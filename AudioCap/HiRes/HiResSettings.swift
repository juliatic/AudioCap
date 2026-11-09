import Foundation
import Observation

/// Hi-Res preferences, persisted in `UserDefaults`. Hi-Res is on by default; it only acts when the driver is installed.
@Observable
final class HiResSettings {
    static let shared = HiResSettings()

    @ObservationIgnored private let defaults: UserDefaults

    var isEnabled: Bool { didSet { defaults.set(isEnabled, forKey: Keys.enabled) } }
    /// Rate for apps other than Music, or when the Music track rate is unknown. 96 kHz by default, up to 192 kHz.
    var fixedRate: Double { didSet { defaults.set(fixedRate, forKey: Keys.fixedRate) } }
    var monitorVolume: Float { didSet { defaults.set(monitorVolume, forKey: Keys.monitorVolume) } }
    var isMonitorMuted: Bool { didSet { defaults.set(isMonitorMuted, forKey: Keys.monitorMuted) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isEnabled = defaults.object(forKey: Keys.enabled) as? Bool ?? true
        fixedRate = HiResRatePolicy.sanitizedFixedRate(defaults.object(forKey: Keys.fixedRate) as? Double ?? HiResRatePolicy.defaultFixedRate)
        monitorVolume = min(max(defaults.object(forKey: Keys.monitorVolume) as? Float ?? 1, 0), 1)
        isMonitorMuted = defaults.object(forKey: Keys.monitorMuted) as? Bool ?? false
    }

    private enum Keys {
        static let enabled = "HiResEnabled"
        static let fixedRate = "HiResFixedRate"
        static let monitorVolume = "HiResMonitorVolume"
        static let monitorMuted = "HiResMonitorMuted"
    }
}
