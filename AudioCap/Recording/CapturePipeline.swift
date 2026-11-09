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
        /// A warning found after an earlier take had closed: it and a later take may be one split passage.
        case amended(RecordingTake.ID, warning: String)
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
    /// Exact-zero frames of split silence that were not written, since the last take opened.
    let splitSilenceZeroFrames = Atomic<Int>(0)
    /// The source stopped during split silence that was not written, since the last take opened.
    let splitSilenceSourceStopped = Atomic<Bool>(false)
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
    private var takeEdges = PassageEdges(sampleRate: 48_000)
    /// Frames read while no take was open, since the last take closed.
    private var framesWithoutTake = 0
    /// `framesWithoutTake` when the current take opened, and the frames the take received in that same drain step
    /// (auto-record's pre-roll and trigger chunk, which were read before the take opened).
    private var takeFramesBeforeOpen = 0
    private var takeOpeningFrames: Int?
    /// The last take ended with an abrupt cut while the source played; the next take may continue its passage.
    private var pendingSplit: (id: RecordingTake.ID, trailingZeros: Int)?
    private var lastTakeTrailingZeros = 0
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

        if detector != nil {
            let analysis = detector!.process(level: level, duration: Double(layout.frames) / format.sampleRate)
            if analysis.didTriggerSplit { ring.pushMarker() }
            if analysis.shouldDrop {
                if !sourceIsOutputting.load(ordering: .relaxed) {
                    splitSilenceSourceStopped.store(true, ordering: .relaxed)
                } else if peak == 0 {
                    splitSilenceZeroFrames.add(layout.frames, ordering: .relaxed)
                }
                return
            }
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

            if writer == nil {
                framesWithoutTake += count
                if !sourceIsOutputting.load(ordering: .relaxed) { (pendingSplit, lastTakeTrailingZeros) = (nil, 0) }
            }
            if writer == nil, !openTake() { continue }
            for c in 0..<channelCount {
                var channelPeak: Float = 0
                vDSP_maxmgv(data[c], 1, &channelPeak, vDSP_Length(count))
                takePeak = max(takePeak, channelPeak)
            }
            let sourceIsPlaying = sourceIsOutputting.load(ordering: .relaxed)
            takeZeros.add(data, channels: channelCount, frames: count, sourceIsPlaying: sourceIsPlaying)
            takeEdges.add(data, channels: channelCount, frames: count, sourceIsPlaying: sourceIsPlaying)
            writer?.write(scratch)
            if takeOpeningFrames == nil, let writer { takeOpeningFrames = Int(writer.framesWritten) }
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
                break // the take's writer finds these with `takeZeros`, along with holes inside a cycle
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
        (takeJumps, takeSkippedFrames) = (0, 0)
        takeLateStartFrames = nil
        takeZeros = ZeroSpanMeter(maxHoleFrames: maxDropoutFrames, sampleRate: format.sampleRate)
        var unwrittenZeros = splitSilenceZeroFrames.exchange(0, ordering: .relaxed)
        if splitSilenceSourceStopped.exchange(false, ordering: .relaxed) {
            (pendingSplit, lastTakeTrailingZeros, unwrittenZeros) = (nil, 0, 0)
        }
        takeEdges = PassageEdges(sampleRate: format.sampleRate, zerosBefore: unwrittenZeros + lastTakeTrailingZeros)
        takeFramesBeforeOpen = framesWithoutTake + unwrittenZeros
        framesWithoutTake = 0
        takeOpeningFrames = nil
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
            pendingSplit = nil
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
        let (jumps, skipped, cuts, cutFrames) = (takeJumps, takeSkippedFrames, takeZeros.holes, takeZeros.holeFrames)
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
        if takeZeros.isMostlyZero(sampleRate: format.sampleRate) {
            let zeros = (Double(takeZeros.zeroFrames) / format.sampleRate).formatted(.number.precision(.fractionLength(3)))
            let span = (Double(takeZeros.spanFrames) / format.sampleRate).formatted(.number.precision(.fractionLength(3)))
            warnings.append("Most of this take after its first sound is digital zero (\(zeros) s of \(span) s) while \(take.sourceName) was playing. Unless that passage was really silent, CoreAudio delivered zeros instead of its audio and that audio is missing from the take.")
        } else if takeZeros.isShortSoundThenTrimmedZeros(sampleRate: format.sampleRate) {
            let sound = (Double(takeZeros.soundFrames) / format.sampleRate).formatted(.number.precision(.fractionLength(3)))
            let zeros = (Double(takeZeros.trailingZeroFrames) / format.sampleRate).formatted(.number.precision(.fractionLength(3)))
            warnings.append("This take kept only \(sound) s of sound, followed by \(zeros) s of digital zeros while \(take.sourceName) was playing; auto-record ended the take and trimmed those zeros. Unless the sound really stopped there, CoreAudio delivered zeros instead of its audio and the rest is missing.")
        }
        warnings += edgeWarnings(take)
        take.warning = warnings.isEmpty ? nil : warnings.joined(separator: " ")
        take.status = .exporting(progress: 0)
        handler(.closed(take))
    }
}

