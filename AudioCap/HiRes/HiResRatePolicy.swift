import Foundation

/// Picks the rate of the Hi-Res device for a recording (plan section 2b, decision 11).
enum HiResRatePolicy {
    static let musicBundleID = "com.apple.Music"
    static let defaultFixedRate: Double = 96_000

    enum Source: Equatable, Sendable {
        /// Matches the sample rate of the current Music.app track.
        case musicTrack
        /// The fixed rate from Settings (other apps, or the Music track rate is unknown/unsupported).
        case fixed
    }

    struct Decision: Equatable, Sendable {
        var rate: Double
        var source: Source
    }

    static func decide(sourceBundleID: String?, musicTrackRate: Double?, fixedRate: Double) -> Decision {
        if sourceBundleID == musicBundleID, let musicTrackRate, HiResDevice.isSupported(musicTrackRate) {
            return Decision(rate: musicTrackRate, source: .musicTrack)
        }
        return Decision(rate: sanitizedFixedRate(fixedRate), source: .fixed)
    }

    /// A supported fixed rate: unsupported values fall back to 96 kHz.
    static func sanitizedFixedRate(_ rate: Double) -> Double {
        HiResDevice.isSupported(rate) ? rate : defaultFixedRate
    }
}
