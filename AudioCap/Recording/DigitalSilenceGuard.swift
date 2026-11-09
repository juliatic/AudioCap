import Foundation

/// Detects a capture that never delivers any signal (the symptom of a missing permission or a dead tap).
///
/// It is armed from the start of a capture session until the first non-zero sample. Once any signal has been
/// seen it is off for the rest of the session, because silent passages (track gaps, quiet intros, digital
/// silence between sounds) are legitimate. While armed, if every sample has been 0 for `seconds` while the
/// source reports that it is playing, it asks for one reconnect; if that doesn't help it shows a warning.
struct DigitalSilenceGuard: Equatable {
    enum State: Equatable {
        case armed
        case reconnected(at: Date)
        case gaveUp
        /// Signal was seen; the guard does nothing until `reset()`.
        case disarmed
    }

    enum Action: Equatable {
        case none
        case reconnect
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
    mutating func update(silentSeconds: Double, hasSeenSignal: Bool, sourceIsPlaying: Bool, sourceName: String, now: Date = Date()) -> Action {
        if hasSeenSignal {
            state = .disarmed
            warning = nil
            return .none
        }
        switch state {
        case .disarmed, .gaveUp:
            return .none
        case .armed:
            guard silentSeconds >= seconds, sourceIsPlaying else { return .none }
            state = .reconnected(at: now)
            warning = "\(sourceName) is playing but the capture is silent. Reconnecting to it…"
            return .reconnect
        case .reconnected(let date):
            guard now.timeIntervalSince(date) >= seconds * 2, sourceIsPlaying else { return .none }
            state = .gaveUp
            warning = "\(sourceName) is playing but AudioCap only receives silence. Check that AudioCap is allowed in System Settings › Privacy & Security › Screen & System Audio Recording, then stop and start again."
            return .none
        }
    }
}
