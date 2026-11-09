import Foundation

/// Detects a capture that never delivers any signal (the symptom of a missing permission or a dead tap).
///
/// It is armed from the start of a capture session until the first non-zero sample. Once any signal has been
/// seen it is off for the rest of the session, because silent passages (track gaps, quiet intros, digital
/// silence between sounds) are legitimate. While armed, if every sample has been 0 for `seconds` while the
/// source reports that it is playing, it shows a warning. It never reconnects: recreating the tap loses the
/// audio played during the rebuild and did not bring signal back in live tests on a 96 kHz device.
struct DigitalSilenceGuard: Equatable {
    enum State: Equatable {
        case armed
        case warned
        /// Signal was seen; the guard does nothing until `reset()`.
        case disarmed
    }

    var seconds: Double
    private(set) var state = State.armed
    /// The live warning to show, if any.
    private(set) var warning: String?

    init(seconds: Double = 2) {
        self.seconds = seconds
    }

    /// Starts a new capture session (or ends one): armed again, no warning.
    mutating func reset() {
        state = .armed
        warning = nil
    }

    /// Call periodically while capturing.
    /// - Parameters:
    ///   - silentSeconds: how long every sample has been exactly 0, up to now.
    ///   - hasSeenSignal: whether any non-zero sample arrived since the session started.
    ///   - sourceIsPlaying: whether the source reports running output.
    mutating func update(silentSeconds: Double, hasSeenSignal: Bool, sourceIsPlaying: Bool, sourceName: String) {
        if hasSeenSignal {
            state = .disarmed
            warning = nil
            return
        }
        guard state == .armed, silentSeconds >= seconds, sourceIsPlaying else { return }
        state = .warned
        warning = String(localized: "\(sourceName) is playing but AudioCap has only received digital silence so far. This is expected during a silent intro. If you hear audio, check that AudioCap is allowed in System Settings › Privacy & Security › Screen & System Audio Recording, then stop and start again.")
    }
}

/// When to recreate a tap that has been receiving only digital silence while no take is open.
///
/// On macOS 26 a process tap that has run for tens of seconds on a source playing digital silence can deliver
/// zeros, or signal chopped into short bursts, when the source starts playing sound, with cycles and sample
/// times still regular (bare tap + aggregate harness, 48 kHz: 0 of 3 runs captured a 3 s tone after 58 s of
/// silence; 3 of 3 with a fresh tap every 10 s). A fresh tap costs about 0.4 s in which nothing is captured,
/// so it is only done while there is nothing to lose: no take open, only zeros, and at most every `interval`.
enum IdleTapRefresh {
    static let interval: Double = 10

    static func shouldRefresh(isTakeOpen: Bool, silentSeconds: Double, sourceIsPlaying: Bool,
                              secondsSinceLastRefresh: Double?) -> Bool {
        guard !isTakeOpen, sourceIsPlaying, silentSeconds >= interval else { return false }
        return (secondsSinceLastRefresh ?? .infinity) >= interval
    }
}
