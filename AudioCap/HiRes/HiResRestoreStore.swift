import Foundation

/// What to restore if the app quits or crashes while the Hi-Res device is the system output.
struct HiResRestoreRecord: Codable, Equatable, Sendable {
    var previousOutput: AudioOutputDevice
    var routedAt: Date
}

/// Persists the restore record in `UserDefaults` before the system output is switched, and clears it after restoring.
final class HiResRestoreStore {
    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = "HiResRestoreRecord") {
        self.defaults = defaults
        self.key = key
    }

    func load() -> HiResRestoreRecord? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(HiResRestoreRecord.self, from: data)
    }

    func save(_ record: HiResRestoreRecord) {
        guard let data = try? JSONEncoder().encode(record) else { return }
        defaults.set(data, forKey: key)
    }

    func clear() {
        defaults.removeObject(forKey: key)
    }
}
