import SwiftUI

@main
struct VoiceScribeApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .frame(minWidth: 400, minHeight: 520)
                .frame(idealWidth: 440, idealHeight: 620)
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 440, height: 620)

        Settings {
            SettingsView()
                .environmentObject(appState)
        }
    }
}