/// Where a take's sound starts and stops, and whether it does so abruptly: from exact digital zero straight into a
/// waveform, or from a waveform straight to exact zero, while the source reports running output. Real audio fades
/// out or starts from near zero; a CoreAudio tap that goes to zeros cuts it mid-waveform (Hi-Res run: a continuous
/// tone split into two takes around ~10 s of zeros). Only the take's first onset and last cut count; cuts inside
/// a take are `ZeroSpanMeter` holes.
struct PassageEdges {
    /// −40 dBFS: the waveform next to the zeros must reach this within `windowSeconds`.
    static let level: Float = 0.01
    static let windowSeconds = 0.003
    /// The waveform before the last `windowSeconds` must not be much louder than in them: a fade has already decayed
    /// by then, a cut has not. The tap rings for ~1 ms at a hard cut (see `ZeroSpanMeter.edgeSeconds`), so the last
    /// samples before the zeros are tiny either way.
    static let bodySeconds = 0.02
    static let notDecayed: Float = 0.5
    /// Ringing ahead of a hard onset stays below this fraction of the onset's peak (≤ 5 % measured).
    static let ringing: Float = 0.1
    /// A sample next to exact zero that is at least this fraction of the nearby peak is mid-waveform.
    static let midWaveform: Float = 0.25
    static let minZeroFrames = ZeroSpanMeter.minHoleFrames

    private(set) var frames = 0
    /// Zero frames before the first non-zero frame.
    private(set) var leadingZeros = 0
    /// Zero frames after the last non-zero frame.
    private(set) var trailingZeros = 0
    /// Frame of the first sound, when it starts mid-waveform after zeros with the source playing.
    private(set) var abruptOnsetFrame: Int?
    /// Frame where the take's trailing zeros start, when the sound before them stopped mid-waveform and the source
    /// kept playing through them.
    var abruptEndFrame: Int? {
        trailingZeros >= Self.minZeroFrames && cutIsAbrupt && !sourceStoppedSinceSound ? frames - trailingZeros : nil
    }

    /// The source reported running output since the take's last sound.
    var sourceKeptPlaying: Bool { !sourceStoppedSinceSound }

    private let windowFrames: Int
    private let historyFrames: Int
    /// Exact-zero frames right before the take's first frame (split silence that was not written).
    private let zerosBefore: Int
    /// The last `historyFrames` magnitudes, then the current buffer's.
    private var magnitudes: [Float]
    /// The first `windowFrames` magnitudes from the first sound on.
    private var onsetMagnitudes: [Float]
    private var onsetCount = 0
    private var channelMagnitudes: [Float] = []
    private var signalSeen = false
    private var sourceStoppedBeforeSound = false
    private var sourceStoppedSinceSound = false
    private var cutIsAbrupt = false
    private var onsetFrame = 0
    private var onsetRemaining = 0

    init(sampleRate: Double, zerosBefore: Int = 0) {
        windowFrames = max(1, Int(sampleRate * Self.windowSeconds))
        historyFrames = windowFrames + max(1, Int(sampleRate * Self.bodySeconds))
        self.zerosBefore = zerosBefore
        magnitudes = Array(repeating: 0, count: historyFrames)
        onsetMagnitudes = Array(repeating: 0, count: windowFrames)
    }

