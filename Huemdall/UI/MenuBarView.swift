import SwiftUI

struct MenuBarView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Label(appState.phase.label, systemImage: appState.phase.symbolName)

        if case .error = appState.phase {
            Button {
                appState.retry()
            } label: {
                Label("Reconnect", systemImage: "arrow.clockwise")
            }
        }

        if appState.phase != .unconfigured {
            Toggle(isOn: Binding(
                get: { appState.manualOverride },
                set: { appState.setManualOverride($0) }
            )) {
                Label("Now ON AIR", systemImage: "record.circle.fill")
            }
        }

        Divider()

        Button {
            // LSUIElement のエージェントアプリは明示的に前面化しないと
            // 設定ウィンドウが背面に出てしまう
            NSApp.activate(ignoringOtherApps: true)
            openSettings()
        } label: {
            Label(
                appState.phase == .unconfigured ? "Set Up…" : "Settings…",
                systemImage: "gearshape"
            )
        }
        .keyboardShortcut(",")

        Divider()

        Button {
            NSApp.terminate(nil)
        } label: {
            Label("Quit Huemdall", systemImage: "power")
        }
        .keyboardShortcut("q")
    }
}
