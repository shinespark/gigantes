import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Form {
            Text("Settings will be implemented in Phase 5.")
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 360)
    }
}
