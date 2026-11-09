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
    /// Jumps in the device's sample timeline between consecutive I/O cycles, and the frames they skipped.
    let discontinuities = Atomic<Int>(0)
    let skippedFrames = Atomic<Int>(0)
    /// `AutoRecordMachine.Phase` of the writer queue's machine, encoded by `Self.code(for:)`.
    private let phaseCode = Atomic<Int>(0)
    /// Silence splitting (manual mode only); "Wait for sound" closes takes by itself.
    private let splitEnabled = Atomic<Bool>(true)
    /// Reconnects (device rebuilds, tap recreation) during the current take.
    let reconnects = Atomic<Int>(0)
    private let signalSeen = Atomic<Bool>(false)
    /// `true` once any non-zero sample has arrived in this pipeline.
    var hasSeenSignal: Bool { signalSeen.load(ordering: .relaxed) }

    private let options: Options
    private let handler: (Event) -> Void
    private let channelCount: Int

    // I/O thread only.
    private var detector: SilenceDetector?
    private var nextSampleTime: Float64 = -1

    // Writer queue only.
    private var timer: DispatchSourceTimer?
    private var writer: CaptureWriter?
    private var take: RecordingTake?
    private var takePeak: Float = 0
    private var takeOverflow = 0
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
                discontinuities.add(1, ordering: .relaxed)
                if sampleTime > nextSampleTime { skippedFrames.add(Int(sampleTime - nextSampleTime), ordering: .relaxed) }
            }
            nextSampleTime = sampleTime + Float64(layout.frames)
        }
        if layout.sourceChannels != channelCount { layoutMismatches.add(1, ordering: .relaxed) }

        var sumSquares: Float = 0
        var peak: Float = 0
        let channelCount = self.channelCount
        let format = self.format
        let staged = ring.stage(frameCount: layout.frames) { offset, count, destination in
            CaptureBufferCopier.convert(list, format: format, sourceOffset: offset, frameCount: count,
                                        channelCount: channelCount, destination: destination)
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
        } else {
            digitalSilenceRun.store(0, ordering: .relaxed)
            signalSeen.store(true, ordering: .relaxed)
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
    func noteReconnect() {
        nextSampleTime = -1
        reconnects.add(1, ordering: .relaxed)
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
                continue
            }
            if writer == nil, !openTake() { continue }
            writeToTake(scratch)
        }
    }

    private func writeToTake(_ buffer: AVAudioPCMBuffer) {
        guard let writer, let data = buffer.floatChannelData else { return }
        for c in 0..<channelCount {
            var channelPeak: Float = 0
            vDSP_maxmgv(data[c], 1, &channelPeak, vDSP_Length(buffer.frameLength))
            takePeak = max(takePeak, channelPeak)
        }
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
            handler(.failed("Could not create the capture file: \(error.audioCapDescription)"))
            return false
        }
        let take = RecordingTake(id: UUID(), sourceName: options.sourceName, startedAt: Date(), captureURL: captureURL,
                                 outputURL: outputURL, outputFormat: options.outputFormat, captureFormat: format)
        self.take = take
        takePeak = 0
        handler(.opened(take))
        return true
    }

    private func closeTake() {
        takeOverflow += ring.overflowFrames.exchange(0, ordering: .relaxed)
        guard let writer, var take else { return }
        self.writer = nil
        self.take = nil
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
            warnings.append("The capture was reconnected \(reconnected) time(s) (output device change, wake or silence recovery); audio played during a reconnect is not in the take.")
        }
        let jumps = discontinuities.exchange(0, ordering: .relaxed)
        let skipped = skippedFrames.exchange(0, ordering: .relaxed)
        if jumps > 0 {
            warnings.append("The audio device's timeline jumped \(jumps) time(s) (\(skipped) frames not delivered by CoreAudio).")
        }
        take.warning = warnings.isEmpty ? nil : warnings.joined(separator: " ")
        take.status = .exporting(progress: 0)
        handler(.closed(take))
    }
}
