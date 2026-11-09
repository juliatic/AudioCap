import AppKit
import OSLog

/// Reads the sample rate of Music.app's current track through AppleScript (needs the Automation permission).
enum MusicTrackRate {
    private static let queue = DispatchQueue(label: "MusicTrackRate", qos: .userInitiated)
    private static let logger = Logger(subsystem: kAppSubsystem, category: "MusicTrackRate")

    private static let source = """
    tell application id "com.apple.Music"
        if player state is stopped then return 0
        return sample rate of current track
    end tell
    """

    static var isMusicRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: HiResRatePolicy.musicBundleID).isEmpty
    }

    /// Queries the rate off the main thread. `nil` when Music is not running, nothing is playing, or the query failed
    /// (for example, Automation permission denied). Never launches Music.
    static func fetch(completion: @escaping @Sendable (Double?) -> Void) {
        guard isMusicRunning else { return completion(nil) }
        queue.async {
            var error: NSDictionary?
            let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
            if let error {
                logger.warning("Music sample rate query failed: \(error, privacy: .public)")
                return completion(nil)
            }
            let rate = Double(result?.int32Value ?? 0)
            completion(rate > 0 ? rate : nil)
        }
    }

    /// Waits up to `timeout` for `fetch`. An answer that arrives later is delivered to `late` on the main queue.
    static func fetch(timeout: TimeInterval, late: @escaping @MainActor @Sendable (Double?) -> Void) -> Double? {
        let semaphore = DispatchSemaphore(value: 0)
        let box = RateBox()
        fetch { rate in
            if box.finish(rate) { DispatchQueue.main.async { late(rate) } }
            semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + timeout) == .timedOut, case .timedOut = box.expire() { return nil }
        return box.value
    }

    /// Hand-off between the query and the waiting caller; whichever comes second decides who gets the value.
    private final class RateBox: @unchecked Sendable {
        enum Expiry { case timedOut, answered }
        private let lock = NSLock()
        private var answered = false
        private var expired = false
        private var _value: Double?
        var value: Double? { lock.withLock { _value } }
        /// Returns `true` when the caller already gave up, so the answer is late.
        func finish(_ value: Double?) -> Bool { lock.withLock { _value = value; answered = true; return expired } }
        func expire() -> Expiry { lock.withLock { if answered { return .answered }; expired = true; return .timedOut } }
    }
}
