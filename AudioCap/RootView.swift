import SwiftUI

@MainActor
struct RootView: View {
    @State private var permission = AudioRecordingPermission()
    @State private var isRequestingPermission = false

    var body: some View {
        Form {
            switch permission.status {
            case .unknown:
                requestPermissionView
            case .authorized:
                recordingView
            case .denied:
                permissionDeniedView
            }
        }
        .formStyle(.grouped)
        .font(AppStyle.body)
        .controlSize(.large)
        .onChange(of: permission.status) { isRequestingPermission = false }
    }

    @ViewBuilder
    private var requestPermissionView: some View {
        LabeledContent("Please Allow Audio Recording") {
            Button(readable: "Allow") {
                isRequestingPermission = true
                permission.request()
            }
            .disabled(isRequestingPermission)
            .keyboardShortcut(.defaultAction)
        }
    }

    @ViewBuilder
    private var permissionDeniedView: some View {
        LabeledContent("Audio Recording Permission Required") {
            Button(readable: "Open System Settings") {
                NSWorkspace.shared.openSystemSettings()
            }
            .keyboardShortcut(.defaultAction)
        }
    }

    @ViewBuilder
    private var recordingView: some View {
        ProcessSelectionView()
    }
}

extension NSWorkspace {
    func openSystemSettings() {
        guard let url = urlForApplication(withBundleIdentifier: "com.apple.systempreferences") else {
            assertionFailure("Failed to get System Settings app URL")
            return
        }

        openApplication(at: url, configuration: .init())
    }
}

#if DEBUG
#Preview {
    RootView()
}
#endif
