import Foundation
import AVFoundation
import Accelerate
import Synchronization

/// The capture path for one capture format: I/O block → `CaptureRingBuffer` → writer queue → `CaptureWriter`.
///
/// `process(_:)` runs inside the I/O block. It converts the tap's buffers straight into the preallocated ring,
/// measures the level, applies silence splitting and publishes the frames; it allocates nothing, takes no
/// locks and sends no Objective-C messages. A timer on the writer queue drains the ring into the take's CAF
/// file, opening a take on the first frame and closing it at split markers and in `finish()`.
final class CapturePipeline: @unchecked Sendable {
    struct Options {
        var outputDirectory: URL
        var outputFormat: RecordingSettings.OutputFormat
        var sourceName: String
        /// `nil` disables splitting.
        var silenceDetector: SilenceDetector?
        /// Returns a unique base file name for a new take. Called on the writer queue.
        var makeBaseName: () -> String
        /// How often the writer queue drains the ring.
        var drainInterval: TimeInterval = 0.02
        /// Ring capacity in seconds of audio.
        var bufferedSeconds: Double = 4
        /// When set, an `AutoRecordMachine` on the writer queue decides when takes open and close.
        var autoRecord: AutoRecordMachine.Configuration?
        var mode: AutoRecordMachine.Mode = .manual
        /// The source is "All system audio" (stored as a code so its name follows the language).
        var isAllSystemAudio = false
    }

    /// Frames per `AutoRecordMachine` step: the resolution of sound detection, pre-roll and tail.
    static let autoRecordChunkFrames = 512

    enum Event {
        /// A take started (status `.recording`).
        case opened(RecordingTake)
        /// A take's capture file was closed and verified (status `.exporting(0)`), or failed (`.failed`).
        case closed(RecordingTake)
        /// A take ended with no frames and was deleted.
        case discarded(RecordingTake.ID)
        /// The capture file could not be created.
        case failed(String)
    }

    let format: CaptureFormat
    let writerFormat: AVAudioFormat
    let ring: CaptureRingBuffer
    let queue: DispatchQueue

