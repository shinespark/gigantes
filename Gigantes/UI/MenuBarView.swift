import SwiftUI

struct MenuBarView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Text(appState.phase.label)

        Divider()

        SettingsLink {
            Text("Settings…")
        }
        .keyboardShortcut(",")

        Divider()

        Button("Quit Gigantes") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
