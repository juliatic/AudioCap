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
                    .secondaryTextStyle()

                Picker("Rate for other apps", selection: $settings.fixedRate) {
                    ForEach(HiResDevice.supportedRates, id: \.self) { rate in
                        Text(verbatim: HiResDevice.rateString(rate)).tag(rate)
                    }
                }
                .disabled(!settings.isEnabled)
                Text("Music.app recordings use the sample rate of the current track. Other apps, or tracks with an unknown rate, use this rate.")
                    .secondaryTextStyle()

                if controller.isDriverAvailable {
                    Label("Driver installed", systemImage: "checkmark.circle")
                        .secondaryTextStyle()
                } else {
                    Label("The AudioCap Hi-Res driver is not installed. Run ./start.sh --install-driver, then reopen AudioCap.", systemImage: "exclamationmark.triangle")
                        .warningTextStyle()
                }
            }
        }
        .formStyle(.grouped)
        .font(AppStyle.body)
        .disabled(controller.isRouted)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }
}