    mutating func add(_ data: UnsafePointer<UnsafeMutablePointer<Float>>, channels: Int, frames count: Int, sourceIsPlaying: Bool) {
        guard count > 0, channels > 0 else { return }
        if !sourceIsPlaying {
            if signalSeen { sourceStoppedSinceSound = true } else { sourceStoppedBeforeSound = true }
        }
        let h = historyFrames
        var history: [Float] = []
        var scratch: [Float] = []
        swap(&history, &magnitudes)
        swap(&scratch, &channelMagnitudes)
        defer {
            swap(&history, &magnitudes)
            swap(&scratch, &channelMagnitudes)
        }
        if history.count < h + count { history += Array(repeating: 0, count: h + count - history.count) }
        if channels > 1, scratch.count < count { scratch = Array(repeating: 0, count: count) }
        history.withUnsafeMutableBufferPointer { buffer in
            let all = buffer.baseAddress!
            let current = all + h
            let n = vDSP_Length(count)
            vDSP_vabs(data[0], 1, current, 1, n)
            scratch.withUnsafeMutableBufferPointer { channel in
                for c in 1..<max(1, channels) {
                    vDSP_vabs(data[c], 1, channel.baseAddress!, 1, n)
                    vDSP_vmax(current, 1, channel.baseAddress!, 1, current, 1, n)
                }
            }
            let peak = Self.peak
            if onsetRemaining > 0 {
                let length = min(onsetRemaining, count)
                recordOnset(current, length)
                onsetRemaining -= length
                if onsetRemaining == 0 { decideOnset(sourceIsPlaying: sourceIsPlaying) }
            }
            var lowest: Float = 0
            vDSP_minv(current, 1, &lowest, n)
            let highest = peak(current, count)
            if signalSeen, lowest > 0 {
                trailingZeros = 0
                sourceStoppedSinceSound = false
            } else if highest == 0 {
                if signalSeen {
                    if trailingZeros == 0 { noteCut(before: current, sourceIsPlaying: sourceIsPlaying) }
                    trailingZeros += count
                } else {
                    leadingZeros += count
                }
            } else {
                for f in 0..<count {
                    let magnitude = current[f]
                    if magnitude == 0 {
                        if signalSeen {
                            if trailingZeros == 0 { noteCut(before: current + f, sourceIsPlaying: sourceIsPlaying) }
                            trailingZeros += 1
                        } else {
                            leadingZeros += 1
                        }
                        continue
                    }
                    if !signalSeen {
                        signalSeen = true
                        onsetFrame = frames + f
                        let length = min(windowFrames, count - f)
                        recordOnset(current + f, length)
                        onsetRemaining = windowFrames - length
                        if onsetRemaining == 0 { decideOnset(sourceIsPlaying: sourceIsPlaying) }
                    }
                    trailingZeros = 0
                    sourceStoppedSinceSound = false
                }
            }
            memmove(all, all + count, h * MemoryLayout<Float>.stride)
        }
        frames += count
    }

    /// Zero frames after the last written frame that were dropped instead of written (auto-record trims the silence
    /// that closes a take), so a take with a short tail, or none, still shows the cut and how long the zeros lasted.
    mutating func addTrimmedZeros(_ count: Int, sourceIsPlaying: Bool) {
        guard count > 0, signalSeen else { return }
        if !sourceIsPlaying { sourceStoppedSinceSound = true }
        if trailingZeros == 0 {
            let h = historyFrames
            magnitudes.withUnsafeBufferPointer { noteCut(before: $0.baseAddress! + h, sourceIsPlaying: sourceIsPlaying) }
        }
        trailingZeros += count
        frames += count
    }

    private static func peak(_ start: UnsafePointer<Float>, _ length: Int) -> Float {
        var value: Float = 0
        vDSP_maxv(start, 1, &value, vDSP_Length(length))
        return value
    }

    /// `zero` points at the first zero after sound, with `historyFrames` magnitudes before it.
    private mutating func noteCut(before zero: UnsafePointer<Float>, sourceIsPlaying: Bool) {
        let window = Self.peak(zero - windowFrames, windowFrames)
        let body = Self.peak(zero - historyFrames, historyFrames - windowFrames)
        cutIsAbrupt = sourceIsPlaying && window >= Self.level && window >= Self.notDecayed * body
    }

