@preconcurrency import AVFoundation
import SwiftUI
import AudioToolbox
import OSLog

/// A CoreAudio process tap on one app, plus the private aggregate device that delivers its audio.
///
/// Lifecycle:
/// - `activate()` creates the tap and the aggregate device (bound to the current default output device)
///   and starts following device changes, source quit/relaunch and wake from sleep.
/// - `start(on:ioBlock:eventHandler:)` starts I/O and returns the capture format, read and validated from the
///   aggregate's input stream **after** the device has started.
/// - `stop()` stops I/O (`AudioDeviceStop`) and keeps the tap ready for the next start.
/// - `invalidate()` destroys everything.
///
/// While running, changes are reported through `Event`s on the main thread.
@Observable
final class ProcessTap {

    /// Things that happen to a running tap. Delivered on the main thread.
    enum Event {
        /// I/O is about to stop for a rebuild (output device change, wake). Buffers until the next event are not valid.
        case willReconfigure
        /// I/O is about to start with this format, read from the aggregate before `AudioDeviceStart`.
        /// Prepare for it now so the first I/O cycles are not lost; the format read after start follows
        /// in `start`'s return value or in `.reconfigured`/`.sourceRestored`.
        case willStart(CaptureFormat)
        /// I/O restarted after a rebuild. The format may differ from the previous one.
        case reconfigured(CaptureFormat)
        /// The source app quit. The tap waits for it to come back.
        case sourceLost
        /// The source app is back (same bundle id) and I/O restarted.
        case sourceRestored(CaptureFormat)
        /// A rebuild or restart failed; I/O is stopped.
        case failed(Error)
    }

    typealias EventHandler = (Event) -> Void

    /// The tapped process. Updated when the app relaunches (new pid and audio object).
    private(set) var process: AudioProcess
    let muteWhenRunning: Bool
    private let logger: Logger

    /// A user-facing message for the last setup failure, with decoded status codes.
    private(set) var errorMessage: String? = nil
    /// The validated format of the running capture.
    private(set) var captureFormat: CaptureFormat?
    /// `false` while the source app is not running.
    private(set) var isSourceAvailable = true
    private(set) var isRunning = false

    // MARK: Diagnostics (last known values)

    @ObservationIgnored private(set) var tapStreamDescription: AudioStreamBasicDescription?
    @ObservationIgnored private(set) var aggregateStreamDescription: AudioStreamBasicDescription?
    @ObservationIgnored private(set) var aggregateFormatSource: String?
    @ObservationIgnored private(set) var aggregateSampleRate: Double?
    @ObservationIgnored private(set) var aggregateOutputDevice: OutputDeviceInfo?
    /// UID of the default output when the tap was created; rebuilding only the aggregate on another output keeps it.
    @ObservationIgnored private(set) var tapOutputUID: String?
    @ObservationIgnored private(set) var lastFormatValidationError: String?
    /// One line per input stream of the aggregate device, in buffer-list order.
    @ObservationIgnored private(set) var aggregateInputStreams: [String] = []
    /// Recent aggregate/tap/I/O events with their rates and buffer sizes, for the diagnostics report.
    @ObservationIgnored private(set) var ioHistory: [String] = []

    // MARK: CoreAudio objects

    @ObservationIgnored private var processTapID: AudioObjectID = .unknown
    @ObservationIgnored private var tapUUID = UUID()
    @ObservationIgnored private var aggregateDeviceID = AudioObjectID.unknown
    @ObservationIgnored private var deviceProcID: AudioDeviceIOProcID?

    @ObservationIgnored private var ioQueue: DispatchQueue?
    @ObservationIgnored private var ioBlock: AudioDeviceIOBlock?
    @ObservationIgnored private var eventHandler: EventHandler?
    /// `true` between `start` and `stop`, including while the source is gone.
    @ObservationIgnored private var wantsRunning = false

    @ObservationIgnored private var listeners: [AudioPropertyListener] = []
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?
    @ObservationIgnored private var pendingRebuild: DispatchWorkItem?
    /// Executable of the source, for recognizing a relaunch of a process without a bundle ID (e.g. `afplay`).
    @ObservationIgnored private var sourceExecutablePath: String?

    @ObservationIgnored
    private(set) var activated = false

