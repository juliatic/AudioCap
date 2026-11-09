import SwiftUI

/// Recording mode ("Wait for sound" or manual) and its silence settings, plus the armed/recording state.
struct AutoRecordControls: View {
    let recorder: ProcessTapRecorder
    @State private var settings = AutoRecordSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Recording mode", selection: modeBinding) {
                Text("Wait for sound").tag(AutoRecordMachine.Mode.waitForSound)
                Text("Manual").tag(AutoRecordMachine.Mode.manual)
            }
            .pickerStyle(.segmented)

            if settings.mode == .waitForSound {
                Text("Start arms the recorder: a take opens when sound arrives, with half a second of pre-roll, and closes after the silence below. Stop disarms.")
                    .secondaryTextStyle()
                    .fixedSize(horizontal: false, vertical: true)

                LabeledContent("Sound threshold") {
                    HStack {
                        Slider(value: $settings.thresholdDb, in: AutoRecordSettings.thresholdRange, step: 1)
                            .frame(width: 160)
                            .accessibilityValue(Text("\(Int(settings.thresholdDb)) dBFS"))
                        Text("\(Int(settings.thresholdDb)) dBFS")
                            .monospacedDigit()
                    }
                }
                .disabled(recorder.isRecording)

                LabeledContent("Close take after silence") {
                    Stepper(value: $settings.minSilence, in: AutoRecordSettings.minSilenceRange, step: 0.5) {
                        Text("\(settings.minSilence, specifier: "%.1f") s")
                            .monospacedDigit()
                    }
                }
                .disabled(recorder.isRecording)

                if recorder.isWaitingForSound {
                    Label("Waiting for sound…", systemImage: "waveform.badge.magnifyingglass")
                        .warningTextStyle()
                }
            }
        }
    }

    private var modeBinding: Binding<AutoRecordMachine.Mode> {
        Binding {
            settings.mode
        } set: { newMode in
            settings.mode = newMode
            recorder.setMode(newMode)
        }
    }
}
