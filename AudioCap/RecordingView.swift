import SwiftUI
import UniformTypeIdentifiers
import Observation

@MainActor
struct RecordingView: View {
    let recorder: ProcessTapRecorder

    @State private var settings = RecordingSettings.shared
    @State private var copiedDiagnostics = false

    var body: some View {
        Section {
            HStack {
                if recorder.isRecording {
                    Button("Stop") {
                        recorder.stop()
                    }
                    .id("button")
                } else {
                    Button("Start") {
                        handlingErrors { try recorder.start() }
                    }
                    .id("button")

                    if let url = recorder.lastCompletedURL {
                        FileProxyView(url: url)
                            .transition(.scale.combined(with: .opacity))
                    }
                }

                Spacer()

                if recorder.isRecording {
                    LevelMeterView(level: recorder.level)
                        .frame(width: 240)
                    Text(timeString(recorder.framesWritten))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .animation(.smooth, value: recorder.isRecording)
            .animation(.smooth, value: recorder.lastCompletedURL)

            if let format = recorder.captureFormat {
                LabeledContent("Capture format", value: format.description)
                    .font(.callout)
            }

            if recorder.status == .waitingForSource {
                Text("Waiting for \(recorder.process.name) to start again…")
                    .foregroundStyle(.secondary)
            }

            // Recording settings
            VStack(alignment: .leading, spacing: 8) {
                Toggle(isOn: $settings.autoSplitOnSilence) {
                    Text("Auto-split on silence")
                }
                .tint(.green)
                .disabled(recorder.isRecording)

                HStack(spacing: 8) {
                    LabeledContent("Format") {
                        Picker("Format", selection: $settings.outputFormat) {
                            ForEach(RecordingSettings.OutputFormat.allCases, id: \.self) { format in
                                Text(format.displayName).tag(format)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 200)
                        .disabled(recorder.isRecording) // lock format while recording
                    }
                }

                HStack(spacing: 8) {
                    LabeledContent("Threshold (dB)") {
                        TextField("", value: $settings.silenceThresholdDb, format: .number)
                            .frame(width: 80)
                            .textFieldStyle(.roundedBorder)
                    }
                    LabeledContent("Min silence (s)") {
                        TextField("", value: $settings.minSilenceDuration, format: .number)
                            .frame(width: 80)
                            .textFieldStyle(.roundedBorder)
                    }
                }
                .disabled(recorder.isRecording)
            }

            if let warning = recorder.silenceWarning {
                Label(warning, systemImage: "speaker.slash")
                    .foregroundStyle(.orange)
            }

            if let error = recorder.lastError {
                Text(error)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            HStack {
                Button("Show Recordings in Finder") {
                    NSWorkspace.shared.open(recorder.outputDirectory)
                }
                Spacer()
                Button(copiedDiagnostics ? "Copied" : "Copy Diagnostics") {
                    Diagnostics.copyToPasteboard(recorder.diagnosticsReport())
                    copiedDiagnostics = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copiedDiagnostics = false }
                }
            }
        } header: {
            HStack {
                RecordingIndicator(appIcon: recorder.process.icon, isRecording: recorder.isRecording)

                Text(headerTitle)
                    .font(.headline)
                    .contentTransition(.identity)
            }
        }
    }

    private var headerTitle: String {
        if recorder.isRecording { return "Recording from \(recorder.process.name)" }
        if recorder.isConverting { return "Exporting…" }
        return "Ready to Record from \(recorder.process.name)"
    }

    private func timeString(_ frames: Int64) -> String {
        let rate = recorder.captureFormat?.sampleRate ?? 48_000
        let seconds = Int(Double(frames) / rate)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private func handlingErrors(perform block: () throws -> Void) {
        do {
            try block()
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Recording could not start"
            alert.informativeText = error.audioCapDescription
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Copy Diagnostics")
            if alert.runModal() == .alertSecondButtonReturn {
                Diagnostics.copyToPasteboard(recorder.diagnosticsReport())
            }
        }
    }
}
