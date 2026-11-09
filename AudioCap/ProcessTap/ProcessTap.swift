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
    @ObservationIgnored private(set) var lastFormatValidationError: String?
    /// One line per input stream of the aggregate device, in buffer-list order.
    @ObservationIgnored private(set) var aggregateInputStreams: [String] = []

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

    private func startIO() throws -> CaptureFormat {
        guard let ioQueue, let ioBlock else { throw "The capture queue is not configured." }
        guard aggregateDeviceID.isValid else { throw errorMessage ?? "The aggregate device is not available." }

        errorMessage = nil
        logger.debug("Starting I/O")

        try checkStatus(AudioDeviceCreateIOProcIDWithBlock(&deviceProcID, aggregateDeviceID, ioQueue, ioBlock), "Creating the device I/O proc")
        do {
            if let provisional = try? readCaptureFormat() { eventHandler?(.willStart(provisional)) }
            try checkStatus(AudioDeviceStart(aggregateDeviceID, deviceProcID), "Starting the aggregate device")
            let format = try readCaptureFormat()
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

    private func stopIO() {
        isRunning = false
        guard aggregateDeviceID.isValid, let deviceProcID else { return }
        var err = AudioDeviceStop(aggregateDeviceID, deviceProcID)
        if err != noErr { logger.warning("AudioDeviceStop: \(AudioStatus.describe(err), privacy: .public)") }
        err = AudioDeviceDestroyIOProcID(aggregateDeviceID, deviceProcID)
        if err != noErr { logger.warning("AudioDeviceDestroyIOProcID: \(AudioStatus.describe(err), privacy: .public)") }
        self.deviceProcID = nil
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
                // The I/O cycle runs on the aggregate's clock, so buffers carry frames at its nominal rate even when
                // the tap's own format still reports the process's rate (e.g. 48 kHz tap, 96 kHz Hi-Res aggregate).
                var source = source
                if let aggregateSampleRate, aggregateSampleRate.isFinite, aggregateSampleRate > 0,
                   format.sampleRate != aggregateSampleRate {
                    logger.warning("\(source, privacy: .public) says \(format.sampleRate, privacy: .public) Hz but the aggregate runs at \(aggregateSampleRate, privacy: .public) Hz; using the aggregate's rate")
                    format.sampleRate = aggregateSampleRate
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
        throw firstError ?? "The aggregate device has no readable input stream format."
    }

    // MARK: - Setup

    private func prepare(for objectID: AudioObjectID) throws {
        errorMessage = nil

        let tapDescription = CATapDescription(stereoMixdownOfProcesses: [objectID])
        tapDescription.uuid = UUID()
        tapDescription.muteBehavior = muteWhenRunning ? .mutedWhenTapped : .unmuted
        var tapID: AUAudioObjectID = .unknown
        try checkStatus(AudioHardwareCreateProcessTap(tapDescription, &tapID), "Creating the process tap")

        logger.debug("Created process tap #\(tapID, privacy: .public)")

        self.processTapID = tapID
        self.tapUUID = tapDescription.uuid
        self.tapStreamDescription = try? tapID.readAudioTapStreamBasicDescription()

        try createAggregateDevice()
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
        // Without sub-devices the aggregate runs at the tap's rate. In Hi-Res mode it must run at the Hi-Res rate.
        if output.uid == HiResDevice.uid, let rate = output.nominalSampleRate, aggregateSampleRate != rate {
            do {
                try deviceID.setNominalSampleRate(rate, name: "The tap aggregate")
                aggregateSampleRate = rate
            } catch {
                logger.warning("Could not run the aggregate at the Hi-Res rate: \(error.audioCapDescription, privacy: .public)")
            }
        }

        logger.debug("Created aggregate device #\(deviceID, privacy: .public) on \(output.description, privacy: .public)")
    }

    private func destroyAggregateDevice() {
        guard aggregateDeviceID.isValid else { return }
        let err = AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
        if err != noErr { logger.warning("Destroying the aggregate device: \(AudioStatus.describe(err), privacy: .public)") }
        aggregateDeviceID = .unknown
    }

    private func destroyAggregateAndTap() {
        destroyAggregateDevice()
        if processTapID.isValid {
            let err = AudioHardwareDestroyProcessTap(processTapID)
            if err != noErr { logger.warning("Destroying the process tap: \(AudioStatus.describe(err), privacy: .public)") }
            processTapID = .unknown
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

    /// Destroys and recreates the tap and the aggregate device, restarting I/O if it was running.
    /// Used when a running tap delivers only silence although the source is playing.
    @MainActor
    func recreateTap(reason: String) {
        guard activated, isSourceAvailable else { return }
        logger.info("Recreating the tap: \(reason, privacy: .public)")
        pendingRebuild?.cancel()
        let wasRunning = wantsRunning && deviceProcID != nil
        if wasRunning { eventHandler?(.willReconfigure) }
        stopIO()
        destroyAggregateAndTap()
        do {
            try prepare(for: process.objectID)
            if wasRunning {
                let format = try startIO()
                eventHandler?(.reconfigured(format))
            }
        } catch {
            logger.error("Recreating the tap failed: \(error.audioCapDescription, privacy: .public)")
            errorMessage = error.audioCapDescription
            if wasRunning { eventHandler?(.failed(error)) }
        }
    }

    @MainActor
    private func processListChanged() {
        guard activated, let objects = try? AudioObjectID.readProcessList() else { return }

        if isSourceAvailable {
            guard !objects.contains(process.objectID) else { return }
            logger.info("Source process quit")
            stopIO()
            destroyAggregateAndTap()
            isSourceAvailable = false
            if wantsRunning { eventHandler?(.sourceLost) }
            return
        }

        guard let bundleID = process.bundleID,
              let objectID = objects.first(where: { $0.readProcessBundleID() == bundleID }) else { return }
        logger.info("Source process relaunched: \(bundleID, privacy: .public)")
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

    deinit { invalidate() }
}
