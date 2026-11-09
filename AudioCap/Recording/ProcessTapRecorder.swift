@preconcurrency import AVFoundation
import Observation
import OSLog
import Synchronization

/// A heap box for an atomic counter, so it can live in an `@Observable` class.
final class AtomicCounter: @unchecked Sendable {
    let value = Atomic<Int>(0)
}

/// Records a `ProcessTap` into takes and exports each take when it ends.
///
/// Data path: the aggregate device's I/O block runs on `ioQueue` and hands each buffer list to the current
/// `CapturePipeline`, which converts it into a preallocated ring buffer without allocating (canonical Float32),
/// measures its level and applies silence splitting. The pipeline's writer queue drains the ring into the take's
/// `CaptureWriter`, which owns the CAF file. When a take ends, the file is closed and its frame count verified;
/// then `AudioExporter` converts it on `exportQueue` and checks the output duration.
///
/// Stop order: `AudioDeviceStop` → drain `ioQueue` → drain the ring and close the writer → verify frames → export.
///
/// All observable state is updated on the main thread. A recorder can record several times.
@Observable
final class ProcessTapRecorder {

    enum Status: Equatable, Sendable {
        case idle
        case recording
        /// Recording, but the source app is not running; a new take starts when it comes back.
        case waitingForSource
    }

    /// Where exports (and CAF intermediates) are written.
    let outputDirectory: URL

    /// The recorder's state.
    private(set) var status: Status = .idle
    /// `true` while recording or waiting for the source.
    var isRecording: Bool { status != .idle }
    /// Level of the most recent buffer, refreshed about 15 times per second while recording.
    private(set) var level: AudioLevel = .silence
    /// Frames written to the current take (0 between takes).
    private(set) var framesWritten: AVAudioFramePosition = 0
    /// Every take of this recorder, oldest first.
    private(set) var takes: [RecordingTake] = []
    /// The validated format of the running capture.
    private(set) var captureFormat: CaptureFormat?
    /// The last error, already decoded for display.
    private(set) var lastError: String?
    /// Set while the capture is digital silence although the source app is playing.
    private(set) var silenceWarning: String?
    /// `true` while any take is being exported.
    var isConverting: Bool { takes.contains { if case .exporting = $0.status { true } else { false } } }
    /// The output of the most recently completed take.
    var lastCompletedURL: URL? { takes.last(where: { $0.status == .completed })?.outputURL }

    var process: AudioProcess { tap?.process ?? initialProcess }

    /// Seconds of digital silence since the capture started, while the source app reports that it is playing, before warning.
    static let digitalSilenceRecoverySeconds: Double = 2

    @ObservationIgnored private weak var tap: ProcessTap?
    @ObservationIgnored private let initialProcess: AudioProcess
    @ObservationIgnored private let settings: RecordingSettings
    @ObservationIgnored private let logger: Logger
    @ObservationIgnored private let ioQueue = DispatchQueue(label: "ProcessTapRecorder.io", qos: .userInteractive)
    @ObservationIgnored private let exportQueue = DispatchQueue(label: "ProcessTapRecorder.export", qos: .userInitiated)
    /// Only touched on `ioQueue` (main changes it with `ioQueue.sync`).
    @ObservationIgnored private var io = IOState()
    /// Main thread only.
    @ObservationIgnored private var pipeline: CapturePipeline?
    @ObservationIgnored private var session: SessionSettings?
    @ObservationIgnored private var meterTimer: Timer?
    @ObservationIgnored private var silenceGuard = DigitalSilenceGuard(seconds: ProcessTapRecorder.digitalSilenceRecoverySeconds)
    /// A non-zero sample arrived since `start()` (in any take or pipeline).
    @ObservationIgnored private var sessionHasSignal = false
    /// I/O cycles that arrived while no pipeline was attached (between takes or while gated).
    @ObservationIgnored private let unattachedCycles = AtomicCounter()
    @ObservationIgnored private var eventContinuations: [UUID: AsyncStream<TakeEvent>.Continuation] = [:]

    /// Settings frozen when recording starts.
    private struct SessionSettings {
        var outputFormat: RecordingSettings.OutputFormat
        var autoSplit: Bool
        var thresholdDb: Double
        var minSilenceDuration: Double
    }

    private struct IOState {
        var pipeline: CapturePipeline?
        /// Hi-Res monitor ring that receives a copy of the captured audio.
        var monitorRing: MonitorRingBuffer?
        /// Buffers between `.willReconfigure` and the next event are not valid.
        var isGated = false
    }

    init(tap: ProcessTap, outputDirectory: URL = .applicationSupport, settings: RecordingSettings = .shared) {
        self.tap = tap
        self.initialProcess = tap.process
        self.outputDirectory = outputDirectory
        self.settings = settings
        self.logger = Logger(subsystem: kAppSubsystem, category: "ProcessTapRecorder(\(tap.process.name))")
    }

