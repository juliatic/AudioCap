import Foundation
import Observation
import OSLog

enum LibraryError: LocalizedError, Equatable {
    case busy
    case invalidName
    case nameTaken(String)
    case captureMissing

    var errorDescription: String? {
        switch self {
        case .busy: String(localized: "Wait until this take has finished recording and converting.")
        case .invalidName: String(localized: "Enter a name without “/” or “:”.")
        case .nameTaken(let name): String(localized: "A file named “\(name)” already exists.")
        case .captureMissing: String(localized: "The original capture is no longer on disk, so it can't be converted again.")
        }
    }
}

/// Every take AudioCap has recorded, indexed as JSON in Application Support. It follows the recorder's take events,
/// reads each exported file back (decoded length, peak) and offers retry, rename and Move to Trash.
@Observable
@MainActor
final class RecordingLibrary {
    static let shared = RecordingLibrary(indexURL: URL.applicationSupport.appending(path: "library.json"))

    private(set) var entries: [LibraryEntry] = []
    var lastError: String?

    let indexURL: URL
    @ObservationIgnored private var pending: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var observers: [Task<Void, Never>] = []
    private let logger = Logger(subsystem: kAppSubsystem, category: "RecordingLibrary")

    private static let indexVersion = 1
    private struct Index: Codable {
        var version: Int
        var entries: [LibraryEntry]
    }

    init(indexURL: URL) {
        self.indexURL = indexURL
        load()
    }

    func entry(_ id: LibraryEntry.ID) -> LibraryEntry? { entries.first { $0.id == id } }

    // MARK: Recorder events

    func observe(_ recorder: ProcessTapRecorder) {
        let events = recorder.takeEvents()
        observers.removeAll { $0.isCancelled }
        observers.append(Task { [weak self] in
            for await event in events { self?.apply(event) }
        })
    }

    func apply(_ event: TakeEvent) {
        switch event {
        case .added(let take), .updated(let take):
            guard let index = entries.firstIndex(where: { $0.id == take.id }) else {
                entries.insert(LibraryEntry(take: take), at: 0)
                save()
                if case .done = LibraryEntry.Status(take.status) { analyze(take.id) }
                return
            }
            let status = LibraryEntry.Status(take.status)
            guard LibraryEntry.Status.canTransition(from: entries[index].status, to: status) else { return }
            let old = entries[index].status
            let oldWarnings = entries[index].warnings
            entries[index].update(from: take)
            entries[index].status = status
            // Progress updates arrive many times a second; only write the index when the state or the warnings change
            // (a closed take's warnings can be amended later, for example when the next take turns out to be split from it).
            if !Self.sameKind(old, status) || entries[index].warnings != oldWarnings { save() }
            if case .done = status, !Self.sameKind(old, status) { analyze(take.id) }
        case .removed(let id):
            entries.removeAll { $0.id == id }
            save()
        }
    }

    // MARK: Actions

    /// Converts the CAF capture of a failed take again.
    func retryConversion(_ id: LibraryEntry.ID) {
        guard let entry = entry(id), case .failed = entry.status else { return }
        guard FileManager.default.fileExists(atPath: entry.captureURL.path) else {
            setStatus(id, .failed(reason: LibraryError.captureMissing.localizedDescription))
            return
        }
        setStatus(id, .converting(progress: 0))
        let expected: Int64? = entry.capturedFrames > 0 ? entry.capturedFrames : nil
        pending[id] = Task { [weak self] in
            let outcome = await Task.detached(priority: .userInitiated) { () -> Result<AudioExporter.Result, Error> in
                Result {
                    try AudioExporter.export(from: entry.captureURL, to: entry.fileURL, format: entry.outputFormat, expectedFrames: expected) { value in
                        Task { @MainActor in self?.setProgress(id, value) }
                    }
                }
            }.value
            guard let self else { return }
            self.pending[id] = nil
            switch outcome {
            case .success(let result):
                try? FileManager.default.removeItem(at: entry.captureURL)
                self.update(id) {
                    if $0.capturedFrames == 0 { $0.capturedFrames = Int64((Double(result.frameCount) * $0.sampleRate / result.sampleRate).rounded()) }
                    $0.exportedFrames = result.frameCount
                }
                self.setStatus(id, .done)
                self.analyze(id)
            case .failure(let error):
                self.setStatus(id, .failed(reason: error.audioCapDescription))
            }
        }
    }