    init(process: AudioProcess, muteWhenRunning: Bool = false) {
        self.process = process
        self.muteWhenRunning = muteWhenRunning
        self.logger = Logger(subsystem: kAppSubsystem, category: "\(String(describing: ProcessTap.self))(\(process.name))")
    }

    @MainActor
    func activate() {
        guard !activated else { return }
        activated = true

        logger.debug(#function)

        self.errorMessage = nil

        do {
            try prepare(for: process.objectID)
        } catch {
            logger.error("\(error.audioCapDescription, privacy: .public)")
            self.errorMessage = error.audioCapDescription
        }
        installObservers()
    }

    /// Stops I/O and destroys the aggregate device and the tap.
    func invalidate() {
        guard activated else { return }
        defer { activated = false }

        logger.debug(#function)

        removeObservers()
        wantsRunning = false
        stopIO()
        destroyAggregateAndTap()
        ioBlock = nil
        ioQueue = nil
        eventHandler = nil
    }

    // MARK: - Start / stop

    /// Starts I/O on the aggregate device and returns the validated capture format.
    ///
    /// The format is read from the aggregate's input stream after `AudioDeviceStart`, so it describes the buffers
    /// that `ioBlock` actually receives. Returns `nil` when the source app is not running: the tap starts by
    /// itself and sends `.sourceRestored` once the app is back.
    @MainActor
    @discardableResult
    func start(on queue: DispatchQueue, ioBlock: @escaping AudioDeviceIOBlock, eventHandler: @escaping EventHandler) throws -> CaptureFormat? {
        if !activated { activate() }
        if let errorMessage, aggregateDeviceID == .unknown, isSourceAvailable { throw errorMessage }

        self.ioQueue = queue
        self.ioBlock = ioBlock
        self.eventHandler = eventHandler
        self.wantsRunning = true

        guard isSourceAvailable else { return nil }
        do {
            try refreshIdleTap()
            return try startIO()
        } catch {
            wantsRunning = false
            self.eventHandler = nil
            throw error
        }
    }

    /// Stops I/O: `AudioDeviceStop`, then destroys the I/O proc. Blocks already queued on the I/O queue may still run;
    /// drain that queue afterwards.
    @MainActor
    func stop() {
        wantsRunning = false
        eventHandler = nil
        stopIO()
    }

    /// A tap left idle between selection and Start can deliver only zeros for a source that is already playing
    /// (seen at 48 kHz with `afplay` after ~40 s idle), so each Start uses a freshly created tap and aggregate.
    private func refreshIdleTap() throws {
        guard deviceProcID == nil, processTapID.isValid else { return }
        pendingRebuild?.cancel()
        destroyAggregateAndTap()
        try prepare(for: process.objectID)
    }

    private func startIO() throws -> CaptureFormat {
        guard let ioQueue, let ioBlock else { throw String(localized: "The capture queue is not configured.") }
        guard aggregateDeviceID.isValid else { throw errorMessage ?? String(localized: "The aggregate device is not available.") }

        errorMessage = nil
        logger.debug("Starting I/O")

        try checkStatus(AudioDeviceCreateIOProcIDWithBlock(&deviceProcID, aggregateDeviceID, ioQueue, ioBlock), "Creating the device I/O proc")
        do {
            if let provisional = try? readCaptureFormat() { eventHandler?(.willStart(provisional)) }
            configureBufferSize()
            try checkStatus(AudioDeviceStart(aggregateDeviceID, deviceProcID), "Starting the aggregate device")
            let format = try readCaptureFormat()
            let frames = (try? aggregateDeviceID.read(kAudioDevicePropertyBufferFrameSize, defaultValue: UInt32(0))) ?? 0
            noteIO("I/O started: \(format.description), buffer \(frames) frames, aggregate nominal \(aggregateSampleRate.map { "\($0)" } ?? "?") Hz")
            captureFormat = format
            isRunning = true
            logger.info("Capture format: \(format.description, privacy: .public) [\(format.sourceDescription.diagnosticDescription, privacy: .public)]")
            return format
        } catch {
            stopIO()
            errorMessage = error.audioCapDescription
            throw error
        }
    }

    /// At 176.4 kHz and above the default I/O buffer is short; a larger one avoids missed I/O cycles.
    /// `CaptureBufferFramesHighRate` in the defaults overrides the size (0 leaves the device's choice).
    private func configureBufferSize() {
        guard let rate = aggregateSampleRate, rate >= 176_400 else { return }
        let stored = UserDefaults.standard.object(forKey: "CaptureBufferFramesHighRate") as? Int
        let wanted = stored ?? 2048
        guard wanted > 0 else { return }
        let range = (try? aggregateDeviceID.read(kAudioDevicePropertyBufferFrameSizeRange, defaultValue: AudioValueRange()))
        var frames = UInt32(wanted)
        if let range, range.mMaximum > 0 {
            frames = UInt32(min(max(Double(wanted), range.mMinimum), range.mMaximum))
        }
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyBufferFrameSize, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let err = AudioObjectSetPropertyData(aggregateDeviceID, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &frames)
        noteIO("Buffer size request \(frames) frames at \(rate) Hz: \(err == noErr ? "ok" : AudioStatus.describe(err))")
    }

    private func noteIO(_ message: String) {
        let stamp = Date().formatted(.dateTime.hour().minute().second())
        ioHistory.append("\(stamp) \(message)")
        if ioHistory.count > 20 { ioHistory.removeFirst(ioHistory.count - 20) }
        logger.notice("\(message, privacy: .public)")
    }

    private func stopIO() {
        stopIO(deviceProcID, on: aggregateDeviceID)
        deviceProcID = nil
    }

    private func stopIO(_ procID: AudioDeviceIOProcID?, on device: AudioObjectID) {
        isRunning = false
        guard device.isValid, let procID else { return }
        var err = AudioDeviceStop(device, procID)
        if err != noErr { logger.warning("AudioDeviceStop: \(AudioStatus.describe(err), privacy: .public)") }
        err = AudioDeviceDestroyIOProcID(device, procID)
        if err != noErr { logger.warning("AudioDeviceDestroyIOProcID: \(AudioStatus.describe(err), privacy: .public)") }
    }

    // MARK: - Format

    /// Reads the format of the aggregate's input stream (the tap), validates and normalizes it.
    ///
    /// Only the tap's streams count: the aggregate also lists its sub-device's input streams first, which is
    /// what broke the old `AVAudioPCMBuffer(bufferListNoCopy:)` path on devices that have inputs.
    /// Tries the tap streams' virtual format first, then the tap format.
    /// A missing sample rate is filled from the aggregate's nominal rate.
    private func readCaptureFormat() throws -> CaptureFormat {
        aggregateSampleRate = try? aggregateDeviceID.readNominalSampleRate()
        tapStreamDescription = try? processTapID.readAudioTapStreamBasicDescription()

        let allStreams = (try? aggregateDeviceID.readStreams(scope: kAudioObjectPropertyScopeInput)) ?? []
        // The sub-device's own input streams (microphone, loopback input) come first in the buffer list.
        let subDeviceInputs = aggregateOutputDevice.flatMap { try? $0.id.readStreams(scope: kAudioObjectPropertyScopeInput).count } ?? 0
        let tapOffset = allStreams.count > subDeviceInputs ? subDeviceInputs : 0
        aggregateInputStreams = allStreams.enumerated().map { index, stream in
            let asbd = (try? stream.readStreamVirtualFormat())?.diagnosticDescription ?? "?"
            let terminal: UInt32 = (try? stream.read(kAudioStreamPropertyTerminalType, defaultValue: UInt32(0))) ?? 0
            let role = index < tapOffset ? "sub-device input" : "tap"
            return "#\(index) \(role) terminal=\(AudioStatus.fourCharCode(OSStatus(bitPattern: terminal)) ?? "\(terminal)") \(asbd)"
        }

        var candidates: [(String, AudioStreamBasicDescription, [AudioStreamBasicDescription])] = []
        let tapFormats = allStreams.dropFirst(tapOffset).compactMap { try? $0.readStreamVirtualFormat() }
        if let first = tapFormats.first {
            candidates.append(("aggregate input stream virtual format (tap streams \(tapOffset)..<\(allStreams.count))", first, tapFormats))
        }
        if let tapStreamDescription {
            candidates.append(("tap format", tapStreamDescription, [tapStreamDescription]))
        }

        var firstError: Error?
        for (source, asbd, streamFormats) in candidates {
            do {
                var format = try CaptureFormat(validating: asbd, fallbackSampleRate: aggregateSampleRate)
                format.firstBufferIndex = tapOffset
                format.bufferCount = streamFormats.count
                var source = source
                let delivered = CaptureFormat.deliveredRate(streamRate: format.sampleRate, aggregateRate: aggregateSampleRate)
                if delivered.overridden {
                    logger.warning("\(source, privacy: .public) says \(format.sampleRate, privacy: .public) Hz but the aggregate runs at \(delivered.rate, privacy: .public) Hz; using the aggregate's rate")
                    format.sampleRate = delivered.rate
                    source += ", rate from the aggregate's nominal rate"
                }
                let totalChannels = streamFormats.reduce(0) { $0 + Int($1.mChannelsPerFrame) }
                if totalChannels > format.channelCount {
                    // Several mono/stereo input streams: one buffer per stream, channels in stream order.
                    format.channelCount = totalChannels
                    format.isInterleaved = false
                }
                aggregateStreamDescription = asbd
                aggregateFormatSource = source
                lastFormatValidationError = firstError?.audioCapDescription
                return format
            } catch {
                logger.warning("Rejected \(source, privacy: .public): \(error.audioCapDescription, privacy: .public) [\(asbd.diagnosticDescription, privacy: .public)]")
                if firstError == nil {
                    firstError = error
                    aggregateStreamDescription = asbd
                    aggregateFormatSource = source
                }
            }
        }
        lastFormatValidationError = firstError?.audioCapDescription
        throw firstError ?? String(localized: "The aggregate device has no readable input stream format.")
    }

    // MARK: - Setup

    private func prepare(for objectID: AudioObjectID) throws {
        errorMessage = nil

        let tapDescription: CATapDescription
        if process.kind == .system {
            // AudioCap only has a process object once it has used audio; nothing to exclude before that.
            let ownObject = (try? AudioObjectID.translatePIDToProcessObjectID(pid: ProcessInfo.processInfo.processIdentifier)) ?? .unknown
            tapDescription = CATapDescription(stereoGlobalTapButExcludeProcesses: ownObject == .unknown ? [] : [ownObject])
        } else {
            tapDescription = CATapDescription(stereoMixdownOfProcesses: [objectID])
        }
        tapDescription.uuid = UUID()
        tapDescription.muteBehavior = muteWhenRunning ? .mutedWhenTapped : .unmuted
        var tapID: AUAudioObjectID = .unknown
        try checkStatus(AudioHardwareCreateProcessTap(tapDescription, &tapID), "Creating the process tap")

        logger.debug("Created process tap #\(tapID, privacy: .public)")

        self.processTapID = tapID
        self.tapUUID = tapDescription.uuid
        if let path = objectID.readProcessExecutablePath() { sourceExecutablePath = path }
        self.tapStreamDescription = try? tapID.readAudioTapStreamBasicDescription()

        try createAggregateDevice()
        tapOutputUID = aggregateOutputDevice?.uid
    }

    /// Creates the private aggregate device with the current default output device as its clock and the tap as input.
    private func createAggregateDevice() throws {
        let output = try OutputDeviceInfo.currentDefault()
        aggregateOutputDevice = output

        var description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Tap-\(process.id)",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: tapUUID.uuidString
                ]
            ]
        ]
        // The output device is named as the clock but deliberately not added as a sub-device: a sub-device
        // brings its input streams (a headset mic, a loopback driver's input) into the aggregate, which makes
        // starting I/O trigger the microphone permission prompt and, until it is answered, deliver silence.
        description[kAudioAggregateDeviceMainSubDeviceKey] = output.uid

