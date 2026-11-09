import Foundation
import Observation

/// Settings of the recording mode ("Wait for sound" or manual), persisted in UserDefaults.
@Observable
final class AutoRecordSettings {
    static let shared = AutoRecordSettings()

    static let thresholdRange: ClosedRange<Double> = -90 ... -20
    static let minSilenceRange: ClosedRange<Double> = 0.5 ... 10

    private let kMode = "AC_RecordingMode"
    private let kThresholdDb = "AC_AutoRecordThresholdDb"
    private let kMinSilence = "AC_AutoRecordMinSilenceSec"

    var mode: AutoRecordMachine.Mode {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: kMode) }
    }

    /// Sound above this RMS level (dBFS) opens a take.
    var thresholdDb: Double {
        didSet { UserDefaults.standard.set(thresholdDb, forKey: kThresholdDb) }
    }

    /// Seconds of silence at or below the threshold that close a take.
    var minSilence: Double {
        didSet { UserDefaults.standard.set(minSilence, forKey: kMinSilence) }
    }

    var configuration: AutoRecordMachine.Configuration {
        var configuration = AutoRecordMachine.Configuration()
        configuration.thresholdDb = thresholdDb.clamped(to: Self.thresholdRange)
        configuration.minSilence = minSilence.clamped(to: Self.minSilenceRange)
        configuration.tail = min(configuration.tail, configuration.minSilence)
        return configuration
    }

    private init() {
        let defaults = UserDefaults.standard
        mode = defaults.string(forKey: kMode).flatMap(AutoRecordMachine.Mode.init(rawValue:)) ?? .waitForSound
        thresholdDb = defaults.object(forKey: kThresholdDb) as? Double ?? AutoRecordMachine.Configuration().thresholdDb
        minSilence = defaults.object(forKey: kMinSilence) as? Double ?? AutoRecordMachine.Configuration().minSilence
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self { min(max(self, range.lowerBound), range.upperBound) }
}
