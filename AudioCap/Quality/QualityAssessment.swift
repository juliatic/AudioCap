import Foundation

/// Everything known about the audio path of a recording, from the source app to the file on disk.
/// `QualityAssessment.assess(_:)` turns it into the badge and warnings of the Quality panel.
///
/// Extension point: other features (the Hi-Res virtual device and monitor) describe their part of the path by
/// registering a `QualityPathContributor`, which can fill in `clock`, `monitor`, `isVirtualHiRes` or add `notes`.
struct QualityPath: Equatable, Sendable {
    struct Stream: Equatable, Sendable {
        var sampleRate: Double
        var channelCount: Int
    }

    struct Device: Equatable, Sendable {
        var name: String
        var uid: String
        var nominalSampleRate: Double?
        var outputChannelCount: Int?
        /// `true` for AudioCap's Hi-Res virtual device, which has no physical rate limit.
        var isVirtualHiRes = false
    }

    struct FileFormat: Equatable, Sendable {
        var format: RecordingSettings.OutputFormat
        var sampleRate: Double
        var channelCount: Int
    }

    struct Monitor: Equatable, Sendable {
        var deviceName: String
        var sampleRate: Double?
    }

    var sourceName: String
    var sourceBundleID: String?
    /// The rate the source material has, when the source reports it (most apps don't).
    var sourceSampleRate: Double?
    var sourceChannelCount: Int?
    /// The format the tap reports for the process mix.
    var tap: Stream?
    /// The device whose clock drives the capture (the default output device).
    var clock: Device?
    /// The validated capture format; `nil` until recording starts, when the other values are predictions.
    var capture: Stream?
    var file: FileFormat?
    /// Where the owner listens while recording, if it isn't the clock device.
    var monitor: Monitor?
    var notes: [QualityNote] = []

    /// The rate samples reach the capture file at.
    var captureRate: Double? { capture?.sampleRate ?? clock?.nominalSampleRate ?? tap?.sampleRate }
    var captureChannels: Int? { capture?.channelCount ?? tap?.channelCount }
}

enum QualityIssue: Equatable, Sendable, Hashable {
    /// The process mix is resampled to the capture rate (`from` is `nil` when the original rate is unknown).
    case resampled(from: Double?, to: Double)
    case downmixed(from: Int, to: Int)
    /// The output device has more channels than the capture; a multichannel source would be mixed down.
    case possibleDownmix(deviceChannels: Int, to: Int)
    case exportResampled(to: Double)
    case lossyFile
}

enum QualityNote: Equatable, Sendable, Hashable {
    /// No recording yet: the formats are what the next recording is expected to use.
    case predicted
    /// The source doesn't report its rate, so resampling before the tap can't be ruled out.
    case sourceRateUnknown(captureRate: Double)
    /// The app's volume, EQ, Sound Check or Spatial Audio changes the samples before the tap.
    case appProcessing
    case integerFile(bits: Int)
    case hiResDevice
    case monitor(deviceName: String, sampleRate: Double?)
    case custom(String)
}

struct QualityAssessment: Equatable, Sendable {
    var issues: [QualityIssue]
    var notes: [QualityNote]

    /// Green badge: nothing in the path is known to resample or downmix.
    var isBitPerfect: Bool { issues.isEmpty }

    static func assess(_ path: QualityPath) -> QualityAssessment {
        var issues: [QualityIssue] = []
        var notes: [QualityNote] = []
        if path.capture == nil { notes.append(.predicted) }

        let rate = path.captureRate
        if let rate {
            if let source = path.sourceSampleRate, !same(source, rate) {
                issues.append(.resampled(from: source, to: rate))
            } else if let tap = path.tap?.sampleRate, !same(tap, rate) {
                issues.append(.resampled(from: tap, to: rate))
            } else if path.sourceSampleRate == nil {
                notes.append(.sourceRateUnknown(captureRate: rate))
            }
        }

        if let channels = path.captureChannels {
            if let source = path.sourceChannelCount, source > channels {
                issues.append(.downmixed(from: source, to: channels))
            } else if path.sourceChannelCount == nil, let device = path.clock?.outputChannelCount, device > channels {
                issues.append(.possibleDownmix(deviceChannels: device, to: channels))
            }
        }

        if let file = path.file {
            if file.format == .aac {
                issues.append(.lossyFile)
            }
            if let rate, !same(file.sampleRate, rate) {
                issues.append(.exportResampled(to: file.sampleRate))
            }
            if file.format == .flac || file.format == .alac { notes.append(.integerFile(bits: 24)) }
        }

        if path.clock?.isVirtualHiRes == true { notes.append(.hiResDevice) }
        if let monitor = path.monitor { notes.append(.monitor(deviceName: monitor.deviceName, sampleRate: monitor.sampleRate)) }
        notes.append(.appProcessing)
        notes.append(contentsOf: path.notes)
        return QualityAssessment(issues: issues, notes: notes)
    }

    private static func same(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.5 }
}

/// Lets another feature describe its part of the audio path (see `QualityPath`).
@MainActor
protocol QualityPathContributor: AnyObject {
    func contribute(to path: inout QualityPath)
}

@MainActor
enum QualityPathContributors {
    private static var contributors: [ObjectIdentifier: QualityPathContributor] = [:]

    static func register(_ contributor: QualityPathContributor) {
        contributors[ObjectIdentifier(contributor)] = contributor
    }

    static func unregister(_ contributor: QualityPathContributor) {
        contributors[ObjectIdentifier(contributor)] = nil
    }

    static func apply(to path: inout QualityPath) {
        for contributor in contributors.values { contributor.contribute(to: &path) }
    }
}
