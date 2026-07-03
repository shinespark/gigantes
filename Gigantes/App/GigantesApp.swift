import SwiftUI

@main
struct GigantesApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environment(appState)
        } label: {
            Image(systemName: appState.phase.symbolName)
        }

        Settings {
            SettingsView()
                .environment(appState)
        }
    }
}
