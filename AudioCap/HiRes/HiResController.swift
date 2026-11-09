import AppKit
import CoreAudio
import Observation
import OSLog

/// Orchestrates Hi-Res mode for a recording: rate policy, routing, monitor and restoring the output.
///
/// The recorder calls `begin(for:)` before starting the tap, `formatChanged(_:)` whenever the capture format is known or
/// changes, and `end()` when it stops. Quitting restores the output; the next launch does too after a crash.
@MainActor
@Observable
final class HiResController {
    static let shared = HiResController()

    let settings: HiResSettings
    private(set) var isDriverAvailable = false
    private(set) var rateDecision: HiResRatePolicy.Decision?
    private(set) var monitorDevice: AudioOutputDevice?
    private(set) var monitorOutputRate: Double?
    /// Last notice for the UI (device lost, start failure, crash recovery). Localized.
    private(set) var message: String?

    var isRouted: Bool { router.isRouted }
    /// The monitor while routed; the recorder pushes captured buffers into it on its capture queue.
    var activeMonitor: AudioMonitor? { router.isRouted ? monitor : nil }

    var monitorVolume: Float {
        get { settings.monitorVolume }
        set { settings.monitorVolume = newValue; monitor.volume = newValue }
    }

    var isMonitorMuted: Bool {
        get { settings.isMonitorMuted }
        set { settings.isMonitorMuted = newValue; monitor.isMuted = newValue }
    }

    @ObservationIgnored private let system: CoreAudioOutputSystem
    @ObservationIgnored private let router: HiResRouter
    @ObservationIgnored private let monitor = AudioMonitor()
    @ObservationIgnored private weak var tap: ProcessTap?
    @ObservationIgnored private var captureFormat: CaptureFormat?
    @ObservationIgnored private var deviceListListener: AudioPropertyListener?
    @ObservationIgnored private var routeListeners: [AudioPropertyListener] = []
    @ObservationIgnored private var musicObserver: NSObjectProtocol?
    @ObservationIgnored private var terminateObserver: NSObjectProtocol?
    @ObservationIgnored private var didRecover = false
    @ObservationIgnored private let logger = Logger(subsystem: kAppSubsystem, category: "HiResController")

    init(settings: HiResSettings = .shared, system: CoreAudioOutputSystem = CoreAudioOutputSystem(), store: HiResRestoreStore = HiResRestoreStore()) {
        self.settings = settings
        self.system = system
        self.router = HiResRouter(system: system, store: store)
        monitor.volume = settings.monitorVolume
        monitor.isMuted = settings.isMonitorMuted
    }

