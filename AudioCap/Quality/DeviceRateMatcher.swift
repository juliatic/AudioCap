import Foundation
import AppKit
import AudioToolbox
import Observation
import OSLog

extension AudioDeviceID {
    static func device(withUID uid: String) -> AudioDeviceID? {
        var cfUID = uid as CFString
        var device = AudioDeviceID.unknown
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let err = withUnsafeMutablePointer(to: &cfUID) { pointer in
            AudioObjectGetPropertyData(.system, &address, UInt32(MemoryLayout<CFString>.size), pointer, &size, &device)
        }
        return err == noErr && device != .unknown ? device : nil
    }

    func readAvailableNominalSampleRates() -> [Double] {
        let address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyAvailableNominalSampleRates,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let ranges: [AudioValueRange] = (try? readArray(address)) ?? []
        // Devices list discrete rates as ranges whose bounds are equal; continuous ranges are rare and skipped.
        return Array(Set(ranges.filter { $0.mMinimum == $0.mMaximum }.map(\.mMinimum))).sorted()
    }

    func setNominalSampleRate(_ rate: Double) throws {
        var value = rate
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        try checkStatus(AudioObjectSetPropertyData(self, &address, 0, nil, UInt32(MemoryLayout<Double>.size), &value), "Setting the nominal sample rate to \(rate) Hz")
    }

    /// Output channels across all output streams.
    func readOutputChannelCount() -> Int? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                                 mScope: kAudioObjectPropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(self, &address, 0, nil, &size) == noErr, size > 0 else { return nil }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(self, &address, 0, nil, &size, raw) == noErr else { return nil }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}

/// The optional "Match output device rate" action. It only runs when the owner presses the button: it sets the
/// output device's nominal rate and puts the previous rate back when the recording stops (or, if AudioCap quit
/// first, on the next launch).
@Observable
@MainActor
final class DeviceRateMatcher {
    static let shared = DeviceRateMatcher()

    struct Change: Codable, Equatable, Sendable {
        var deviceUID: String
        var deviceName: String
        var originalRate: Double
        var newRate: Double
    }

    private(set) var activeChange: Change?
    var lastError: String?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let setRate: (String, Double) throws -> Void
    private let logger = Logger(subsystem: kAppSubsystem, category: "DeviceRateMatcher")
    static let pendingKey = "AC_PendingRateRestore"

    init(defaults: UserDefaults = .standard, setRate: ((String, Double) throws -> Void)? = nil) {
        self.defaults = defaults
        self.setRate = setRate ?? { uid, rate in
            guard let device = AudioDeviceID.device(withUID: uid) else { throw CoreAudioError(operation: "Finding output device \(uid)", status: OSStatus(kAudioHardwareBadDeviceError)) }
            try device.setNominalSampleRate(rate)
        }
        if let data = defaults.data(forKey: Self.pendingKey) {
            activeChange = try? JSONDecoder().decode(Change.self, from: data)
            // AudioCap quit (or crashed) while a rate was matched: put the device back now.
            restore()
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { DeviceRateMatcher.shared.restore() }
        }
    }

    /// Sets the device to `rate`, remembering the current rate so `restore()` can put it back.
    func match(deviceUID: String, deviceName: String, currentRate: Double, to rate: Double) {
        let original = activeChange?.deviceUID == deviceUID ? activeChange!.originalRate : currentRate
        do {
            if let activeChange, activeChange.deviceUID != deviceUID { restore() }
            try setRate(deviceUID, rate)
            let change = Change(deviceUID: deviceUID, deviceName: deviceName, originalRate: original, newRate: rate)
            activeChange = change
            defaults.set(try JSONEncoder().encode(change), forKey: Self.pendingKey)
            lastError = nil
            logger.info("Set \(deviceName, privacy: .public) to \(rate) Hz (was \(original) Hz)")
        } catch {
            lastError = String(localized: "Couldn't change the rate of \(deviceName): \(error.audioCapDescription)")
        }
    }

    /// Puts back the rate the device had before `match`. Safe to call when nothing was changed.
    func restore() {
        guard let change = activeChange else { return }
        do {
            try setRate(change.deviceUID, change.originalRate)
            logger.info("Restored \(change.deviceName, privacy: .public) to \(change.originalRate) Hz")
            lastError = nil
        } catch {
            // The device may be unplugged; forget the change rather than retrying forever.
            logger.error("Can't restore rate of \(change.deviceName, privacy: .public): \(error, privacy: .public)")
        }
        activeChange = nil
        defaults.removeObject(forKey: Self.pendingKey)
    }
}