        var deviceID = AudioObjectID.unknown
        try checkStatus(AudioHardwareCreateAggregateDevice(description as CFDictionary, &deviceID), "Creating the aggregate device")
        aggregateDeviceID = deviceID
        aggregateSampleRate = try? deviceID.readNominalSampleRate()
        // With no sub-devices the aggregate runs at the tap's rate; run it at the clock device's rate instead.
        // Every rebuild and tap recreation goes through here, so a reconnect re-applies it.
        if let rate = output.nominalSampleRate, rate > 0, aggregateSampleRate != rate {
            do {
                try deviceID.setNominalSampleRate(rate, name: "The tap aggregate")
                aggregateSampleRate = rate
            } catch {
                logger.warning("Could not run the aggregate at \(rate, privacy: .public) Hz: \(error.audioCapDescription, privacy: .public)")
            }
        }

        noteIO("Aggregate #\(deviceID) created on \(output.description), nominal \(aggregateSampleRate.map { "\($0)" } ?? "?") Hz")
    }

    private func destroyAggregateDevice() {
        guard aggregateDeviceID.isValid else { return }
        let err = AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
        if err != noErr { logger.warning("Destroying the aggregate device: \(AudioStatus.describe(err), privacy: .public)") }
        aggregateDeviceID = .unknown
    }

    private func destroyAggregateAndTap() {
        destroy(aggregate: aggregateDeviceID, tap: processTapID)
        aggregateDeviceID = .unknown
        processTapID = .unknown
    }

    private func destroy(aggregate: AudioObjectID, tap: AudioObjectID) {
        if aggregate.isValid {
            let err = AudioHardwareDestroyAggregateDevice(aggregate)
            if err != noErr { logger.warning("Destroying the aggregate device: \(AudioStatus.describe(err), privacy: .public)") }
        }
        if tap.isValid {
            let err = AudioHardwareDestroyProcessTap(tap)
            if err != noErr { logger.warning("Destroying the process tap: \(AudioStatus.describe(err), privacy: .public)") }
        }
    }

    // MARK: - Robustness (device changes, source quit/relaunch, wake)

    private func installObservers() {
        let rebuild: () -> Void = { [weak self] in self?.scheduleRebuild(reason: "default output device changed", delay: 0.3) }
        for selector in [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDefaultSystemOutputDevice] {
            if let listener = try? AudioPropertyListener(objectID: .system, selector: selector, handler: rebuild) {
                listeners.append(listener)
            }
        }
        if let listener = try? AudioPropertyListener(objectID: .system, selector: kAudioHardwarePropertyProcessObjectList, handler: { [weak self] in
            MainActor.assumeIsolated { self?.processListChanged() }
        }) {
            listeners.append(listener)
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.scheduleRebuild(reason: "wake from sleep", delay: 1.0, force: true)
        }
    }

    private func removeObservers() {
        listeners.forEach { $0.cancel() }
        listeners.removeAll()
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
        pendingRebuild?.cancel()
        pendingRebuild = nil
    }

    /// Rebuilds the aggregate on the current default output now, if it changed (Hi-Res routing switches the output).
    @MainActor
    func syncAggregateWithDefaultOutput() {
        guard activated else { return activate() }
        pendingRebuild?.cancel()
        pendingRebuild = nil
        rebuildAggregate(reason: "Hi-Res routing changed the output", force: false)
    }

    /// Rebuilds the aggregate even if the output device is the same, e.g. after its nominal rate changed.
    @MainActor
    func forceReconfigure(reason: String) {
        pendingRebuild?.cancel()
        pendingRebuild = nil
        rebuildAggregate(reason: reason, force: true)
    }

    private func scheduleRebuild(reason: String, delay: TimeInterval, force: Bool = false) {
        pendingRebuild?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.rebuildAggregate(reason: reason, force: force) }
        }
        pendingRebuild = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Rebuilds the aggregate device on the current default output and restarts I/O if it was running.
    @MainActor
    private func rebuildAggregate(reason: String, force: Bool) {
        guard activated, isSourceAvailable, processTapID.isValid else { return }
        let newOutputUID = try? OutputDeviceInfo.currentDefault().uid
        guard force || newOutputUID != aggregateOutputDevice?.uid else { return }

        logger.info("Rebuilding the aggregate device: \(reason, privacy: .public)")
        let wasRunning = wantsRunning && deviceProcID != nil
        if wasRunning { eventHandler?(.willReconfigure) }
        stopIO()
        destroyAggregateDevice()
        do {
            try createAggregateDevice()
            if wasRunning {
                let format = try startIO()
                eventHandler?(.reconfigured(format))
            }
        } catch {
            logger.error("Rebuild failed: \(error.audioCapDescription, privacy: .public)")
            errorMessage = error.audioCapDescription
            if wasRunning { eventHandler?(.failed(error)) }
        }
    }

    /// `true` when the source app reports that it is playing audio right now.
    var isSourceOutputting: Bool {
        isSourceAvailable && process.objectID.readProcessIsRunningOutput()
    }

    /// Replaces the tap and the aggregate device with fresh ones, restarting I/O if it was running.
    /// Used to refresh a tap idling on digital silence (see `IdleTapRefresh`); the silence guard only warns.
    /// The new tap and aggregate are built while the old ones still run, so capture stops only for the switch;
    /// if building fails, the old ones keep running.
    @MainActor
    func recreateTap(reason: String) {
        guard activated, isSourceAvailable else { return }
        noteIO("Recreating the tap: \(reason)")
        pendingRebuild?.cancel()
        let wasRunning = wantsRunning && deviceProcID != nil
        let old = (tap: processTapID, uuid: tapUUID, aggregate: aggregateDeviceID, proc: deviceProcID,
                   output: aggregateOutputDevice, rate: aggregateSampleRate, tapFormat: tapStreamDescription,
                   tapOutputUID: tapOutputUID)
        do {
            try prepare(for: process.objectID)
        } catch {
            logger.error("Recreating the tap failed, keeping the current one: \(error.audioCapDescription, privacy: .public)")
            if processTapID != old.tap { destroyAggregateAndTap() }
            (processTapID, tapUUID, aggregateDeviceID, deviceProcID) = (old.tap, old.uuid, old.aggregate, old.proc)
            (aggregateOutputDevice, aggregateSampleRate, tapStreamDescription) = (old.output, old.rate, old.tapFormat)
            tapOutputUID = old.tapOutputUID
            return
        }
        if wasRunning {
            eventHandler?(.willReconfigure)
            stopIO(old.proc, on: old.aggregate)
            deviceProcID = nil
            do {
                let format = try startIO()
                eventHandler?(.reconfigured(format))
            } catch {
                logger.error("Recreating the tap failed: \(error.audioCapDescription, privacy: .public)")
                errorMessage = error.audioCapDescription
                eventHandler?(.failed(error))
            }
        }
        destroy(aggregate: old.aggregate, tap: old.tap)
    }

    @MainActor
    private func processListChanged() {
        guard activated, process.kind != .system, let objects = try? AudioObjectID.readProcessList() else { return }

        if isSourceAvailable {
            guard !objects.contains(process.objectID) else { return }
            logger.info("Source process quit")
            stopIO()
            destroyAggregateAndTap()
            isSourceAvailable = false
            if wantsRunning { eventHandler?(.sourceLost) }
            return
        }

        guard let objectID = objects.first(where: {
            Self.isRelaunch(bundleID: process.bundleID, executablePath: sourceExecutablePath,
                            candidateBundleID: $0.readProcessBundleID(), candidatePath: $0.readProcessExecutablePath())
        }) else { return }
        logger.info("Source process relaunched: \(self.process.bundleID ?? self.sourceExecutablePath ?? "?", privacy: .public)")
        process.objectID = objectID
        if let pid = objectID.readProcessPID() { process.id = pid }
        do {
            try prepare(for: objectID)
            isSourceAvailable = true
            if wantsRunning {
                let format = try startIO()
                eventHandler?(.sourceRestored(format))
            }
        } catch {
            logger.error("Re-arming failed: \(error.audioCapDescription, privacy: .public)")
            errorMessage = error.audioCapDescription
            isSourceAvailable = true
            if wantsRunning { eventHandler?(.failed(error)) }
        }
    }

    /// Whether a process object is a relaunch of the source: same bundle ID, or, for processes without one
    /// (command-line players such as `afplay`), the same executable.
    nonisolated static func isRelaunch(bundleID: String?, executablePath: String?, candidateBundleID: String?, candidatePath: String?) -> Bool {
        if let bundleID { return candidateBundleID == bundleID }
        guard let executablePath else { return false }
        return candidateBundleID == nil && candidatePath == executablePath
    }

    deinit { invalidate() }
}
