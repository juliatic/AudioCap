@preconcurrency import AVFoundation
import Observation
import OSLog
import os

/// Records a `ProcessTap` into takes and exports each take when it ends.
///
/// Data path: the aggregate device's I/O block runs on `ioQueue`, copies each buffer into the canonical
/// Float32 format (`CaptureBufferCopier`), measures its level, applies silence splitting and hands it to the
/// take's `CaptureWriter`, which owns the CAF file. When a take ends, the writer is drained, closed and its
/// frame count verified; then `AudioExporter` converts it on `exportQueue` and checks the output duration.
///
/// Stop order: `AudioDeviceStop` → drain `ioQueue` → drain and close the writer → verify frames → export.
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
    /// The take state machine's phase, refreshed with the level (`.armed` while waiting for sound).
    private(set) var autoRecordPhase: AutoRecordMachine.Phase = .idle
    /// The recording mode of the running session (or of the next one while idle).
    private(set) var mode: AutoRecordMachine.Mode
    /// Running in "Wait for sound" mode with no take open.
    var isWaitingForSound: Bool { status == .recording && autoRecordPhase == .armed }
    /// Every take of this recorder, oldest first.
    private(set) var takes: [RecordingTake] = []
    /// The validated format of the running capture.
    private(set) var captureFormat: CaptureFormat?
    /// The last error, already decoded for display.
    private(set) var lastError: String?
    /// `true` while any take is being exported.
    var isConverting: Bool { takes.contains { if case .exporting = $0.status { true } else { false } } }
    /// The output of the most recently completed take.
    var lastCompletedURL: URL? { takes.last(where: { $0.status == .completed })?.outputURL }

    var process: AudioProcess { tap?.process ?? initialProcess }

    @ObservationIgnored private weak var tap: ProcessTap?
    @ObservationIgnored private let initialProcess: AudioProcess
    @ObservationIgnored private let settings: RecordingSettings
    @ObservationIgnored private let autoRecordSettings: AutoRecordSettings
    @ObservationIgnored private let logger: Logger
    @ObservationIgnored private let ioQueue = DispatchQueue(label: "ProcessTapRecorder.io", qos: .userInteractive)
    @ObservationIgnored private let exportQueue = DispatchQueue(label: "ProcessTapRecorder.export", qos: .userInitiated)
    /// Only touched on `ioQueue`.
    @ObservationIgnored private var io = IOState()
    @ObservationIgnored private let meter = OSAllocatedUnfairLock(initialState: Meter())
    @ObservationIgnored private var meterTimer: Timer?
    @ObservationIgnored private var eventContinuations: [UUID: AsyncStream<TakeEvent>.Continuation] = [:]

    /// Settings frozen when recording starts.
    private struct SessionSettings {
        var outputFormat: RecordingSettings.OutputFormat
        var autoSplit: Bool
        var detector: SilenceDetector
        var autoRecord: AutoRecordMachine.Configuration
    }

    private struct IOState {
        var format: CaptureFormat?
        var writerFormat: AVAudioFormat?
        var session: SessionSettings?
        var writer: CaptureWriter?
        var take: RecordingTake?
        /// Decides when takes open and close. Created on the main thread for each capture format.
        var machine: AutoRecordMachine?
        var mode: AutoRecordMachine.Mode = .waitForSound
        var droppedBuffers: Int64 = 0
        var reportedLayoutMismatch = false
    }

    private struct Meter {
        var level: AudioLevel = .silence
        var frames: AVAudioFramePosition = 0
        var phase: AutoRecordMachine.Phase = .idle
    }

    init(tap: ProcessTap, outputDirectory: URL = .applicationSupport, settings: RecordingSettings = .shared,
         autoRecordSettings: AutoRecordSettings = .shared) {
        self.tap = tap
        self.initialProcess = tap.process
        self.outputDirectory = outputDirectory
        self.settings = settings
        self.autoRecordSettings = autoRecordSettings
        self.mode = autoRecordSettings.mode
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

        let session = SessionSettings(
            outputFormat: settings.outputFormat,
            autoSplit: settings.autoSplitOnSilence,
            detector: SilenceDetector(thresholdDb: settings.silenceThresholdDb, minSilenceDuration: settings.minSilenceDuration),
            autoRecord: autoRecordSettings.configuration
        )
        let mode = autoRecordSettings.mode
        self.mode = mode
        ioQueue.sync {
            io = IOState()
            io.session = session
            io.mode = mode
        }

        do {
            let format = try tap.start(on: ioQueue, ioBlock: { [weak self] _, inputData, _, _, _ in
                self?.handleInput(inputData)
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
            ioQueue.sync { io = IOState() }
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
        ioQueue.sync {
            io.format = nil
            if let machine = io.machine {
                var sink = RecorderTakeSink(recorder: self)
                machine.stop(sink: &sink)
            }
            finishTake()
            io.machine = nil
            io.session = nil
        }
        status = .idle
        stopMeterTimer()
    }

    // MARK: - Tap events

    @MainActor
    private func handle(_ event: ProcessTap.Event) {
        switch event {
        case .willReconfigure:
            ioQueue.sync { io.format = nil }
        case .reconfigured(let format):
            setFormat(format)
        case .sourceLost:
            ioQueue.sync {
                io.format = nil
                endTake()
            }
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
        let previous = captureFormat
        let writerFormat = format.writerFormat
        // Allocated here, before the format reaches the I/O path; used only if the format changed.
        let candidate = ioQueue.sync { io.session?.autoRecord }.map { configuration in
            AutoRecordMachine(configuration: configuration, format: writerFormat, mode: mode)
        }
        ioQueue.sync {
            if let current = io.take?.captureFormat, current != format {
                logger.info("Capture format changed to \(format.description, privacy: .public); starting a new take")
                endTake()
            }
            io.format = format
            io.writerFormat = writerFormat
            if let candidate, io.machine.map({ !$0.format.isEqual(writerFormat) }) ?? true {
                if io.take != nil { endTake() }
                candidate.start()
                io.machine = candidate
            }
        }
        if previous != format { captureFormat = format }
    }

    /// Switches between "Wait for sound" and manual. Applies to the running session at once.
    @MainActor
    func setMode(_ newMode: AutoRecordMachine.Mode) {
        guard newMode != mode else { return }
        mode = newMode
        ioQueue.sync {
            io.mode = newMode
            guard let machine = io.machine else { return }
            var sink = RecorderTakeSink(recorder: self)
            machine.setMode(newMode, sink: &sink)
            let phase = machine.phase
            meter.withLock { $0.phase = phase }
        }
    }

    // MARK: - I/O path (ioQueue)

    private func handleInput(_ inputData: UnsafePointer<AudioBufferList>) {
        guard let format = io.format, let writerFormat = io.writerFormat, io.session != nil else {
            io.droppedBuffers += 1
            return
        }
        guard let copy = CaptureBufferCopier.copy(inputData, format: format, writerFormat: writerFormat) else { return }
        if copy.layoutMismatch, !io.reportedLayoutMismatch {
            io.reportedLayoutMismatch = true
            logger.warning("Buffer layout differs from the declared format \(format.description, privacy: .public)")
        }
        let buffer = copy.buffer
        let level = AudioLevel(measuring: buffer)
        meter.withLock { $0.level = level }

        // Auto-split only applies to manual mode; "Wait for sound" closes takes on silence by itself.
        if io.mode == .manual, io.session!.autoSplit {
            let analysis = io.session!.detector.process(level: level, duration: Double(buffer.frameLength) / buffer.format.sampleRate)
            if analysis.didTriggerSplit {
                logger.info("Silence of \(analysis.silentDuration, privacy: .public) s: splitting")
                endTake()
            }
            if analysis.shouldDrop { return }
        }

        guard let machine = io.machine else { return }
        var sink = RecorderTakeSink(recorder: self, format: format, writerFormat: writerFormat)
        machine.process(buffer, level: level, sink: &sink)
        let phase = machine.phase
        meter.withLock { $0.phase = phase }
    }

    /// Ends the open take through the state machine, which re-arms (wait for sound) or reopens on the next buffer.
    private func endTake() {
        if let machine = io.machine {
            var sink = RecorderTakeSink(recorder: self)
            machine.endTake(sink: &sink)
            let phase = machine.phase
            meter.withLock { $0.phase = phase }
        }
        finishTake()
    }

    /// Connects `AutoRecordMachine` to the take files. Used on `ioQueue` only.
    private struct RecorderTakeSink: TakeSink {
        unowned let recorder: ProcessTapRecorder
        var format: CaptureFormat?
        var writerFormat: AVAudioFormat?

        mutating func openTake() -> Bool {
            guard let format = format ?? recorder.io.format, let writerFormat = writerFormat ?? recorder.io.writerFormat else { return false }
            return recorder.openTake(format: format, writerFormat: writerFormat)
        }

        mutating func write(_ buffer: AVAudioPCMBuffer) {
            guard let writer = recorder.io.writer else { return }
            writer.append(buffer)
            recorder.meter.withLock { $0.frames += AVAudioFramePosition(buffer.frameLength) }
        }

        mutating func closeTake() {
            recorder.finishTake()
        }
    }

    private func openTake(format: CaptureFormat, writerFormat: AVAudioFormat) -> Bool {
        guard let session = io.session else { return false }
        let base = uniqueBaseName()
        let captureURL = outputDirectory.appendingPathComponent(base).appendingPathExtension("caf")
        let outputURL = outputDirectory.appendingPathComponent(base).appendingPathExtension(session.outputFormat.fileExtension)
        let take = RecordingTake(id: UUID(), sourceName: process.name, startedAt: Date(), captureURL: captureURL,
                                 outputURL: outputURL, outputFormat: session.outputFormat, captureFormat: format)
        do {
            io.writer = try CaptureWriter(url: captureURL, format: writerFormat)
            io.take = take
            meter.withLock { $0.frames = 0 }
            DispatchQueue.main.async { self.upsert(take, event: .added(take)) }
            return true
        } catch {
            let message = error.audioCapDescription
            logger.error("Could not create the capture file: \(message, privacy: .public)")
            io.session = nil
            DispatchQueue.main.async {
                self.lastError = "Could not create the capture file: \(message)"
                self.stop()
            }
            return false
        }
    }

    /// Ends the current take: drains and closes the writer, verifies its length and queues the export.
    private func finishTake() {
        guard let writer = io.writer, var take = io.take else { return }
        io.writer = nil
        io.take = nil
        meter.withLock { $0.frames = 0 }

        do {
            take.capturedFrames = try writer.finish()
        } catch {
            take.capturedFrames = writer.framesWritten
            take.status = .failed(message: "Capture failed: \(error.audioCapDescription)")
            DispatchQueue.main.async { self.upsert(take, event: .updated(take)) }
            return
        }

        guard take.capturedFrames > 0 else {
            try? FileManager.default.removeItem(at: take.captureURL)
            DispatchQueue.main.async { self.remove(take.id) }
            return
        }
        take.status = .exporting(progress: 0)
        DispatchQueue.main.async { self.upsert(take, event: .updated(take)) }
        export(take)
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
            guard let self else { return }
            let snapshot = self.meter.withLock { $0 }
            if self.level != snapshot.level { self.level = snapshot.level }
            if self.framesWritten != snapshot.frames { self.framesWritten = snapshot.frames }
            if self.autoRecordPhase != snapshot.phase { self.autoRecordPhase = snapshot.phase }
        }
    }

    private func stopMeterTimer() {
        meterTimer?.invalidate()
        meterTimer = nil
        level = .silence
        framesWritten = 0
        autoRecordPhase = .idle
        meter.withLock { $0 = Meter() }
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
        }
        lines.append("Capture format: \(captureFormat?.description ?? "none")")
        let writerFormat = captureFormat?.writerFormat
        if let writerFormat {
            lines.append("Capture file settings (CAF): \(Diagnostics.describe(settings: CaptureWriter.fileSettings(for: writerFormat)))")
        }
        let outputFormat = settings.outputFormat
        let rate = writerFormat?.sampleRate ?? 48_000
        let channels = writerFormat?.channelCount ?? 2
        lines.append("Export format: \(outputFormat.displayName), settings: \(Diagnostics.describe(settings: AudioExporter.fileSettings(for: outputFormat, sampleRate: rate, channelCount: channels)))")
        let auto = autoRecordSettings.configuration
        lines.append("Recording mode: \(mode.rawValue), phase \(autoRecordPhase) (threshold \(auto.thresholdDb) dBFS RMS, close after \(auto.minSilence) s, pre-roll \(auto.preRoll) s, tail \(auto.tail) s)")
        lines.append("Auto-split (manual mode): \(settings.autoSplitOnSilence) (threshold \(settings.silenceThresholdDb) dB, min \(settings.minSilenceDuration) s)")
        lines.append("Last error: \(lastError ?? "none")")
        for take in takes.suffix(10) {
            lines.append("Take \(take.outputURL.lastPathComponent): \(take.status), \(take.capturedFrames) frames captured, exported \(take.exportedFrames.map(String.init) ?? "-"), format \(take.captureFormatDescription)")
        }
        return lines.joined(separator: "\n")
    }
}
