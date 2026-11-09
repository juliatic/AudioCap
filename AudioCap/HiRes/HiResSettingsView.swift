import SwiftUI

/// Settings window (⌘,): Hi-Res on/off and the fixed rate for apps other than Music.
struct HiResSettingsView: View {
    @Bindable private var settings = HiResSettings.shared
    private let controller = HiResController.shared

    var body: some View {
        Form {
            Section {
                Toggle("Hi-Res mode", isOn: $settings.isEnabled)
                Text("While recording, apps play into the silent AudioCap Hi-Res device at a high sample rate, and AudioCap plays a copy on your speakers or headphones. Only that copy is resampled.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("Rate for other apps", selection: $settings.fixedRate) {
                    ForEach(HiResDevice.supportedRates, id: \.self) { rate in
                        Text(verbatim: HiResDevice.rateString(rate)).tag(rate)
                    }
                }
                .disabled(!settings.isEnabled)
                Text("Music.app recordings use the sample rate of the current track. Other apps, or tracks with an unknown rate, use this rate.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if controller.isDriverAvailable {
                    Label("Driver installed", systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                } else {
                    Label("The AudioCap Hi-Res driver is not installed. Run ./start.sh --install-driver, then reopen AudioCap.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }
}
