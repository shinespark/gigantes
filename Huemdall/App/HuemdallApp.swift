import SwiftUI

@main
struct HuemdallApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environment(appState)
        } label: {
            MenuBarLabel()
                .environment(appState)
        }

        Settings {
            SettingsView()
                .environment(appState)
        }
    }
}

private struct MenuBarLabel: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Image(systemName: appState.phase.symbolName)
            .task {
                // 初回起動(未設定)ではメニューバーに気づいてもらえないことが多いため、
                // 設定ウィンドウを自動で開いてオンボーディングを始める
                if appState.phase == .unconfigured {
                    NSApp.activate(ignoringOtherApps: true)
                    openSettings()
                }
            }
    }
}
