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
                    Button(readable: "Stop") {
                        recorder.stop()
                    }
                    .keyboardShortcut("r", modifiers: .command)
                    .help(Text("Stop recording (⌘R)"))
                    .id("button")
                } else {
                    Button(readable: "Start") {
                        handlingErrors { try recorder.start() }
                    }
                    .keyboardShortcut("r", modifiers: .command)
                    .help(Text("Start recording (⌘R)"))
                    .disabled(recorder.isConverting)
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
                        .secondaryTextStyle()
                        .accessibilityLabel(Text("Recorded time"))
                }
            }
            .animation(.smooth, value: recorder.isRecording)
            .animation(.smooth, value: recorder.lastCompletedURL)

            if let format = recorder.captureFormat {
                LabeledContent("Capture format", value: format.displayDescription)
            }

            HiResStatusView()

            if recorder.status == .waitingForSource {
                Text("Waiting for \(recorder.process.name) to start again…")
                    .secondaryTextStyle()
            }

            AutoRecordControls(recorder: recorder)

            // Recording settings
            VStack(alignment: .leading, spacing: 8) {
                Toggle(isOn: $settings.autoSplitOnSilence) {
                    Text("Auto-split on silence")
                }
                .tint(.green)
                .disabled(isLocked || recorder.mode == .waitForSound)

                HStack(spacing: 8) {
                    LabeledContent("Format") {
                        Picker("Format", selection: $settings.outputFormat) {
                            ForEach(RecordingSettings.OutputFormat.allCases, id: \.self) { format in
                                Text(format.displayName).font(AppStyle.body).tag(format)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 260)
                        .disabled(isLocked)
                    }
                }

                HStack(spacing: 8) {
                    LabeledContent("Threshold (dB)") {
                        TextField("Threshold (dB)", value: $settings.silenceThresholdDb, format: .number)
                            .labelsHidden()
                            .frame(width: 80)
                            .textFieldStyle(.roundedBorder)
                            .font(AppStyle.body)
                    }
                    LabeledContent("Min silence (s)") {
                        TextField("Min silence (s)", value: $settings.minSilenceDuration, format: .number)
                            .labelsHidden()
                            .frame(width: 80)
                            .textFieldStyle(.roundedBorder)
                            .font(AppStyle.body)
                    }
                }
                .disabled(isLocked)
            }

            if let warning = recorder.silenceWarning {
                Label(warning, systemImage: "speaker.slash")
                    .warningTextStyle()
            }

            if let error = recorder.lastError {
                Text(error)
                    .errorTextStyle()
                    .textSelection(.enabled)
            }

            HStack {
                Button(readable: "Show Recordings in Finder") {
                    NSWorkspace.shared.open(recorder.outputDirectory)
                }
                Spacer()
                Button(readable: copiedDiagnostics ? LocalizedStringKey("Copied") : LocalizedStringKey("Copy Diagnostics")) {
                    Diagnostics.copyToPasteboard(recorder.diagnosticsReport())
                    copiedDiagnostics = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copiedDiagnostics = false }
                }
            }
        } header: {
            HStack {
                RecordingIndicator(appIcon: recorder.process.icon, isRecording: recorder.isRecording)
                    .accessibilityHidden(true)

                Text(headerTitle)
                    .font(AppStyle.headline)
                    .contentTransition(.identity)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
        }
    }

    /// Settings and the start button stay locked while a take is recorded or exported.
    private var isLocked: Bool { recorder.isRecording || recorder.isConverting }

    private var headerTitle: String {
        if recorder.isRecording { return String(localized: "Recording from \(recorder.process.name)") }
        if recorder.isConverting { return String(localized: "Exporting…") }
        return String(localized: "Ready to Record from \(recorder.process.name)")
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
            alert.messageText = String(localized: "Recording could not start")
            alert.informativeText = error.audioCapDescription
            alert.addButton(withTitle: String(localized: "OK"))
            alert.addButton(withTitle: String(localized: "Copy Diagnostics"))
            if alert.runModal() == .alertSecondButtonReturn {
                Diagnostics.copyToPasteboard(recorder.diagnosticsReport())
            }
        }
    }
}