    // Read from any thread.
    /// Level of the latest I/O buffer, as `Double` bit patterns of dBFS.
    private let rmsBits = Atomic<UInt64>(AudioLevel.silence.rmsDb.bitPattern)
    private let peakBits = Atomic<UInt64>(AudioLevel.silence.peakDb.bitPattern)
    /// Consecutive frames, up to now, in which every sample was exactly 0.
    let digitalSilenceRun = Atomic<Int>(0)
    /// I/O cycles seen.
    let ioCycles = Atomic<Int>(0)
    /// I/O cycles whose buffer list had a different channel count than the format.
    let layoutMismatches = Atomic<Int>(0)
    /// Frames in the current take's file.
    let currentTakeFrames = Atomic<Int>(0)
    /// Jumps in the device's sample timeline between consecutive I/O cycles, and the frames they skipped, since the
    /// pipeline started (diagnostics). Each take's own share comes from `timeline`.
    let discontinuities = Atomic<Int>(0)
    let skippedFrames = Atomic<Int>(0)
    /// `AutoRecordMachine.Phase` of the writer queue's machine, encoded by `Self.code(for:)`.
    private let phaseCode = Atomic<Int>(0)
    /// Silence splitting (manual mode only); "Wait for sound" closes takes by itself.
    private let splitEnabled = Atomic<Bool>(true)
    /// Reconnects (device rebuilds, tap recreation) during the current take.
    let reconnects = Atomic<Int>(0)
    /// Dropouts: runs of all-zero I/O cycles that cut into signal and end with an abrupt return of signal, at most
    /// `maxDropoutSeconds` long, while the source reports running output. Real audio does not jump from a loud sample
    /// to exact zeros and back; the tap does when it delivers zeros mid-signal (see docs), and no sample time jumps.
    let dropouts = Atomic<Int>(0)
    let dropoutFrames = Atomic<Int>(0)
    /// Cuts from signal to an all-zero cycle while the source plays, since the last `cleanSignalSeconds` of
    /// uninterrupted signal. A tap that chops a playing source into short bursts makes many (see `ChoppedCapture`).
    let chops = Atomic<Int>(0)
    let timeline = CaptureTimelineLog()
    /// `true` while a take file is open (writer queue writes, any thread reads).
    let isTakeOpen = Atomic<Bool>(false)
    /// Whether the source reports running output; kept current by the recorder (any thread).
    let sourceIsOutputting = Atomic<Bool>(true)
    /// A cycle edge at or above this magnitude (-40 dBFS) counts as an abrupt cut or return.
    static let dropoutEdge: Float = 0.01
    static let maxDropoutSeconds = 1.0
    static let cleanSignalSeconds = 0.5
    /// A take whose first signal arrives this soon after an idle tap refresh may have lost its onset to the refresh.
    static let lateStartSeconds = 0.5
    static let hostTicksPerSecond: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return 1e9 * Double(info.denom) / Double(info.numer)
    }()
    /// Idle tap refreshes and the audio time between the last cycle before and the first cycle after each (diagnostics).
    let idleRefreshes = Atomic<Int>(0)
    let idleRefreshGapFrames = Atomic<Int>(0)
    private let signalSeen = Atomic<Bool>(false)
    /// `true` once any non-zero sample has arrived in this pipeline.
    var hasSeenSignal: Bool { signalSeen.load(ordering: .relaxed) }

    private let options: Options
    private let handler: (Event) -> Void
    private let channelCount: Int

    // I/O thread only.
    private var detector: SilenceDetector?
    private var nextSampleTime: Float64 = -1
    /// Largest magnitude of the last frame of the previous cycle; 0 after an all-zero cycle.
    private var lastEdge: Float = 0
    private var previousCyclePeak: Float = 0
    private var cleanSignalFrames = 0
    /// Frames of the all-zero run that started with an abrupt cut, not yet counted as a dropout.
    private var pendingDropoutFrames = 0
    private var pendingDropoutPosition = 0
    private let maxDropoutFrames: Int
    private let lateStartFrames: Int
    /// Host time at the end of the previous cycle; 0 when unknown.
    private var lastCycleEndHost: UInt64 = 0
    private var awaitingRefreshEnd = false
    /// Uncaptured frames of the last idle refresh, and frames since it ended (`Int.max` once past `lateStartFrames`).
    /// A fresh tap can deliver zeros for its first cycles, so a late start counts both.
    private var refreshGap = 0
    private var framesSinceRefresh = Int.max

    // Writer queue only.
    private var timer: DispatchSourceTimer?
    private var writer: CaptureWriter?
    private var take: RecordingTake?
    private var takePeak: Float = 0
    private var takeOverflow = 0
    private var takeJumps = 0
    private var takeSkippedFrames = 0
    /// Uncaptured frames of the refresh the take's onset followed, if any.
    private var takeLateStartFrames: Int?
    private var takeZeros = ZeroSpanMeter()
    private var pendingLateStart: CaptureTimelineLog.Entry?
    private let scratch: AVAudioPCMBuffer
    private var isFinished = false
    private var openFailed = false
    private var machine: AutoRecordMachine?

    var phase: AutoRecordMachine.Phase {
        switch phaseCode.load(ordering: .relaxed) {
        case 1: .armed
        case 2: .recording
        case 3: .closing
        default: .idle
        }
    }

    private static func code(for phase: AutoRecordMachine.Phase) -> Int {
        switch phase {
        case .idle: 0
        case .armed: 1
        case .recording: 2
        case .closing: 3
        }
    }

    var level: AudioLevel {
        AudioLevel(rmsDb: Double(bitPattern: rmsBits.load(ordering: .relaxed)),
                   peakDb: Double(bitPattern: peakBits.load(ordering: .relaxed)))
    }

    /// `handler` is called on the writer queue.
    init(format: CaptureFormat, options: Options, handler: @escaping (Event) -> Void) {
        self.format = format
        self.writerFormat = format.writerFormat
        self.options = options
        self.handler = handler
        self.channelCount = Int(writerFormat.channelCount)
        self.maxDropoutFrames = Int(format.sampleRate * Self.maxDropoutSeconds)
        self.lateStartFrames = Int(format.sampleRate * Self.lateStartSeconds)
        self.detector = options.silenceDetector
        self.ring = CaptureRingBuffer(channelCount: channelCount, minimumCapacity: Int(format.sampleRate * options.bufferedSeconds))
        self.scratch = AVAudioPCMBuffer(pcmFormat: writerFormat, frameCapacity: 16_384)!
        self.queue = DispatchQueue(label: "CapturePipeline.writer", qos: .userInitiated)
        if let configuration = options.autoRecord {
            let machine = AutoRecordMachine(configuration: configuration, format: writerFormat, mode: options.mode)
            machine.start()
            self.machine = machine
            phaseCode.store(Self.code(for: machine.phase), ordering: .relaxed)
            splitEnabled.store(options.mode == .manual, ordering: .relaxed)
        }

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + options.drainInterval, repeating: options.drainInterval, leeway: .milliseconds(5))
        timer.setEventHandler { [weak self] in self?.drain() }
        timer.resume()
        self.timer = timer
    }

    deinit {
        timer?.cancel()
    }

    // MARK: - I/O thread

    /// Takes the audio of one I/O cycle. Call only from the I/O block (one producer).
    /// `time` is the cycle's input time stamp; gaps in its sample time are counted in `discontinuities`.
    func process(_ list: UnsafePointer<AudioBufferList>, time: UnsafePointer<AudioTimeStamp>? = nil) {
        ioCycles.add(1, ordering: .relaxed)
        let layout = CaptureBufferCopier.layout(of: list, format: format)
        guard layout.frames > 0 else { return }
        if let time, time.pointee.mFlags.contains(.sampleTimeValid) {
            let sampleTime = time.pointee.mSampleTime
            if nextSampleTime >= 0, abs(sampleTime - nextSampleTime) >= 1 {
                let skipped = sampleTime > nextSampleTime ? Int(sampleTime - nextSampleTime) : 0
                discontinuities.add(1, ordering: .relaxed)
                skippedFrames.add(skipped, ordering: .relaxed)
                timeline.push(.init(kind: .jump, position: ring.producedFrames, frames: skipped))
            }
            nextSampleTime = sampleTime + Float64(layout.frames)
        }
        if awaitingRefreshEnd {
            awaitingRefreshEnd = false
            var gapSeconds = 0.0
            if let time, time.pointee.mFlags.contains(.hostTimeValid), lastCycleEndHost > 0, time.pointee.mHostTime > lastCycleEndHost {
                gapSeconds = Double(time.pointee.mHostTime - lastCycleEndHost) / Self.hostTicksPerSecond
            }
            refreshGap = Int((gapSeconds * format.sampleRate).rounded())
            idleRefreshGapFrames.add(refreshGap, ordering: .relaxed)
            framesSinceRefresh = 0
        }
        if let time, time.pointee.mFlags.contains(.hostTimeValid) {
            lastCycleEndHost = time.pointee.mHostTime + UInt64(Double(layout.frames) / format.sampleRate * Self.hostTicksPerSecond)
        } else {
            lastCycleEndHost = 0
        }
        if layout.sourceChannels != channelCount { layoutMismatches.add(1, ordering: .relaxed) }

        var sumSquares: Float = 0
        var peak: Float = 0
        var firstEdge: Float = 0
        var endEdge: Float = 0
        let channelCount = self.channelCount
        let format = self.format
        let totalFrames = layout.frames
        let staged = ring.stage(frameCount: layout.frames) { offset, count, destination in
            CaptureBufferCopier.convert(list, format: format, sourceOffset: offset, frameCount: count,
                                        channelCount: channelCount, destination: destination)
            for c in 0..<channelCount where count > 0 {
                if offset == 0 { firstEdge = max(firstEdge, abs(destination(c)[0])) }
                if offset + count == totalFrames { endEdge = max(endEdge, abs(destination(c)[count - 1])) }
            }
            for c in 0..<channelCount {
                var channelPeak: Float = 0
                var channelSquares: Float = 0
                vDSP_maxmgv(destination(c), 1, &channelPeak, vDSP_Length(count))
                vDSP_svesq(destination(c), 1, &channelSquares, vDSP_Length(count))
                peak = max(peak, channelPeak)
                sumSquares += channelSquares
            }
        }
        let samples = Double(max(staged * channelCount, 1))
        let level = AudioLevel(rmsDb: AudioLevel.dbfs(sqrt(Double(sumSquares) / samples)), peakDb: AudioLevel.dbfs(Double(peak)))
        rmsBits.store(level.rmsDb.bitPattern, ordering: .relaxed)
        peakBits.store(level.peakDb.bitPattern, ordering: .relaxed)
        if peak == 0 {
            digitalSilenceRun.add(layout.frames, ordering: .relaxed)
            if pendingDropoutFrames > 0 {
                pendingDropoutFrames += layout.frames
            } else if lastEdge >= Self.dropoutEdge, sourceIsOutputting.load(ordering: .relaxed) {
                pendingDropoutFrames = layout.frames
                pendingDropoutPosition = ring.producedFrames
            }
            lastEdge = 0
            if previousCyclePeak >= Self.dropoutEdge, sourceIsOutputting.load(ordering: .relaxed) {
                chops.add(1, ordering: .relaxed)
            }
            cleanSignalFrames = 0
        } else {
            cleanSignalFrames += layout.frames
            if Double(cleanSignalFrames) >= Self.cleanSignalSeconds * format.sampleRate { chops.store(0, ordering: .relaxed) }
            digitalSilenceRun.store(0, ordering: .relaxed)
            signalSeen.store(true, ordering: .relaxed)
            if pendingDropoutFrames > 0, pendingDropoutFrames <= maxDropoutFrames, firstEdge >= Self.dropoutEdge {
                dropouts.add(1, ordering: .relaxed)
                dropoutFrames.add(pendingDropoutFrames, ordering: .relaxed)
                timeline.push(.init(kind: .dropout, position: pendingDropoutPosition, frames: pendingDropoutFrames))
            }
            pendingDropoutFrames = 0
            lastEdge = endEdge
            if framesSinceRefresh <= lateStartFrames {
                timeline.push(.init(kind: .lateStart, position: ring.producedFrames, frames: refreshGap + framesSinceRefresh))
                framesSinceRefresh = .max
            }
        }
        previousCyclePeak = peak
        if framesSinceRefresh != .max {
            framesSinceRefresh = framesSinceRefresh + layout.frames > lateStartFrames ? .max : framesSinceRefresh + layout.frames
        }

        if detector != nil, splitEnabled.load(ordering: .relaxed) {
            let analysis = detector!.process(level: level, duration: Double(layout.frames) / format.sampleRate)
            if analysis.didTriggerSplit { ring.pushMarker() }
            if analysis.shouldDrop { return }
        }
        ring.commitStaged()
    }

    /// Marks a deliberate restart of the device: the next cycle's sample time starts a new timeline and is not
    /// counted as a discontinuity. Call on the I/O queue while the producer is gated.
    /// `chargesTake: false` for an idle refresh done while no take is open: it is not a reconnect of a take, but a
    /// take whose first signal arrives within `lateStartSeconds` of it is flagged as possibly starting late.
    func noteReconnect(chargesTake: Bool = true) {
        nextSampleTime = -1
        lastEdge = 0
        pendingDropoutFrames = 0
        framesSinceRefresh = .max
        previousCyclePeak = 0
        cleanSignalFrames = 0
        chops.store(0, ordering: .relaxed)
        if chargesTake {
            reconnects.add(1, ordering: .relaxed)
        } else {
            idleRefreshes.add(1, ordering: .relaxed)
            awaitingRefreshEnd = true
        }
    }

    // MARK: - Writer queue

    /// Drains the ring, closes the current take and stops the drain timer. Call after the producer has stopped.
    func finish() {
        queue.sync {
            guard !isFinished else { return }
            timer?.cancel()
            timer = nil
            drain()
            if let machine {
                var sink = Sink(pipeline: self)
                machine.stop(sink: &sink)
                publishPhase()
            }
            closeTake()
            isFinished = true
        }
    }

    /// Writes everything published so far. Runs on the writer queue.
    private func drain() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !isFinished else { return }
        while true {
            let read = ring.consumedFrames
            let marker = ring.peekMarker()
            if let marker, marker <= read {
                ring.popMarker()
                endTake()
                continue
            }
            var count = ring.availableFrames
            if let marker { count = min(count, marker - read) }
            count = min(count, machine == nil ? Int(scratch.frameCapacity) : Self.autoRecordChunkFrames)
            guard count > 0 else { return }

            let data = scratch.floatChannelData!
            ring.read(count: count) { data[$0] }
            scratch.frameLength = AVAudioFrameCount(count)
            takeOverflow += ring.overflowFrames.exchange(0, ordering: .relaxed)

            if let machine {
                var sink = Sink(pipeline: self)
                machine.process(scratch, level: AudioLevel(measuring: scratch), sink: &sink)
                publishPhase()
                chargeTimeline()
                continue
            }
            if writer == nil, !openTake() { continue }
            writeToTake(scratch)
            chargeTimeline()
        }
    }

    /// Charges the timeline entries of the frames read so far to the open take, or drops them while none is open.
    /// A late start seen while no take is open is kept for a take that opens shortly after.
    private func chargeTimeline() {
        let isTakeOpen = writer != nil
        timeline.consume(before: ring.consumedFrames) { entry in
            guard isTakeOpen else {
                if entry.kind == .lateStart { pendingLateStart = entry }
                return
            }
            switch entry.kind {
            case .jump:
                takeJumps += 1
                takeSkippedFrames += entry.frames
            case .dropout:
                break // the take's writer finds these with `takeZeros`, along with holes inside a cycle
            case .lateStart:
                takeLateStartFrames = max(takeLateStartFrames ?? 0, entry.frames)
            }
        }
    }

    private func writeToTake(_ buffer: AVAudioPCMBuffer) {
        guard let writer, let data = buffer.floatChannelData else { return }
        for c in 0..<channelCount {
            var channelPeak: Float = 0
            vDSP_maxmgv(data[c], 1, &channelPeak, vDSP_Length(buffer.frameLength))
            takePeak = max(takePeak, channelPeak)
        }
        takeZeros.add(data, channels: channelCount, frames: Int(buffer.frameLength), sourceIsPlaying: sourceIsOutputting.load(ordering: .relaxed))
        writer.write(buffer)
        currentTakeFrames.store(Int(writer.framesWritten), ordering: .relaxed)
    }

    /// Ends the open take at a split marker; the machine re-arms ("Wait for sound") or reopens on the next frame.
    private func endTake() {
        if let machine {
            var sink = Sink(pipeline: self)
            machine.endTake(sink: &sink)
            publishPhase()
        }
        closeTake()
    }

    /// Switches the running machine between "Wait for sound" and manual.
    func setMode(_ mode: AutoRecordMachine.Mode) {
        splitEnabled.store(mode == .manual, ordering: .relaxed)
        queue.async { [self] in
            guard !isFinished, let machine else { return }
            var sink = Sink(pipeline: self)
            machine.setMode(mode, sink: &sink)
            publishPhase()
        }
    }

    private func publishPhase() {
        if let machine { phaseCode.store(Self.code(for: machine.phase), ordering: .relaxed) }
    }

    /// Connects `AutoRecordMachine` to the take files. Writer queue only.
    private struct Sink: TakeSink {
        unowned let pipeline: CapturePipeline

        mutating func openTake() -> Bool { pipeline.writer != nil || pipeline.openTake() }
        mutating func write(_ buffer: AVAudioPCMBuffer) { pipeline.writeToTake(buffer) }
        mutating func closeTake() { pipeline.closeTake() }
    }

    private func openTake() -> Bool {
        guard !openFailed else { return false }
        let base = options.makeBaseName()
        let captureURL = options.outputDirectory.appendingPathComponent(base).appendingPathExtension("caf")
        let outputURL = options.outputDirectory.appendingPathComponent(base).appendingPathExtension(options.outputFormat.fileExtension)
        do {
            writer = try CaptureWriter(url: captureURL, format: writerFormat)
        } catch {
            openFailed = true
            handler(.failed(String(localized: "Could not create the capture file: \(error.audioCapDescription)")))
            return false
        }
        let take = RecordingTake(id: UUID(), source: options.isAllSystemAudio ? .allSystemAudio : .app(name: options.sourceName), startedAt: Date(), captureURL: captureURL,
                                 outputURL: outputURL, outputFormat: options.outputFormat, captureFormat: format)
        self.take = take
        takePeak = 0
        isTakeOpen.store(true, ordering: .relaxed)
        (takeJumps, takeSkippedFrames) = (0, 0)
        takeLateStartFrames = nil
        takeZeros = ZeroSpanMeter(maxHoleFrames: maxDropoutFrames)
        if let pending = pendingLateStart, ring.consumedFrames - pending.position <= lateStartFrames + Int(scratch.frameCapacity) {
            takeLateStartFrames = pending.frames
        }
        pendingLateStart = nil
        handler(.opened(take))
        return true
    }

    private func closeTake() {
        takeOverflow += ring.overflowFrames.exchange(0, ordering: .relaxed)
        chargeTimeline()
        guard let writer, var take else { return }
        self.writer = nil
        self.take = nil
        isTakeOpen.store(false, ordering: .relaxed)
        currentTakeFrames.store(0, ordering: .relaxed)
        defer { takeOverflow = 0 }

        do {
            take.capturedFrames = try writer.finish()
        } catch {
            take.capturedFrames = writer.framesWritten
            take.status = .failed(message: String(localized: "Capture failed: \(error.audioCapDescription)"))
            handler(.closed(take))
            return
        }
        guard take.capturedFrames > 0 else {
            try? FileManager.default.removeItem(at: take.captureURL)
            handler(.discarded(take.id))
            return
        }
        var warnings: [TakeWarning] = []
        if takePeak == 0 { warnings.append(.allZero) }
        if takeOverflow > 0 { warnings.append(.droppedFrames(frames: takeOverflow)) }
        let reconnected = reconnects.exchange(0, ordering: .relaxed)
        if reconnected > 0 { warnings.append(.reconnected(count: reconnected)) }
        if takeJumps > 0 { warnings.append(.timelineJumps(count: takeJumps, skippedFrames: takeSkippedFrames)) }
        if takeZeros.holes > 0 {
            warnings.append(.dropouts(count: takeZeros.holes, frames: takeZeros.holeFrames,
                                      seconds: Double(takeZeros.holeFrames) / format.sampleRate))
        }
        if let lateFrames = takeLateStartFrames {
            warnings.append(.startMayBeLate(seconds: Double(lateFrames) / format.sampleRate))
        }
        if takeZeros.isMostlyZero(sampleRate: format.sampleRate) {
            warnings.append(.mostlyZero(zeroSeconds: Double(takeZeros.zeroFrames) / format.sampleRate,
                                        spanSeconds: Double(takeZeros.spanFrames) / format.sampleRate))
        }
        take.warnings = warnings
        take.status = .exporting(progress: 0)
        handler(.closed(take))
    }
}

