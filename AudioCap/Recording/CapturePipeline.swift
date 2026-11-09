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
    }

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
    /// Reconnects (device rebuilds, tap recreation) during the current take.
    let reconnects = Atomic<Int>(0)
    /// Dropouts: runs of all-zero I/O cycles that cut into signal and end with an abrupt return of signal, at most
    /// `maxDropoutSeconds` long, while the source reports running output. Real audio does not jump from a loud sample
    /// to exact zeros and back; the tap does when it delivers zeros mid-signal (see docs), and no sample time jumps.
    let dropouts = Atomic<Int>(0)
    let dropoutFrames = Atomic<Int>(0)
    let timeline = CaptureTimelineLog()
    /// `true` while a take file is open (writer queue writes, any thread reads).
    let isTakeOpen = Atomic<Bool>(false)
    /// Whether the source reports running output; kept current by the recorder (any thread).
    let sourceIsOutputting = Atomic<Bool>(true)
    /// A cycle edge at or above this magnitude (-40 dBFS) counts as an abrupt cut or return.
    static let dropoutEdge: Float = 0.01
    static let maxDropoutSeconds = 1.0
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
    private var takeDropouts = 0
    private var takeDropoutFrames = 0
    /// Uncaptured frames of the refresh the take's onset followed, if any.
    private var takeLateStartFrames: Int?
    private var pendingLateStart: CaptureTimelineLog.Entry?
    private let scratch: AVAudioPCMBuffer
    private var isFinished = false
    private var openFailed = false

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
        } else {
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
        if framesSinceRefresh != .max {
            framesSinceRefresh = framesSinceRefresh + layout.frames > lateStartFrames ? .max : framesSinceRefresh + layout.frames
        }

        if detector != nil {
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
                closeTake()
                continue
            }
            var count = ring.availableFrames
            if let marker { count = min(count, marker - read) }
            count = min(count, Int(scratch.frameCapacity))
            guard count > 0 else { return }

            let data = scratch.floatChannelData!
            ring.read(count: count) { data[$0] }
            scratch.frameLength = AVAudioFrameCount(count)
            takeOverflow += ring.overflowFrames.exchange(0, ordering: .relaxed)

            if writer == nil, !openTake() { continue }
            for c in 0..<channelCount {
                var channelPeak: Float = 0
                vDSP_maxmgv(data[c], 1, &channelPeak, vDSP_Length(count))
                takePeak = max(takePeak, channelPeak)
            }
            writer?.write(scratch)
            currentTakeFrames.store(Int(writer?.framesWritten ?? 0), ordering: .relaxed)
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
                takeDropouts += 1
                takeDropoutFrames += entry.frames
            case .lateStart:
                takeLateStartFrames = max(takeLateStartFrames ?? 0, entry.frames)
            }
        }
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
            handler(.failed("Could not create the capture file: \(error.audioCapDescription)"))
            return false
        }
        let take = RecordingTake(id: UUID(), sourceName: options.sourceName, startedAt: Date(), captureURL: captureURL,
                                 outputURL: outputURL, outputFormat: options.outputFormat, captureFormat: format)
        self.take = take
        takePeak = 0
        isTakeOpen.store(true, ordering: .relaxed)
        (takeJumps, takeSkippedFrames, takeDropouts, takeDropoutFrames) = (0, 0, 0, 0)
        takeLateStartFrames = nil
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
            take.status = .failed(message: "Capture failed: \(error.audioCapDescription)")
            handler(.closed(take))
            return
        }
        guard take.capturedFrames > 0 else {
            try? FileManager.default.removeItem(at: take.captureURL)
            handler(.discarded(take.id))
            return
        }
        var warnings: [String] = []
        if takePeak == 0 {
            warnings.append("Every sample in this take is 0 (digital silence). If \(take.sourceName) was playing, check that AudioCap is allowed in System Settings › Privacy & Security › Screen & System Audio Recording.")
        }
        if takeOverflow > 0 {
            warnings.append("\(takeOverflow) frames were dropped because the writer fell behind.")
        }
        let reconnected = reconnects.exchange(0, ordering: .relaxed)
        if reconnected > 0 {
            warnings.append("The capture was reconnected \(reconnected) time(s) (output device change, source relaunch or wake); audio played during a reconnect is not in the take.")
        }
        let (jumps, skipped, cuts, cutFrames) = (takeJumps, takeSkippedFrames, takeDropouts, takeDropoutFrames)
        if jumps > 0 {
            warnings.append("The audio device's timeline jumped \(jumps) time(s) (\(skipped) frames not delivered by CoreAudio).")
        }
        if cuts > 0 {
            let seconds = (Double(cutFrames) / format.sampleRate).formatted(.number.precision(.fractionLength(3)))
            warnings.append("CoreAudio delivered digital zeros instead of \(take.sourceName)'s audio \(cuts) time(s) while it was playing (\(cutFrames) frames, \(seconds) s); that audio is missing from the take.")
        }
        if let lateFrames = takeLateStartFrames {
            let seconds = (Double(lateFrames) / format.sampleRate).formatted(.number.precision(.fractionLength(3)))
            warnings.append("The take may start up to \(seconds) s late: its first sound arrived during or right after an idle tap refresh, and audio played during the refresh is not in the take.")
        }
        take.warning = warnings.isEmpty ? nil : warnings.joined(separator: " ")
        take.status = .exporting(progress: 0)
        handler(.closed(take))
    }
}

/// Timeline jumps and dropouts found on the I/O thread, tagged with the ring position where they happened, so the
/// writer queue charges each one to the take that contains that position (or to none, while no take is open).
/// Single producer (I/O thread), single consumer (writer queue); no allocation or locks after init.
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
