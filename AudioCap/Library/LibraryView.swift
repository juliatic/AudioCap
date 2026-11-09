import SwiftUI
import AppKit

/// The recordings library: output folder, the built-in player and every take with its status and actions.
struct LibrarySection: View {
    private let library = RecordingLibrary.shared
    @State private var player = PlayerModel()
    @State private var renaming: LibraryEntry?
    @State private var newName = ""
    @State private var actionError: String?

    var body: some View {
        Section {
            OutputFolderRow()

            if let id = player.entryID, let entry = library.entry(id) {
                PlayerView(entry: entry, model: player) { player.unload() }
            }

            if let error = library.lastError {
                Text(error).foregroundStyle(.secondary)
            }

            if library.entries.isEmpty {
                Text("No recordings yet.").foregroundStyle(.secondary)
            }
            ForEach(library.entries) { entry in
                LibraryRow(entry: entry, isPlaying: player.entryID == entry.id,
                           play: { player.load(entry); player.togglePlayback() },
                           retry: { library.retryConversion(entry.id) },
                           rename: { newName = entry.displayName; renaming = entry },
                           trash: { perform { if player.entryID == entry.id { player.unload() }; try library.moveToTrash(entry.id) } })
            }
        } header: {
            Text("Recordings")
        }
        .alert("Rename Recording", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Rename") {
                if let entry = renaming {
                    perform {
                        if player.entryID == entry.id { player.unload() }
                        try library.rename(entry.id, to: newName)
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Couldn't Complete the Action", isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
            Button("OK") {}
        } message: {
            Text(actionError ?? "")
        }
    }

    private func perform(_ action: () throws -> Void) {
        do { try action() } catch { actionError = error.localizedDescription }
    }
}

struct LibraryRow: View {
    let entry: LibraryEntry
    let isPlaying: Bool
    var play: () -> Void
    var retry: () -> Void
    var rename: () -> Void
    var trash: () -> Void

    private var canPlay: Bool {
        if case .done = entry.status { return FileManager.default.fileExists(atPath: entry.fileURL.path) }
        return false
    }

    private var canRetry: Bool {
        if case .failed = entry.status { return FileManager.default.fileExists(atPath: entry.captureURL.path) }
        return false
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            statusIcon.frame(width: 20)
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.displayName).fontWeight(.semibold)
                Text(details).foregroundStyle(.secondary)
                statusView
            }
            Spacer()
            if canPlay {
                Button("Play", systemImage: isPlaying ? "speaker.wave.2.fill" : "play.circle", action: play)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
            }
            Menu {
                Button("Play", action: play).disabled(!canPlay)
                Button("Retry Conversion", action: retry).disabled(!canRetry)
                Button("Rename…", action: rename).disabled(entry.status.isBusy)
                Button("Show in Finder") { showInFinder() }
                Divider()
                Button("Move to Trash", role: .destructive, action: trash).disabled(entry.status.isBusy)
            } label: {
                Label("Actions", systemImage: "ellipsis.circle").labelStyle(.iconOnly)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .accessibilityElement(children: .combine)
    }

    private var details: String {
        var parts = [entry.sourceName,
                     entry.startedAt.formatted(date: .abbreviated, time: .shortened)]
        if entry.status != .recording {
            parts.append(PlayerView.clock(entry.duration))
        }
        parts += [QualityPanel.formatName(entry.outputFormat),
                  "\(CaptureFormat.rateString(entry.fileSampleRate)) / \(QualityPanel.bitDepth(entry.outputFormat))"]
        if let analysis = entry.analysis {
            parts.append(String(localized: "Peak \(LevelMeterView.dbText(analysis.peakDb))"))
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch entry.status {
        case .recording: Image(systemName: "record.circle").foregroundStyle(.red)
        case .converting: Image(systemName: "gearshape.2").foregroundStyle(.secondary)
        case .done:
            entry.lengthIsConsistent == false
                ? Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                : Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private var statusView: some View {
        switch entry.status {
        case .recording:
            Text("Recording").foregroundStyle(.red)
        case .converting(let progress):
            HStack {
                ProgressView(value: progress).frame(maxWidth: 160)
                Text("Converting \(progress.formatted(.percent.precision(.fractionLength(0))))")
            }
        case .done:
            if entry.lengthIsConsistent == false {
                Text("Done, but the file's length doesn't match the capture").foregroundStyle(.orange)
            } else {
                Text("Done").foregroundStyle(.green)
            }
        case .failed(let reason):
            Text("Failed: \(reason)").foregroundStyle(.red)
        }
    }

    private func showInFinder() {
        let url = [entry.fileURL, entry.captureURL].first { FileManager.default.fileExists(atPath: $0.path) }
        if let url {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(entry.fileURL.deletingLastPathComponent())
        }
    }
}

struct OutputFolderRow: View {
    private let folder = OutputFolder.shared
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent("Save recordings in") {
                Text((folder.url.path as NSString).abbreviatingWithTildeInPath)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(folder.url.path)
            }
            HStack {
                Button("Change…") { choose() }
                if !folder.isDefault {
                    Button("Use Music Folder") { folder.resetToDefault() }
                }
                Button("Open Folder") {
                    NSWorkspace.shared.open(folder.preparedURL())
                }
            }
            if let message = error ?? folder.lastError {
                Text(message).foregroundStyle(.red)
            }
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = folder.url
        panel.prompt = String(localized: "Choose")
        panel.message = String(localized: "Choose where AudioCap saves new recordings.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try folder.choose(url)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}
