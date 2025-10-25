import SwiftUI
import UniformTypeIdentifiers
import Observation

@MainActor
struct RecordingView: View {
    let recorder: ProcessTapRecorder

    @State private var lastRecordingURL: URL?
    @State private var settings = RecordingSettings.shared
    @State private var showConversionSheet = false

    var body: some View {
        Section {
            HStack {
                if recorder.isRecording {
                    Button("Stop") {
                        if settings.outputFormat != .wav {
                            recorder.stop()
                            showConversionSheet = true
                        } else {
                            recorder.stop()
                        }
                    }
                    .id("button")
                } else {
                    Button("Start") {
                        handlingErrors { try recorder.start() }
                    }
                    .id("button")

                    if let lastRecordingURL {
                        FileProxyView(url: lastRecordingURL)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
            }
            .animation(.smooth, value: recorder.isRecording)
            .animation(.smooth, value: lastRecordingURL)
            .onChange(of: recorder.isRecording) { _, newValue in
                if !newValue {
                    if settings.outputFormat == .wav {
                        lastRecordingURL = recorder.fileURL
                    } else {
                        lastRecordingURL = nil
                    }
                }
            }
            .onChange(of: recorder.isConverting) { _, isConverting in
                if !isConverting {
                    lastRecordingURL = recorder.lastConvertedURL
                }
            }

            // Recording settings
            VStack(alignment: .leading, spacing: 8) {
                Toggle(isOn: $settings.autoSplitOnSilence) {
                    Text("Auto-split on silence")
                }
                .accessibilityLabel(Text("Auto-split on silence"))

                HStack(spacing: 8) {
                    LabeledContent("Format") {
                        Picker("Format", selection: $settings.outputFormat) {
                            ForEach(RecordingSettings.OutputFormat.allCases, id: \.self) { format in
                                Text(format.displayName).tag(format)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(width: 150)
                        .disabled(recorder.isRecording) // lock format while recording
                    }
                }

                HStack(spacing: 8) {
                    LabeledContent("Threshold (dB)") {
                        TextField("-40", value: $settings.silenceThresholdDb, format: .number)
                            .frame(width: 80)
                    }
                    LabeledContent("Min silence (s)") {
                        TextField("2.0", value: $settings.minSilenceDuration, format: .number)
                            .frame(width: 80)
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            // Allow editing threshold/min during recording; changes apply to next session
        } header: {
            HStack {
                RecordingIndicator(appIcon: recorder.process.icon, isRecording: recorder.isRecording)

                Text(recorder.isRecording ? "Recording from \(recorder.process.name)" : (recorder.isConverting ? "Converting…" : "Ready to Record from \(recorder.process.name)"))
                    .font(.headline)
                    .contentTransition(.identity)
            }
        }
        .sheet(isPresented: $showConversionSheet) {
            VStack(alignment: .leading, spacing: 12) {
                if recorder.isConverting {
                    Text("Converting to \(settings.outputFormat.displayName)…")
                        .font(.headline)
                    ProgressView()
                        .controlSize(.small)
                    Text("Files will be saved in:")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(recorder.fileURL.deletingLastPathComponent().path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                } else {
                    if let url = recorder.lastConvertedURL {
                        Text("Conversion complete.")
                            .font(.headline)
                        Text("Saved to:")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text(url.path)
                            .font(.caption)
                            .textSelection(.enabled)
                        HStack(spacing: 8) {
                            Button("Show in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([url])
                            }
                            Button("Close") {
                                showConversionSheet = false
                                lastRecordingURL = url
                            }
                        }
                    } else {
                        Text("Conversion complete.")
                            .font(.headline)
                        Text("Saved in:")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text(recorder.fileURL.deletingLastPathComponent().path)
                            .font(.caption)
                            .textSelection(.enabled)
                        HStack(spacing: 8) {
                            Button("Show in Finder") {
                                NSWorkspace.shared.open(recorder.fileURL.deletingLastPathComponent())
                            }
                            Button("Close") {
                                showConversionSheet = false
                            }
                        }
                    }
                }
            }
            .padding(20)
            .frame(minWidth: 420)
        }
    }

    private func handlingErrors(perform block: () throws -> Void) {
        do {
            try block()
        } catch {
            /// "handling" in the function name might not be entirely true 😅
            NSAlert(error: error).runModal()
        }
    }
}

