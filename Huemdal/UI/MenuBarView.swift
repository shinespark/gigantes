import SwiftUI

struct MenuBarView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Text(appState.phase.label)

        if case .error = appState.phase {
            Button("Reconnect") {
                appState.retry()
            }
        }

        if appState.phase != .unconfigured {
            Toggle("Force ON AIR", isOn: Binding(
                get: { appState.manualOverride },
                set: { appState.setManualOverride($0) }
            ))
        }

        Divider()

        Button(appState.phase == .unconfigured ? "Set Up…" : "Settings…") {
            // LSUIElement のエージェントアプリは明示的に前面化しないと
            // 設定ウィンドウが背面に出てしまう
            NSApp.activate(ignoringOtherApps: true)
            openSettings()
        }
        .keyboardShortcut(",")

        Divider()

        Button("Quit Huemdal") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