    /// A stream of take changes for observers outside SwiftUI (library, auto-record). Ends when the recorder is released.
    @MainActor
    func takeEvents() -> AsyncStream<TakeEvent> {
        let id = UUID()
        return AsyncStream { continuation in
            eventContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                DispatchQueue.main.async { self?.eventContinuations[id] = nil }
            }
        }
    }

    // MARK: - Start / stop

    /// Starts recording. Throws a decoded error when the tap cannot start or its format is not usable.
    @MainActor
    func start() throws {
        guard status == .idle else {
            logger.warning("\(#function, privacy: .public) while already recording")
            return
        }
        guard let tap else { throw "The process tap is not available." }
        lastError = nil
        silenceGuard.reset()
        silenceWarning = nil
        sessionHasSignal = false
        session = SessionSettings(outputFormat: settings.outputFormat, autoSplit: settings.autoSplitOnSilence,
                                  thresholdDb: settings.silenceThresholdDb, minSilenceDuration: settings.minSilenceDuration)
        HiResController.shared.begin(for: tap)
        do {
            let format = try tap.start(on: ioQueue, ioBlock: { [weak self] _, inputData, inputTime, _, _ in
                self?.handleInput(inputData, time: inputTime)
            }, eventHandler: { [weak self] event in
                MainActor.assumeIsolated { self?.handle(event) }
            })
            if let format {
                setFormat(format)
                status = .recording
            } else {
                status = .waitingForSource
            }
        } catch {
            session = nil
            ioQueue.sync { io.monitorRing = nil }
            HiResController.shared.end()
            lastError = error.audioCapDescription
            logger.error("Start failed: \(error.audioCapDescription, privacy: .public)")
            throw error
        }
        startMeterTimer()
    }

    /// Stops recording: stops the device, drains pending buffers, closes and verifies the take, then exports it.
    @MainActor
    func stop() {
        guard status != .idle else { return }
        logger.debug(#function)

        tap?.stop()
        endPipeline()
        session = nil
        ioQueue.sync { io.monitorRing = nil }
        HiResController.shared.end()
        status = .idle
        stopMeterTimer()
    }

    // MARK: - Tap events

    @MainActor
    private func handle(_ event: ProcessTap.Event) {
        switch event {
        case .willReconfigure:
            ioQueue.sync {
                io.isGated = true
                // The restarted device has a new sample timeline; that is a reconnect, not a lost-audio jump.
                io.pipeline?.noteReconnect()
            }
        case .willStart(let format):
            // Install the pipeline before AudioDeviceStart so the first I/O cycles are kept.
            setFormat(format)
        case .reconfigured(let format):
            setFormat(format)
        case .sourceLost:
            endPipeline()
            status = .waitingForSource
        case .sourceRestored(let format):
            setFormat(format)
            status = .recording
        case .failed(let error):
            lastError = error.audioCapDescription
            stop()
        }
    }

    /// Applies a (new) capture format. A different format ends the current take; the next buffer starts a new one.
    @MainActor
    private func setFormat(_ format: CaptureFormat) {
        if let pipeline, pipeline.format == format {
            ioQueue.sync { io.isGated = false }
            return
        }
        if pipeline != nil {
            logger.info("Capture format changed to \(format.description, privacy: .public); starting a new take")
        }
        endPipeline()
        guard let session else { return }
        let detector = session.autoSplit ? SilenceDetector(thresholdDb: session.thresholdDb, minSilenceDuration: session.minSilenceDuration) : nil
        let options = CapturePipeline.Options(outputDirectory: outputDirectory, outputFormat: session.outputFormat,
                                              sourceName: process.name, silenceDetector: detector,
                                              makeBaseName: { [weak self] in self?.uniqueBaseName() ?? UUID().uuidString })
        let pipeline = CapturePipeline(format: format, options: options) { [weak self] event in
            DispatchQueue.main.async { self?.handle(event) }
        }
        self.pipeline = pipeline
        ioQueue.sync {
            io.pipeline = pipeline
            io.isGated = false
        }
        captureFormat = format
        HiResController.shared.formatChanged(format)
        let monitorRing = HiResController.shared.activeMonitor?.ringBuffer
        ioQueue.sync { io.monitorRing = monitorRing }
    }

    /// Detaches the pipeline from the I/O block, then drains and closes it.
    @MainActor
    private func endPipeline() {
        guard let pipeline else { return }
        ioQueue.sync { io.pipeline = nil }
        pipeline.finish()
        self.pipeline = nil
    }

    @MainActor
    private func handle(_ event: CapturePipeline.Event) {
        switch event {
        case .opened(let take):
            upsert(take, event: .added(take))
        case .closed(let take):
            upsert(take, event: .updated(take))
            if case .exporting = take.status { export(take) }
        case .discarded(let id):
            remove(id)
        case .failed(let message):
            lastError = message
            logger.error("\(message, privacy: .public)")
            stop()
        }
    }

    // MARK: - I/O path (ioQueue)

    /// Runs inside the I/O block: no allocation, locks or Objective-C messaging (see `CapturePipeline.process`).
    private func handleInput(_ inputData: UnsafePointer<AudioBufferList>, time: UnsafePointer<AudioTimeStamp>) {
        guard !io.isGated, let pipeline = io.pipeline else {
            unattachedCycles.value.add(1, ordering: .relaxed)
            return
        }
        pipeline.process(inputData, time: time)
        io.monitorRing?.write(inputData, format: pipeline.format)
    }

    // MARK: - Export (exportQueue)

    private func export(_ take: RecordingTake) {
        exportQueue.async { [self] in
            var take = take
            var lastReported = -1.0
            do {
                let result = try AudioExporter.export(from: take.captureURL, to: take.outputURL, format: take.outputFormat,
                                                      expectedFrames: take.capturedFrames) { progress in
                    guard progress - lastReported >= 0.05 || progress == 1 else { return }
                    lastReported = progress
                    var update = take
                    update.status = .exporting(progress: progress)
                    DispatchQueue.main.async { self.upsert(update, event: .updated(update)) }
                }
                try? FileManager.default.removeItem(at: take.captureURL)
                take.exportedFrames = result.frameCount
                take.status = .completed
                logger.info("Exported \(take.outputURL.lastPathComponent, privacy: .public): \(result.frameCount) frames")
            } catch {
                take.status = .failed(message: "Export to \(take.outputFormat.displayName) failed: \(error.audioCapDescription) The capture is kept at \(take.captureURL.lastPathComponent).")
                logger.error("Export failed: \(error.audioCapDescription, privacy: .public)")
            }
            DispatchQueue.main.async { self.upsert(take, event: .updated(take)) }
        }
    }

    // MARK: - Main-thread state

    private func upsert(_ take: RecordingTake, event: TakeEvent) {
        if let index = takes.firstIndex(where: { $0.id == take.id }) {
            // Ignore late progress updates once a take has reached a final state.
            if takes[index].status.isFinal, !take.status.isFinal { return }
            takes[index] = take
        } else {
            takes.append(take)
        }
        if case .failed(let message) = take.status { lastError = message }
        eventContinuations.values.forEach { $0.yield(event) }
    }

    private func remove(_ id: RecordingTake.ID) {
        takes.removeAll { $0.id == id }
        eventContinuations.values.forEach { $0.yield(.removed(id)) }
    }

    private func startMeterTimer() {
        meterTimer?.invalidate()
        meterTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 15.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.meterTick() }
        }
    }

    @MainActor
    private func meterTick() {
        guard let pipeline else {
            if level != .silence { level = .silence }
            if framesWritten != 0 { framesWritten = 0 }
            return
        }
        let newLevel = pipeline.level
        if level != newLevel { level = newLevel }
        let frames = AVAudioFramePosition(pipeline.currentTakeFrames.load(ordering: .relaxed))
        if framesWritten != frames { framesWritten = frames }
        checkDigitalSilence(pipeline)
    }

    /// Guards against a capture that never delivers signal (seen right after the permission is granted).
    /// See `DigitalSilenceGuard`: it only acts until the first non-zero sample of the session.
    @MainActor
    private func checkDigitalSilence(_ pipeline: CapturePipeline) {
        if pipeline.hasSeenSignal { sessionHasSignal = true }
        let silentSeconds = Double(pipeline.digitalSilenceRun.load(ordering: .relaxed)) / pipeline.format.sampleRate
        let wasArmed = silenceGuard.state != .disarmed
        silenceGuard.update(silentSeconds: silentSeconds, hasSeenSignal: sessionHasSignal,
                            sourceIsPlaying: wasArmed && (tap?.isSourceOutputting ?? false), sourceName: process.name)
        if silenceWarning != silenceGuard.warning {
            if silenceGuard.warning != nil {
                logger.warning("No signal for \(silentSeconds, privacy: .public) s since the capture started while the source is playing")
            }
            silenceWarning = silenceGuard.warning
        }
    }

    private func stopMeterTimer() {
        meterTimer?.invalidate()
        meterTimer = nil
        level = .silence
        framesWritten = 0
        silenceGuard.reset()
        silenceWarning = nil
    }

    private func uniqueBaseName() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let safeName = process.name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let stem = "\(safeName)-\(formatter.string(from: Date()))"
        var candidate = stem
        var counter = 2
        let extensions = ["caf"] + RecordingSettings.OutputFormat.allCases.map(\.fileExtension)
        while extensions.contains(where: { FileManager.default.fileExists(atPath: outputDirectory.appendingPathComponent(candidate).appendingPathExtension($0).path) }) {
            candidate = "\(stem)-\(counter)"
            counter += 1
        }
        return candidate
    }

    // MARK: - Diagnostics

    /// The "Copy diagnostics" report: OS, devices, tap and aggregate formats, file settings and recent takes.
    @MainActor
    func diagnosticsReport() -> String {
        var lines: [String] = ["AudioCap diagnostics", "Generated: \(ISO8601DateFormatter().string(from: Date()))"]
        lines.append("App: \(Diagnostics.appDescription)")
        lines.append("OS: \(Diagnostics.osDescription), \(ProcessInfo.processInfo.operatingSystemVersionString)")
        lines.append("Hardware: \(Diagnostics.hardwareModel ?? "?")")
        lines.append("Default output device: \((try? OutputDeviceInfo.currentDefault().description) ?? "unavailable")")
        if let system = try? AudioObjectID.readDefaultSystemOutputDevice(), let info = try? OutputDeviceInfo(id: system) {
            lines.append("Default system (alert) output device: \(info.description)")
        }
        let process = self.process
        lines.append("Source: \(process.name) (bundle \(process.bundleID ?? "none"), pid \(process.id), audio object \(process.objectID))")
        if let tap {
            lines.append("Source available: \(tap.isSourceAvailable), tap running: \(tap.isRunning)")
            lines.append("Aggregate clock device: \(tap.aggregateOutputDevice?.description ?? "none")")
            lines.append("Tap ASBD: \(tap.tapStreamDescription?.diagnosticDescription ?? "unavailable")")
            lines.append("Aggregate input ASBD: \(tap.aggregateStreamDescription?.diagnosticDescription ?? "unavailable") [\(tap.aggregateFormatSource ?? "-")]")
            lines.append("Aggregate nominal rate: \(tap.aggregateSampleRate.map { "\($0) Hz" } ?? "unavailable")")
            if let error = tap.lastFormatValidationError { lines.append("Format validation: \(error)") }
            if let error = tap.errorMessage { lines.append("Tap error: \(error)") }
            lines.append(contentsOf: HiResController.shared.diagnosticsLines)
            lines.append(contentsOf: tap.ioHistory.map { "I/O history: \($0)" })
        }
        lines.append("Capture format: \(captureFormat?.description ?? "none")")
        lines.append("I/O cycles with no pipeline attached: \(unattachedCycles.value.load(ordering: .relaxed))")
        if let pipeline {
            lines.append("Device timeline: \(pipeline.discontinuities.load(ordering: .relaxed)) jumps, \(pipeline.skippedFrames.load(ordering: .relaxed)) frames skipped")
            lines.append("Capture pipeline: \(pipeline.ioCycles.load(ordering: .relaxed)) I/O cycles, \(pipeline.layoutMismatches.load(ordering: .relaxed)) layout mismatches, \(pipeline.ring.overflowFrames.load(ordering: .relaxed)) overflow frames, ring \(pipeline.ring.capacity) frames, digital silence run \(pipeline.digitalSilenceRun.load(ordering: .relaxed)) frames")
        }
        if let silenceWarning { lines.append("Silence warning: \(silenceWarning)") }
        let writerFormat = captureFormat?.writerFormat
        if let writerFormat {
            lines.append("Capture file settings (CAF): \(Diagnostics.describe(settings: CaptureWriter.fileSettings(for: writerFormat)))")
        }
        let outputFormat = settings.outputFormat
        let rate = writerFormat?.sampleRate ?? 48_000
        let channels = writerFormat?.channelCount ?? 2
        lines.append("Export format: \(outputFormat.displayName), settings: \(Diagnostics.describe(settings: AudioExporter.fileSettings(for: outputFormat, sampleRate: rate, channelCount: channels)))")
        lines.append("Auto-split: \(settings.autoSplitOnSilence) (threshold \(settings.silenceThresholdDb) dB, min \(settings.minSilenceDuration) s)")
        lines.append("Last error: \(lastError ?? "none")")
        for take in takes.suffix(10) {
            lines.append("Take \(take.outputURL.lastPathComponent): \(take.status), \(take.capturedFrames) frames captured, exported \(take.exportedFrames.map(String.init) ?? "-"), format \(take.captureFormatDescription)\(take.warning.map { ", warning: \($0)" } ?? "")")
        }
        return lines.joined(separator: "\n")
    }
}