    private mutating func recordOnset(_ start: UnsafePointer<Float>, _ length: Int) {
        for i in 0..<min(length, windowFrames - onsetCount) { onsetMagnitudes[onsetCount + i] = start[i] }
        onsetCount = min(windowFrames, onsetCount + length)
    }

    /// Mid-waveform: the first sample above the ringing level is already at least `midWaveform` of the peak.
    private mutating func decideOnset(sourceIsPlaying: Bool) {
        let samples = onsetMagnitudes[..<onsetCount]
        let peak = samples.max() ?? 0
        guard sourceIsPlaying, !sourceStoppedBeforeSound, leadingZeros + zerosBefore >= Self.minZeroFrames,
              peak >= Self.level, let first = samples.first(where: { $0 >= Self.ringing * peak }) else { return }
        if first >= Self.midWaveform * peak { abruptOnsetFrame = onsetFrame }
    }

    /// Zero frames between an abrupt end and the next take's abrupt onset: the earlier take's trailing zeros, the
    /// frames read while no take was open (less those the next take received when it opened, its pre-roll), and the
    /// next take's leading zeros.
    static func splitGapFrames(previousTrailingZeros: Int, framesWithoutTake: Int, openingFrames: Int, leadingZeros: Int) -> Int {
        previousTrailingZeros + max(0, framesWithoutTake - openingFrames) + leadingZeros
    }
}

