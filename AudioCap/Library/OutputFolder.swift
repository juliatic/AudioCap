import Foundation
import Observation
import OSLog

/// Where new takes are saved. Defaults to `~/Music/AudioCap` (sandbox entitlement
/// `com.apple.security.assets.music.read-write`); a folder chosen in the picker is remembered with an app-scoped
/// security-scoped bookmark (`com.apple.security.files.bookmarks.app-scope`). Folders used before stay accessible so
/// older takes in the library keep playing.
@Observable
final class OutputFolder {
    static let shared = OutputFolder()

    private(set) var url: URL
    private(set) var lastError: String?

    var isDefault: Bool { url.standardizedFileURL == Self.defaultURL.standardizedFileURL }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var accessedURLs: [URL] = []
    private let logger = Logger(subsystem: kAppSubsystem, category: "OutputFolder")

    static let bookmarkKey = "AC_OutputFolderBookmark"
    static let knownBookmarksKey = "AC_KnownFolderBookmarks"
    static let maxKnownFolders = 20

    /// `~/Music/AudioCap` in the real home folder (not the sandbox container).
    static var defaultURL: URL {
        realHomeDirectory.appending(path: "Music", directoryHint: .isDirectory)
            .appending(path: "AudioCap", directoryHint: .isDirectory)
    }

    static var realHomeDirectory: URL {
        if let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        url = Self.defaultURL
        for data in defaults.array(forKey: Self.knownBookmarksKey) as? [Data] ?? [] {
            _ = resolve(data)
        }
        if let data = defaults.data(forKey: Self.bookmarkKey), let resolved = resolve(data) {
            url = resolved
        }
    }

    deinit {
        accessedURLs.forEach { $0.stopAccessingSecurityScopedResource() }
    }

    /// Creates the folder if needed and returns it. Falls back to Application Support when it can't be created,
    /// recording the reason in `lastError`.
    func preparedURL() -> URL {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            lastError = nil
            return url
        } catch {
            logger.error("Can't use output folder \(self.url.path, privacy: .public): \(error, privacy: .public)")
            lastError = String(localized: "Can't write to \(url.path). Recordings are saved in Application Support instead.")
            return .applicationSupport
        }
    }

    /// Uses `newURL` (picked by the user in an open panel) for new takes and remembers access to it.
    func choose(_ newURL: URL) throws {
        let started = newURL.startAccessingSecurityScopedResource()
        let bookmark: Data
        do {
            bookmark = try newURL.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        } catch {
            if started { newURL.stopAccessingSecurityScopedResource() }
            throw error
        }
        if started { accessedURLs.append(newURL) }
        defaults.set(bookmark, forKey: Self.bookmarkKey)
        var known = defaults.array(forKey: Self.knownBookmarksKey) as? [Data] ?? []
        known.append(bookmark)
        defaults.set(Array(known.suffix(Self.maxKnownFolders)), forKey: Self.knownBookmarksKey)
        url = newURL
        lastError = nil
    }

    func resetToDefault() {
        defaults.removeObject(forKey: Self.bookmarkKey)
        url = Self.defaultURL
        lastError = nil
    }

    private func resolve(_ data: Data) -> URL? {
        var stale = false
        guard let resolved = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale) else {
            return nil
        }
        if resolved.startAccessingSecurityScopedResource() { accessedURLs.append(resolved) }
        return resolved
    }
}