/// Timeline jumps and dropouts found on the I/O thread, tagged with the ring position where they happened, so the
/// writer queue charges each one to the take that contains that position (or to none, while no take is open).
/// Single producer (I/O thread), single consumer (writer queue); no allocation or locks after init.
/// Digital zero in a take after its first sound, while the source reports running output. A tap can deliver a
/// sliver of signal and then zeros while the source keeps playing (see docs); the dropout check misses that when
/// the zeros last longer than `maxDropoutSeconds` or the take ends before signal returns.
struct ZeroSpanMeter {
    /// Exact-zero runs at least this long count; isolated zero samples are ordinary audio.
    static let minRunFrames = 64
    static let minZeroSeconds = 1.0
    /// Zeros this long between two loud samples are a hole cut into the audio: real audio cannot jump from a loud
    /// sample to exact zero on every channel and back (engine harness, 48 kHz: 23-frame holes in every 512-frame cycle).
    static let minHoleFrames = 8
    /// Frames after the first non-zero frame while the source was playing.
    private(set) var spanFrames = 0
    /// Of those, frames in zero runs of at least `minRunFrames`, including a trailing run.
    var zeroFrames: Int { closedZeroFrames + (run >= Self.minRunFrames ? run : 0) }
    /// Zero runs of `minHoleFrames` up to `maxHoleFrames` between loud samples (`CapturePipeline.dropoutEdge`).
    private(set) var holes = 0
    private(set) var holeFrames = 0
    let maxHoleFrames: Int
    private var closedZeroFrames = 0
    private var run = 0
    private var runStartMagnitude: Float = 0
    private var lastMagnitude: Float = 0
    private var signalSeen = false