    /// Call once at launch: restores an output left on the Hi-Res device by a crash and watches for the driver.
    func recoverOnLaunch() {
        guard !didRecover else { return }
        didRecover = true
        QualityPathContributors.register(HiResQualityContributor.shared)
        if let restored = router.recoverAfterCrash() {
            message = String(localized: "Restored the output to \(restored.name) after AudioCap last quit unexpectedly.")
        }
        isDriverAvailable = router.isVirtualDeviceAvailable
        deviceListListener = try? AudioPropertyListener(objectID: .system, selector: kAudioHardwarePropertyDevices) { [weak self] in
            self?.deviceListChanged()
        }
        terminateObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.end() }
        }
    }

    // MARK: - Recording hooks

    /// Routes the system output to the Hi-Res device (when enabled and installed) and rebuilds `tap`'s aggregate on it.
    func begin(for tap: ProcessTap) {
        recoverOnLaunch()
        isDriverAvailable = router.isVirtualDeviceAvailable
        guard settings.isEnabled, isDriverAvailable, !router.isRouted else { return }
        self.tap = tap
        message = nil

        let isMusic = tap.process.bundleID == HiResRatePolicy.musicBundleID
        let trackRate = isMusic ? MusicTrackRate.fetch(timeout: 1.5) { [weak self] rate in self?.applyMusicRate(rate) } : nil
        let decision = HiResRatePolicy.decide(sourceBundleID: tap.process.bundleID, musicTrackRate: trackRate, fixedRate: settings.fixedRate)
        do {
            let target = try router.route(rate: decision.rate)
            rateDecision = decision
            monitorDevice = target
            installRouteListeners(observeMusic: isMusic)
        } catch {
            logger.error("Hi-Res routing failed: \(error.audioCapDescription, privacy: .public)")
            message = String(localized: "Hi-Res could not start: \(error.audioCapDescription). Recording without it.")
            self.tap = nil
        }
        tap.syncAggregateWithDefaultOutput()
    }

    /// The capture format is known or changed: (re)starts the monitor at that rate.
    func formatChanged(_ format: CaptureFormat) {
        captureFormat = format
        guard router.isRouted else { return }
        restartMonitor()
    }

    /// Stops the monitor and restores the remembered output.
    func end() {
        removeRouteListeners()
        monitor.stop()
        monitorOutputRate = nil
        captureFormat = nil
        guard router.isRouted else { return }
        router.restore()
        rateDecision = nil
        monitorDevice = nil
        tap?.syncAggregateWithDefaultOutput()
        tap = nil
    }

    /// The Hi-Res route the next take of `sourceBundleID` would use, while idle with Hi-Res on and the driver installed.
    /// The rate is the fixed rate for Music too, because its track rate is only read when a take starts.
    func nextTake(sourceBundleID: String?) -> (monitor: AudioOutputDevice, rate: Double)? {
        guard settings.isEnabled else { return nil }
        let decision = HiResRatePolicy.decide(sourceBundleID: sourceBundleID, musicTrackRate: nil, fixedRate: settings.fixedRate)
        guard case .routed(let monitor, let rate) = router.nextRoute(rate: decision.rate) else { return nil }
        return (monitor, rate)
    }

    var diagnosticsLines: [String] {
        var lines = ["Hi-Res: enabled \(settings.isEnabled), driver \(isDriverAvailable ? "available" : "missing"), fixed rate \(settings.fixedRate) Hz"]
        if let rate = router.rate { lines.append("Hi-Res routed at \(rate) Hz (\(rateDecision.map { "\($0.source)" } ?? "-")), monitor: \(monitorDevice?.name ?? "-") at \(monitorOutputRate.map { "\($0) Hz" } ?? "-")") }
        return lines
    }

    // MARK: - Events

    private func restartMonitor() {
        guard let format = captureFormat, let device = router.monitorTarget else { return }
        do {
            try monitor.start(format: format, device: device, deviceID: system.deviceID(uid: device.uid))
            monitorDevice = device
            monitorOutputRate = monitor.outputSampleRate
        } catch {
            logger.error("Monitor failed: \(error.audioCapDescription, privacy: .public)")
            monitorOutputRate = nil
            message = String(localized: "Monitor unavailable: \(error.audioCapDescription)")
        }
    }

    private func handle(_ event: HiResRouter.Event?) {
        switch event {
        case .monitorTargetChanged(let device):
            monitorDevice = device
            restartMonitor()
        case .virtualDeviceLost(let restored):
            let name = restored?.name ?? "-"
            message = String(localized: "AudioCap Hi-Res disappeared. The output is back on \(name); recording continues at that device's rate.")
            removeRouteListeners()
            monitor.stop()
            rateDecision = nil
            monitorDevice = nil
            monitorOutputRate = nil
        case nil:
            break
        }
    }

    private func deviceListChanged() {
        isDriverAvailable = router.isVirtualDeviceAvailable
        handle(router.deviceListChanged())
    }

    private func nominalRateChanged() {
        guard router.isRouted, let tap, let rate = try? system.deviceID(uid: HiResDevice.uid).readNominalSampleRate(),
              rate != tap.aggregateSampleRate else { return }
        logger.info("\(HiResDevice.name, privacy: .public) now runs at \(rate, privacy: .public) Hz; rebuilding the tap")
        tap.forceReconfigure(reason: "Hi-Res rate changed to \(rate) Hz")
    }

    private func applyMusicRate(_ rate: Double?) {
        guard router.isRouted, let tap else { return }
        let decision = HiResRatePolicy.decide(sourceBundleID: tap.process.bundleID, musicTrackRate: rate, fixedRate: settings.fixedRate)
        guard decision != rateDecision else { return }
        do {
            try router.setRate(decision.rate)
            rateDecision = decision
            nominalRateChanged()
        } catch {
            logger.error("Could not apply the Music track rate: \(error.audioCapDescription, privacy: .public)")
        }
    }

    private func installRouteListeners(observeMusic: Bool) {
        removeRouteListeners()
        if let listener = try? AudioPropertyListener(objectID: .system, selector: kAudioHardwarePropertyDefaultOutputDevice, handler: { [weak self] in
            guard let self else { return }
            handle(router.defaultOutputChanged())
        }) { routeListeners.append(listener) }
        if let id = try? system.deviceID(uid: HiResDevice.uid),
           let listener = try? AudioPropertyListener(objectID: id, selector: kAudioDevicePropertyNominalSampleRate, handler: { [weak self] in
               self?.nominalRateChanged()
           }) { routeListeners.append(listener) }
        if observeMusic {
            musicObserver = DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.apple.Music.playerInfo"), object: nil, queue: .main) { [weak self] _ in
                MusicTrackRate.fetch { rate in
                    DispatchQueue.main.async { MainActor.assumeIsolated { self?.applyMusicRate(rate) } }
                }
            }
        }
    }

    private func removeRouteListeners() {
        routeListeners.removeAll()
        if let musicObserver { DistributedNotificationCenter.default().removeObserver(musicObserver) }
        musicObserver = nil
    }
}
