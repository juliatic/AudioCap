import SwiftUI

/// Hi-Res line in the recording section: route and monitor while recording, plus monitor volume and mute.
struct HiResStatusView: View {
    private let controller = HiResController.shared
    @Bindable private var settings = HiResSettings.shared

    var body: some View {
        if settings.isEnabled, controller.isDriverAvailable || controller.message != nil {
            VStack(alignment: .leading, spacing: 6) {
                if let decision = controller.rateDecision, controller.isRouted {
                    Text("Hi-Res: \(HiResDevice.rateString(decision.rate)) (\(sourceLabel(decision.source))) · monitor: \(monitorDescription)")
                        .font(AppStyle.detail)
                } else if controller.isDriverAvailable {
                    Text("Hi-Res is on. Recording switches the system output to AudioCap Hi-Res and restores it when you stop.")
                        .secondaryTextStyle()
                }
                if let message = controller.message {
                    Text(message)
                        .warningTextStyle()
                }
                if controller.isDriverAvailable {
                    HStack {
                        Slider(value: Binding(get: { controller.monitorVolume }, set: { controller.monitorVolume = $0 }), in: 0...1) {
                            Text("Monitor volume")
                        }
                        Toggle("Mute monitor", isOn: Binding(get: { controller.isMonitorMuted }, set: { controller.isMonitorMuted = $0 }))
                    }
                }
            }
        }
    }

    private func sourceLabel(_ source: HiResRatePolicy.Source) -> String {
        switch source {
        case .musicTrack: String(localized: "track rate")
        case .fixed: String(localized: "fixed rate")
        }
    }

    private var monitorDescription: String {
        let name = controller.monitorDevice?.name ?? "-"
        guard let rate = controller.monitorOutputRate else { return name }
        return "\(name) \(HiResDevice.rateString(rate))"
    }
}
