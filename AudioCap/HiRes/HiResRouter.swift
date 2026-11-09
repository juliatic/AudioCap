import Foundation
import OSLog

/// Routing state machine for Hi-Res mode.
///
/// `idle` → `route(rate:)` remembers the system output, persists it, sets the Hi-Res device's rate and makes it the
/// system output → `routed`. `restore()` (stop, quit), `virtualDeviceVanished()` and `recoverAfterCrash()` (next launch)
/// put the remembered output back. When the user picks another output while routed, that device becomes the monitor
/// target and the Hi-Res device is made the system output again.
final class HiResRouter {
    enum State: Equatable {
        case idle
        case routed(monitor: AudioOutputDevice, rate: Double)
    }

    enum Event: Equatable {
        /// The user picked another output while routed; the monitor should follow it.
        case monitorTargetChanged(AudioOutputDevice)
        /// The Hi-Res device disappeared; the previous output was restored.
        case virtualDeviceLost(restored: AudioOutputDevice?)
    }

    private(set) var state: State = .idle
    let virtualUID: String
    private let system: AudioOutputSystem
    private let store: HiResRestoreStore
    private let logger = Logger(subsystem: kAppSubsystem, category: "HiResRouter")

    init(system: AudioOutputSystem, store: HiResRestoreStore, virtualUID: String = HiResDevice.uid) {
        self.system = system
        self.store = store
        self.virtualUID = virtualUID
    }

    var isRouted: Bool { state != .idle }
    var monitorTarget: AudioOutputDevice? { if case .routed(let monitor, _) = state { monitor } else { nil } }
    var rate: Double? { if case .routed(_, let rate) = state { rate } else { nil } }
    var isVirtualDeviceAvailable: Bool { system.device(uid: virtualUID) != nil }

    /// Makes the Hi-Res device the system output at `rate`. Returns the real device that the monitor plays to.
    @discardableResult
    func route(rate: Double) throws -> AudioOutputDevice {
        guard state == .idle else { throw "Hi-Res routing is already active." }
        guard isVirtualDeviceAvailable else { throw "\(HiResDevice.name) is not installed." }
        guard let previous = currentRealOutput() else { throw "No real output device is available for monitoring." }

        store.save(HiResRestoreRecord(previousOutput: previous, routedAt: Date()))
        do {
            try system.setNominalSampleRate(rate, uid: virtualUID)
            try system.setDefaultOutput(uid: virtualUID)
        } catch {
            putBack(previous)
            store.clear()
            throw error
        }
        state = .routed(monitor: previous, rate: rate)
        logger.info("Routed to \(HiResDevice.name, privacy: .public) at \(rate, privacy: .public) Hz; monitor: \(previous.name, privacy: .public)")
        return previous
    }

    /// Changes the Hi-Res device's rate while routed.
    func setRate(_ rate: Double) throws {
        guard case .routed(let monitor, let current) = state, current != rate else { return }
        try system.setNominalSampleRate(rate, uid: virtualUID)
        state = .routed(monitor: monitor, rate: rate)
    }

    /// Call when the system default output changed. Returns an event when the router acted.
    func defaultOutputChanged() -> Event? {
        guard case .routed(let monitor, let rate) = state else { return nil }
        guard let uid = system.defaultOutputUID(), uid != virtualUID else { return nil }
        guard let device = system.device(uid: uid) else { return nil }
        store.save(HiResRestoreRecord(previousOutput: device, routedAt: Date()))
        do {
            try system.setDefaultOutput(uid: virtualUID)
        } catch {
            logger.error("Could not switch back to \(HiResDevice.name, privacy: .public): \(error.audioCapDescription, privacy: .public)")
            state = .idle
            store.clear()
            return .virtualDeviceLost(restored: device)
        }
        state = .routed(monitor: device, rate: rate)
        return device == monitor ? nil : .monitorTargetChanged(device)
    }

    /// Call when the device list changed. Restores the previous output when the Hi-Res device is gone.
    func deviceListChanged() -> Event? {
        guard isRouted, !isVirtualDeviceAvailable else { return nil }
        return .virtualDeviceLost(restored: restore())
    }

    /// Restores the remembered output (stop, quit). Returns the device that is now the system output.
    @discardableResult
    func restore() -> AudioOutputDevice? {
        guard case .routed(let monitor, _) = state else { return nil }
        state = .idle
        let restored = putBack(monitor)
        store.clear()
        return restored
    }

    /// On launch: if a restore record survived (the app quit or crashed while routed), put the previous output back.
    @discardableResult
    func recoverAfterCrash() -> AudioOutputDevice? {
        guard state == .idle, let record = store.load() else { return nil }
        let restored = putBack(record.previousOutput)
        store.clear()
        logger.info("Recovered the output after an unclean exit: \(restored?.name ?? "none", privacy: .public)")
        return restored
    }

    // MARK: - Helpers

    private func currentRealOutput() -> AudioOutputDevice? {
        if let uid = system.defaultOutputUID(), uid != virtualUID, let device = system.device(uid: uid) {
            return device
        }
        // The Hi-Res device is already the system output (e.g. chosen by hand): fall back to a stored or any real device.
        if let stored = store.load()?.previousOutput, system.device(uid: stored.uid) != nil { return stored }
        return system.outputDevices(excluding: virtualUID).first
    }

    /// Makes `device` (or, if it is gone, any other real output) the system output, but only while the Hi-Res device is
    /// still the system output: an output the user picked in the meantime is left alone.
    @discardableResult
    private func putBack(_ device: AudioOutputDevice) -> AudioOutputDevice? {
        let current = system.defaultOutputUID()
        guard current == virtualUID || current == nil else { return current.flatMap { system.device(uid: $0) } }
        let candidates = [device].filter { system.device(uid: $0.uid) != nil } + system.outputDevices(excluding: virtualUID)
        for candidate in candidates {
            do {
                try system.setDefaultOutput(uid: candidate.uid)
                return candidate
            } catch {
                logger.error("Could not restore \(candidate.name, privacy: .public): \(error.audioCapDescription, privacy: .public)")
            }
        }
        return nil
    }
}