    init(maxHoleFrames: Int = .max) {
        self.maxHoleFrames = maxHoleFrames
    }

    mutating func add(_ data: UnsafePointer<UnsafeMutablePointer<Float>>, channels: Int, frames: Int, sourceIsPlaying: Bool) {
        guard sourceIsPlaying else {
            endRun()
            lastMagnitude = 0
            return
        }
        for f in 0..<frames {
            var magnitude: Float = 0
            for c in 0..<channels { magnitude = max(magnitude, abs(data[c][f])) }
            if magnitude == 0 {
                guard signalSeen else { continue }
                if run == 0 { runStartMagnitude = lastMagnitude }
                run += 1
                spanFrames += 1
            } else {
                if run >= Self.minHoleFrames, run <= maxHoleFrames,
                   runStartMagnitude >= CapturePipeline.dropoutEdge, magnitude >= CapturePipeline.dropoutEdge {
                    holes += 1
                    holeFrames += run
                }
                endRun()
                signalSeen = true
                spanFrames += 1
                lastMagnitude = magnitude
            }
        }
    }

    /// At least `minZeroSeconds` of zeros, and more than half of the span after the first sound.
    func isMostlyZero(sampleRate: Double) -> Bool {
        Double(zeroFrames) >= Self.minZeroSeconds * sampleRate && zeroFrames * 2 > spanFrames
    }

