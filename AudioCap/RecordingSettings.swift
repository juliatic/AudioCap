import Foundation
import Observation
import UniformTypeIdentifiers

/// Global recording settings persisted via UserDefaults.
@Observable
final class RecordingSettings {
    static let shared = RecordingSettings()

    enum OutputFormat: String, CaseIterable, Hashable {
        case wav
        case m4a
        case flac

        var displayName: String {
            switch self {
            case .wav: "WAV"
            case .m4a: "M4A (AAC)"
            case .flac: "FLAC"
            }
        }

        var utType: UTType {
            switch self {
            case .wav: .wav
            case .m4a: .mpeg4Audio
            case .flac:
                // Some macOS versions do not provide UTType.flac; construct from extension and fallback
                UTType(filenameExtension: "flac") ?? .audio
            }
        }
    }

    // UserDefaults keys
    private let kAutoSplitEnabled = "AC_AutoSplitEnabled"
    private let kSilenceThresholdDb = "AC_SilenceThresholdDb"
    private let kMinSilenceDuration = "AC_MinSilenceDurationSec"
    private let kOutputFormat = "AC_OutputFormat"
    private let kDefaultsInitializedV1 = "AC_DefaultsInitializedV1"

    /// Toggle: auto-split on silence.
    var autoSplitOnSilence: Bool {
        didSet { UserDefaults.standard.set(autoSplitOnSilence, forKey: kAutoSplitEnabled) }
    }

    /// Threshold in dBFS below which audio is considered silent. Example: -40 dBFS.
    var silenceThresholdDb: Double {
        didSet { UserDefaults.standard.set(silenceThresholdDb, forKey: kSilenceThresholdDb) }
    }

    /// Minimum continuous silence duration (seconds) before triggering a split.
    var minSilenceDuration: Double {
        didSet { UserDefaults.standard.set(minSilenceDuration, forKey: kMinSilenceDuration) }
    }

    /// Output format for recorded files.
    var outputFormat: OutputFormat {
        didSet { UserDefaults.standard.set(outputFormat.rawValue, forKey: kOutputFormat) }
    }

    private init() {
        let defaults = UserDefaults.standard
        self.autoSplitOnSilence = defaults.object(forKey: kAutoSplitEnabled) as? Bool ?? false
        self.silenceThresholdDb = defaults.object(forKey: kSilenceThresholdDb) as? Double ?? -40.0
        self.minSilenceDuration = defaults.object(forKey: kMinSilenceDuration) as? Double ?? 2.0
        if let raw = defaults.string(forKey: kOutputFormat), let fmt = OutputFormat(rawValue: raw) {
            self.outputFormat = fmt
        } else {
            self.outputFormat = .wav
        }

        // One-time baseline defaults reset for this version
        if defaults.bool(forKey: kDefaultsInitializedV1) == false {
            self.autoSplitOnSilence = false
            self.outputFormat = .wav
            defaults.set(true, forKey: kDefaultsInitializedV1)
            defaults.set(self.autoSplitOnSilence, forKey: kAutoSplitEnabled)
            defaults.set(self.outputFormat.rawValue, forKey: kOutputFormat)
        }
    }
}