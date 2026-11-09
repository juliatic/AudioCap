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
                    LevelMeter(level: recorder.level)
                        .frame(width: 120, height: 6)
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

            if recorder.status == .waitingForSource {
                Text("Waiting for \(recorder.process.name) to start again…")
                    .secondaryTextStyle()
            }

            // Recording settings
            VStack(alignment: .leading, spacing: 8) {
                Toggle(isOn: $settings.autoSplitOnSilence) {
                    Text("Auto-split on silence")
                }
                .tint(.green)
                .disabled(isLocked)

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

        if !recorder.takes.isEmpty {
            Section {
                ForEach(recorder.takes.reversed()) { take in
                    TakeRow(take: take)
                }
            } header: {
                Text("Takes")
                    .font(AppStyle.headline)
                    .accessibilityAddTraits(.isHeader)
            }
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

private struct TakeRow: View {
    let take: RecordingTake

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(take.outputURL.lastPathComponent)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(take.captureFormat.displayDescription) → \(take.outputFormat.displayName) · \(take.duration.formatted(.number.precision(.fractionLength(3)))) s")
                    .secondaryTextStyle()
                if case .failed(let message) = take.status {
                    Text(message)
                        .errorTextStyle()
                        .textSelection(.enabled)
                }
            }
            Spacer()
            switch take.status {
            case .recording:
                Text("Recording").foregroundStyle(AppStyle.errorText.color)
            case .exporting(let progress):
                ProgressView(value: progress) {
                    Text("Exporting…")
                }
                .labelsHidden()
                .frame(width: 80)
                .accessibilityValue(Text(progress.formatted(.percent.precision(.fractionLength(0)))))
            case .completed:
                Button(readable: "Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([take.outputURL])
                }
            case .failed:
                Button(readable: "Show Capture") {
                    NSWorkspace.shared.activateFileViewerSelecting([take.captureURL])
                }
            }
        }
    }
}

private struct LevelMeter: View {
    let level: AudioLevel

    var body: some View {
        GeometryReader { proxy in
            let fraction = max(0, min(1, (level.peakDb + 60) / 60))
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(level.peakDb > -1 ? Color.red : Color.green)
                    .frame(width: proxy.size.width * fraction)
            }
        }
        .accessibilityLabel(Text("Level"))
        .accessibilityValue(Text("\(Int(level.peakDb.rounded())) dB"))
    }
}
