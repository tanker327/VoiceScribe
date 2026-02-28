import SwiftUI

@main
struct VoiceScribeApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .frame(minWidth: 720, minHeight: 520)
                .frame(idealWidth: 840, idealHeight: 620)
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 840, height: 620)

        Settings {
            SettingsView()
                .environmentObject(appState)
        }
    }
}
