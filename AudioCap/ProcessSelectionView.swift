import SwiftUI
import UniformTypeIdentifiers
import Observation

@MainActor
struct ProcessSelectionView: View {
    @State private var processController = AudioProcessController()
    @State private var tap: ProcessTap?
    @State private var recorder: ProcessTapRecorder?

    @State private var selectedProcess: AudioProcess?
    /// Executable of the selected source, for following a relaunch of a process without a bundle ID.
    @State private var selectedExecutablePath: String?
    @State private var settings = RecordingSettings.shared

    var body: some View {
        Section {
            Picker("Process", selection: $selectedProcess) {
                Text("Select…")
                    .font(AppStyle.body)
                    .tag(Optional<AudioProcess>.none)

                HStack {
                    Image(nsImage: AudioProcess.allSystemAudio.icon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 16, height: 16)

                    Text("All system audio")
                }
                    .tag(Optional<AudioProcess>.some(.allSystemAudio))

                if let selectedProcess, selectedProcess.kind != .system, !processController.processes.contains(selectedProcess) {
                    Text("\(selectedProcess.name) (waiting)")
                        .tag(Optional<AudioProcess>.some(selectedProcess))
                }

                ForEach(processController.processGroups) { group in
                    Section {
                        ForEach(group.processes) { process in
                            HStack {
                                Image(nsImage: process.icon)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(width: 16, height: 16)
                                    .accessibilityHidden(true)

                                Text(process.name)
                                    .font(AppStyle.body)
                            }
                                .tag(Optional<AudioProcess>.some(process))
                        }
                    } header: {
                        Text(group.title)
                    }
                }
            }
            .disabled(recorder?.isRecording == true || recorder?.isConverting == true)
            .task { processController.activate() }
            .onChange(of: OutputFolder.shared.url) {
                if recorder?.status == .idle, recorder?.isConverting == false { createRecorder() }
            }
            .onChange(of: processController.processes) { followRelaunchedSource() }
            .onChange(of: selectedProcess) { oldValue, newValue in
                guard newValue != oldValue else { return }
                // A relaunch of the same source: the tap re-attaches by itself, keep the recorder.
                if let oldValue, let newValue, SourceSelection.isRelaunch(of: oldValue, executablePath: selectedExecutablePath,
                                                                          candidate: newValue, candidatePath: newValue.objectID.readProcessExecutablePath()) {
                    return
                }

                if let newValue {
                    setupRecording(for: newValue)
                } else if oldValue == tap?.process {
                    teardownTap()
                }
            }
        } header: {
            Text("Source")
                .font(AppStyle.headline)
                .accessibilityAddTraits(.isHeader)
        }

        if let tap {
            if let errorMessage = tap.errorMessage {
                Text(errorMessage)
                    .font(AppStyle.headline)
                    .foregroundStyle(AppStyle.errorText.color)
                    .textSelection(.enabled)
            } else if let recorder {
                RecordingView(recorder: recorder)
                QualityPanel(tap: tap, recorder: recorder)
            }
        }
    }

    private func followRelaunchedSource() {
        guard let selected = selectedProcess,
              let row = SourceSelection.row(for: selected, executablePath: selectedExecutablePath, in: processController.processes,
                                            path: { $0.objectID.readProcessExecutablePath() }),
              row != selected else { return }
        selectedProcess = row
    }

    private func setupRecording(for process: AudioProcess) {
        teardownTap()
        selectedExecutablePath = process.kind == .system ? nil : process.objectID.readProcessExecutablePath()
        let newTap = ProcessTap(process: process)
        self.tap = newTap
        newTap.activate()

        createRecorder()
    }

    private func createRecorder() {
        guard let tap else { return }

        let recorder = ProcessTapRecorder(tap: tap, outputDirectory: OutputFolder.shared.preparedURL())
        RecordingLibrary.shared.observe(recorder)
        self.recorder = recorder
    }

    private func teardownTap() {
        recorder?.stop()
        recorder = nil
        tap?.invalidate()
        tap = nil
    }
}

extension URL {
    static var applicationSupport: URL {
        do {
            let appSupport = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
            let subdir = appSupport.appending(path: "AudioCap", directoryHint: .isDirectory)
            if !FileManager.default.fileExists(atPath: subdir.path) {
                try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)
            }
            return subdir
        } catch {
            assertionFailure("Failed to get application support directory: \(error)")

            return FileManager.default.temporaryDirectory
        }
    }
}