extension CapturePipeline {
    /// Abrupt start and end of the take's sound, and the link to the previous take when one passage looks split
    /// between them. Updates `pendingSplit` for the next take.
    fileprivate func edgeWarnings(_ take: RecordingTake) -> [String] {
        let rate = format.sampleRate
        let seconds = { (frames: Int) in (Double(frames) / rate).formatted(.number.precision(.fractionLength(3))) }
        var warnings: [String] = []
        if let onset = takeEdges.abruptOnsetFrame {
            warnings.append("Audio started abruptly mid-waveform at \(seconds(onset)) s while \(take.sourceName) was playing; the start may be missing.")
        }
        if let pending = pendingSplit, takeEdges.abruptOnsetFrame != nil {
            let gap = PassageEdges.splitGapFrames(previousTrailingZeros: pending.trailingZeros,
                                                  framesWithoutTake: takeFramesBeforeOpen,
                                                  openingFrames: takeOpeningFrames ?? 0,
                                                  leadingZeros: takeEdges.leadingZeros)
            warnings.append("This take and the previous one may be one passage split by a CoreAudio dropout; \(seconds(gap)) s between them (digital zeros while \(take.sourceName) was playing) are not in either take.")
            handler(.amended(pending.id, warning: "This take and the next one may be one passage split by a CoreAudio dropout; \(seconds(gap)) s between them (digital zeros while \(take.sourceName) was playing) are not in either take."))
        }
        pendingSplit = nil
        lastTakeTrailingZeros = takeEdges.sourceKeptPlaying ? takeEdges.trailingZeros : 0
        if let end = takeEdges.abruptEndFrame {
            warnings.append("Audio stopped abruptly at \(seconds(end)) s while \(take.sourceName) was playing; the rest may be missing.")
            pendingSplit = (take.id, takeEdges.trailingZeros)
        }
        return warnings
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
    /// How far from a hole its loud edge may be. The tap smooths a hard cut: the last loud sample is followed by
    /// about 1 ms of ringing below 5 % of its level before the exact zeros, and the same ringing leads into the
    /// audio after them (afplay through a process tap, 48 kHz).
    static let edgeSeconds = 0.002
    /// Zeros trimmed after a short sound make the take mostly zero when they are more than this fraction of its span.
    static let trimmedZeroFraction = 0.8
    /// Frames after the first non-zero frame while the source was playing.
    private(set) var spanFrames = 0
    /// Of those, frames in zero runs of at least `minRunFrames`, including a trailing run.
    var zeroFrames: Int { closedZeroFrames + (run >= Self.minRunFrames ? run : 0) }
    /// Zero runs of `minHoleFrames` up to `maxHoleFrames` between loud samples (`CapturePipeline.dropoutEdge`).
    private(set) var holes = 0
    private(set) var holeFrames = 0
    /// Zeros after the take's last sound that were not written to it (auto-record's trimmed silence), while the
    /// source was playing.
    private(set) var trimmedZeros = 0
    let maxHoleFrames: Int
    private let edgeFrames: Int
    private var closedZeroFrames = 0
    private var run = 0
    private var runStartMagnitude: Float = 0
    private var recentPeak: Float = 0
    private var recentLeft = 0
    private var pendingHole = 0
    private var pendingLeft = 0
    private var signalSeen = false

    init(maxHoleFrames: Int = .max, sampleRate: Double = 48_000) {
        self.maxHoleFrames = maxHoleFrames
        edgeFrames = max(1, Int(sampleRate * Self.edgeSeconds))
    }

    mutating func add(_ data: UnsafePointer<UnsafeMutablePointer<Float>>, channels: Int, frames: Int, sourceIsPlaying: Bool) {
        guard sourceIsPlaying else {
            endRun()
            (recentPeak, recentLeft, pendingHole, pendingLeft) = (0, 0, 0, 0)
            return
        }
        for f in 0..<frames {
            var magnitude: Float = 0
            for c in 0..<channels { magnitude = max(magnitude, abs(data[c][f])) }
            if pendingLeft > 0 {
                pendingLeft -= 1
                if magnitude >= CapturePipeline.dropoutEdge {
                    holes += 1
                    holeFrames += pendingHole
                    pendingLeft = 0
                }
            }
            if magnitude == 0 {
                guard signalSeen else { continue }
                if run == 0 { runStartMagnitude = recentPeak }
                run += 1
                spanFrames += 1
            } else {
                if run >= Self.minHoleFrames, run <= maxHoleFrames, runStartMagnitude >= CapturePipeline.dropoutEdge {
                    pendingHole = run
                    pendingLeft = edgeFrames
                    if magnitude >= CapturePipeline.dropoutEdge {
                        holes += 1
                        holeFrames += run
                        pendingLeft = 0
                    }
                }
                if run > 0 { (recentPeak, recentLeft) = (0, 0) }
                endRun()
                signalSeen = true
                spanFrames += 1
                if magnitude >= recentPeak || recentLeft == 0 {
                    (recentPeak, recentLeft) = (magnitude, edgeFrames)
                } else {
                    recentLeft -= 1
                }
            }
        }
    }

    /// Zero frames after the last written frame that were dropped instead of written (auto-record trims the
    /// silence that closes a take), so a take cut to zeros early still shows them.
    mutating func addTrimmedZeros(_ frames: Int, sourceIsPlaying: Bool) {
        guard sourceIsPlaying, signalSeen, frames > 0 else { return }
        trimmedZeros += frames
    }

    /// At least `minZeroSeconds` of zeros, and more than half of the span after the first sound.
    func isMostlyZero(sampleRate: Double) -> Bool {
        Double(zeroFrames) >= Self.minZeroSeconds * sampleRate && zeroFrames * 2 > spanFrames
    }

    /// Not `isMostlyZero` from the written frames alone, but zeros including the trimmed ones are at least
    /// `minZeroSeconds` and more than `trimmedZeroFraction` of the span: a short sound, then zeros while the source
    /// played. A normal ending (the sound, then the trimmed silence) has a much longer sound.
    func isShortSoundThenTrimmedZeros(sampleRate: Double) -> Bool {
        guard trimmedZeros > 0, !isMostlyZero(sampleRate: sampleRate) else { return false }
        let zeros = zeroFrames + trimmedZeros + (run < Self.minRunFrames ? run : 0)
        return Double(zeros) >= Self.minZeroSeconds * sampleRate
            && Double(zeros) > Self.trimmedZeroFraction * Double(spanFrames + trimmedZeros)
    }

    /// First to last sound, for `isShortSoundThenTrimmedZeros`.
    var soundFrames: Int { spanFrames - run }
    /// Zeros after the last sound, written and trimmed.
    var trailingZeroFrames: Int { run + trimmedZeros }

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
