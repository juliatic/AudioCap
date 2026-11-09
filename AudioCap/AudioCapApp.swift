import SwiftUI

let kAppSubsystem = "io.github.juliatic.AudioCap"

@main
struct AudioCapApp: App {
    init() {
        HiResController.shared.recoverOnLaunch()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
        Settings {
            HiResSettingsView()
        }
    }
}