    /// Renames the take's file (and its capture, if still on disk) to `newName` plus the format's extension.
    func rename(_ id: LibraryEntry.ID, to newName: String) throws {
        guard let entry = entry(id) else { return }
        guard !entry.status.isBusy else { throw LibraryError.busy }
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("/"), !name.contains(":"), !name.hasPrefix(".") else { throw LibraryError.invalidName }
        guard name != entry.displayName else { return }

        let folder = entry.fileURL.deletingLastPathComponent()
        let newFile = folder.appendingPathComponent(name).appendingPathExtension(entry.fileURL.pathExtension)
        let newCapture = entry.captureURL.deletingLastPathComponent().appendingPathComponent(name).appendingPathExtension("caf")
        let fm = FileManager.default
        let hasFile = fm.fileExists(atPath: entry.fileURL.path)
        let hasCapture = fm.fileExists(atPath: entry.captureURL.path)
        if hasFile, fm.fileExists(atPath: newFile.path) { throw LibraryError.nameTaken(newFile.lastPathComponent) }
        if hasCapture, fm.fileExists(atPath: newCapture.path) { throw LibraryError.nameTaken(newCapture.lastPathComponent) }

        if hasFile { try fm.moveItem(at: entry.fileURL, to: newFile) }
        if hasCapture {
            do { try fm.moveItem(at: entry.captureURL, to: newCapture) } catch {
                if hasFile { try? fm.moveItem(at: newFile, to: entry.fileURL) }
                throw error
            }
        }
        update(id) {
            $0.fileURL = newFile
            $0.captureURL = newCapture
        }
        save()
    }

    /// Moves the take's files to the Trash and removes it from the library.
    func moveToTrash(_ id: LibraryEntry.ID) throws {
        guard let entry = entry(id) else { return }
        guard !entry.status.isBusy else { throw LibraryError.busy }
        let fm = FileManager.default
        for url in [entry.fileURL, entry.captureURL] where fm.fileExists(atPath: url.path) {
            try fm.trashItem(at: url, resultingItemURL: nil)
        }
        entries.removeAll { $0.id == id }
        save()
    }

    /// Waits for pending conversions and file analysis (used by tests).
    func settle() async {
        for _ in 0..<10 where !pending.isEmpty {
            let tasks = Array(pending.values)
            for task in tasks { await task.value }
            pending = pending.filter { !tasks.contains($0.value) }
        }
    }

    // MARK: Analysis

    func analyze(_ id: LibraryEntry.ID) {
        guard let url = entry(id)?.fileURL, pending[id] == nil else { return }
        pending[id] = Task { [weak self] in
            let analysis = await Task.detached(priority: .utility) { try? AudioFileInspector.analyze(url).analysis }.value
            guard let self else { return }
            self.pending[id] = nil
            guard let analysis else { return }
            self.update(id) { $0.analysis = analysis }
            self.save()
        }
    }

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: indexURL) else { return }
        do {
            let index = try JSONDecoder.library.decode(Index.self, from: data)
            entries = index.entries.map { entry in
                var entry = entry
                // A take that was still recording or converting when the app quit can't resume.
                if entry.status.isBusy {
                    entry.status = .failed(reason: String(localized: "AudioCap quit before this take was finished. Retry the conversion to export what was captured."))
                }
                return entry
            }
        } catch {
            logger.error("Can't read library index: \(error, privacy: .public)")
            lastError = String(localized: "The recordings list couldn't be read, so it starts empty. Your files are untouched.")
            try? FileManager.default.moveItem(at: indexURL, to: indexURL.appendingPathExtension("unreadable"))
        }
    }

    func save() {
        do {
            try FileManager.default.createDirectory(at: indexURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder.library.encode(Index(version: Self.indexVersion, entries: entries))
            try data.write(to: indexURL, options: .atomic)
        } catch {
            logger.error("Can't save library index: \(error, privacy: .public)")
        }
    }

    // MARK: Helpers

    private func update(_ id: LibraryEntry.ID, _ change: (inout LibraryEntry) -> Void) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        change(&entries[index])
    }

    private func setStatus(_ id: LibraryEntry.ID, _ status: LibraryEntry.Status) {
        guard let index = entries.firstIndex(where: { $0.id == id }),
              LibraryEntry.Status.canTransition(from: entries[index].status, to: status) else { return }
        entries[index].status = status
        save()
    }

    private func setProgress(_ id: LibraryEntry.ID, _ value: Double) {
        guard let index = entries.firstIndex(where: { $0.id == id }), case .converting = entries[index].status else { return }
        entries[index].status = .converting(progress: value)
    }

    private static func sameKind(_ a: LibraryEntry.Status, _ b: LibraryEntry.Status) -> Bool {
        switch (a, b) {
        case (.recording, .recording), (.converting, .converting), (.done, .done): true
        case (.failed(let x), .failed(let y)): x == y
        default: false
        }
    }
}

private extension JSONEncoder {
    static var library: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var library: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