    private mutating func endRun() {
        if run >= Self.minRunFrames { closedZeroFrames += run }
        run = 0
    }
}

final class CaptureTimelineLog: @unchecked Sendable {
    enum Kind: UInt8 { case jump, dropout, lateStart }
    struct Entry { var kind: Kind; var position: Int; var frames: Int }

    static let capacity = 256
    private let entries = UnsafeMutablePointer<Entry>.allocate(capacity: CaptureTimelineLog.capacity)
    private let writeIndex = Atomic<Int>(0)
    private let readIndex = Atomic<Int>(0)
    /// Entries the producer could not store because the consumer fell behind.
    let lostEntries = Atomic<Int>(0)

    deinit { entries.deallocate() }

    func push(_ entry: Entry) {
        let w = writeIndex.load(ordering: .relaxed)
        guard w - readIndex.load(ordering: .acquiring) < Self.capacity else {
            lostEntries.add(1, ordering: .relaxed)
            return
        }
        (entries + (w & (Self.capacity - 1))).initialize(to: entry)
        writeIndex.store(w + 1, ordering: .releasing)
    }

    /// Calls `body` for every entry before ring position `position`, oldest first, and removes it.
    func consume(before position: Int, _ body: (Entry) -> Void) {
        var r = readIndex.load(ordering: .relaxed)
        let w = writeIndex.load(ordering: .acquiring)
        while r < w {
            let entry = entries[r & (Self.capacity - 1)]
            guard entry.position < position else { break }
            body(entry)
            r += 1
        }
        readIndex.store(r, ordering: .releasing)
    }
}
