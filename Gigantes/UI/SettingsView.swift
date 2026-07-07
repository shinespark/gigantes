import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Form {
            if !isSetUp {
                SetupProgressSection()
            }
            BridgeSection()
            LightSection()
            OnAirSection()
            GeneralSection()
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .frame(minHeight: 460)
    }

    private var isSetUp: Bool {
        appState.config.isComplete && appState.hueClient != nil
    }
}

// MARK: - オンボーディング(セットアップ進捗)

private struct SetupProgressSection: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Section("Setup") {
            stepRow(1, "Pair with your Hue Bridge", done: appState.hueClient != nil)
            stepRow(2, "Choose the ON AIR lights", done: !appState.config.lightIDs.isEmpty)
            stepRow(3, "Pick a color and test it", done: false)
        }
    }

    private func stepRow(_ number: Int, _ title: LocalizedStringKey, done: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: done ? "checkmark.circle.fill" : "\(number).circle")
                .foregroundStyle(done ? .green : .secondary)
            Text(title)
                .foregroundStyle(done ? .secondary : .primary)
        }
    }
}

// MARK: - 一般設定

private struct GeneralSection: View {
    @Environment(AppState.self) private var appState
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchAtLoginError: String?

    var body: some View {
        Section("General") {
            LabeledContent("Force ON AIR shortcut") {
                ShortcutRecorderView(
                    shortcut: hotkeyBinding,
                    onRecordingChanged: { appState.setHotkeyRecording($0) }
                )
            }
            if let hotkeyError = appState.hotkeyError {
                Text(hotkeyError).foregroundStyle(.red)
            }

            Toggle("Launch at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, enabled in
                    do {
                        if enabled {
                            try SMAppService.mainApp.register()
                        } else {
                            try SMAppService.mainApp.unregister()
                        }
                        launchAtLoginError = nil
                    } catch {
                        launchAtLoginError = error.localizedDescription
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
                }
            if let launchAtLoginError {
                Text(launchAtLoginError).foregroundStyle(.red)
            }
        }
    }

    private var hotkeyBinding: Binding<HotkeyShortcut?> {
        Binding(
            get: { appState.config.hotkey },
            set: { appState.config.hotkey = $0 }
        )
    }
}

// MARK: - Bridge の発見とペアリング

private struct BridgeSection: View {
    enum PairingState: Equatable {
        case idle
        case discovering
        case waitingForLinkButton
        case failed(String)
    }

    @Environment(AppState.self) private var appState
    @State private var pairingState: PairingState = .idle
    @State private var discovered: [DiscoveredBridge] = []
    @State private var pairingTask: Task<Void, Never>?

    var body: some View {
        Section("Hue Bridge") {
            if let bridgeIP = appState.config.bridgeIP {
                LabeledContent("Bridge", value: bridgeIP)
                LabeledContent("Status") {
                    if appState.hueClient != nil {
                        Text("Paired").foregroundStyle(.green)
                    } else {
                        Text("Not paired").foregroundStyle(.orange)
                    }
                }
            }

            switch pairingState {
            case .idle:
                Button(appState.config.bridgeIP == nil ? "Search for Bridge…" : "Search Again…") {
                    discover()
                }
            case .discovering:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Searching for Hue Bridge…")
                }
            case .waitingForLinkButton:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Press the link button on your Hue Bridge")
                }
                Button("Cancel") {
                    pairingTask?.cancel()
                    pairingState = .idle
                }
            case .failed(let message):
                Text(message).foregroundStyle(.red)
                Button("Try Again…") { discover() }
            }

            if discovered.count > 1 {
                Picker("Found bridges", selection: bridgeSelection) {
                    ForEach(discovered) { bridge in
                        Text("\(bridge.ip) (\(bridge.id))").tag(bridge as DiscoveredBridge?)
                    }
                }
            }
        }
    }

    private var bridgeSelection: Binding<DiscoveredBridge?> {
        Binding(
            get: { discovered.first { $0.id == appState.config.bridgeID } },
            set: { bridge in
                if let bridge { pair(with: bridge) }
            }
        )
    }

    private func discover() {
        pairingState = .discovering
        pairingTask = Task {
            do {
                let bridges = try await BridgeDiscovery().discover()
                discovered = bridges
                guard let bridge = bridges.first else {
                    pairingState = .failed(String(localized: "No Hue Bridge found on the local network."))
                    return
                }
                pair(with: bridge)
            } catch {
                pairingState = .failed(error.localizedDescription)
            }
        }
    }

    /// リンクボタンが押されるまで 2 秒間隔で最大 30 秒ポーリングする。
    private func pair(with bridge: DiscoveredBridge) {
        pairingState = .waitingForLinkButton
        pairingTask = Task {
            let client = HueClient(bridgeIP: bridge.ip, bridgeID: bridge.id, applicationKey: nil)
            do {
                for _ in 0..<15 {
                    guard !Task.isCancelled else { return }
                    if case .success(let key) = try await client.attemptPairing() {
                        try appState.secrets.setApplicationKey(key, for: bridge.id)
                        appState.config.bridgeIP = bridge.ip
                        appState.config.bridgeID = bridge.id
                        pairingState = .idle
                        return
                    }
                    try await Task.sleep(for: .seconds(2))
                }
                pairingState = .failed(String(localized: "Link button was not pressed in time."))
            } catch is CancellationError {
                // キャンセル時は何もしない
            } catch {
                pairingState = .failed(error.localizedDescription)
            }
        }
    }
}

// MARK: - ランプ選択

private struct LightSection: View {
    @Environment(AppState.self) private var appState
    @State private var lights: [HueLight] = []
    @State private var loadError: String?

    var body: some View {
        Section("Lights") {
            if appState.hueClient == nil {
                Text("Pair with a Hue Bridge first.").foregroundStyle(.secondary)
            } else {
                ForEach(lights) { light in
                    Toggle(light.displayName, isOn: selectionBinding(for: light.id))
                }
                if let loadError {
                    Text(loadError).foregroundStyle(.red)
                }
                Button("Reload Lights") { Task { await loadLights() } }
            }
        }
        .task(id: appState.config.bridgeID) {
            await loadLights()
        }
    }

    private func selectionBinding(for lightID: String) -> Binding<Bool> {
        Binding(
            get: { appState.config.lightIDs.contains(lightID) },
            set: { selected in
                if selected {
                    if !appState.config.lightIDs.contains(lightID) {
                        appState.config.lightIDs.append(lightID)
                    }
                } else {
                    appState.config.lightIDs.removeAll { $0 == lightID }
                }
            }
        )
    }

    private func loadLights() async {
        guard let client = appState.hueClient else { return }
        do {
            lights = try await client.listLights()
                .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }
}

// MARK: - ON AIR 時の色・輝度

private struct OnAirSection: View {
    @Environment(AppState.self) private var appState
    @State private var testResult: String?
    @State private var testing = false

    var body: some View {
        Section("ON AIR") {
            ColorPicker("Color", selection: colorSelection, supportsOpacity: false)

            LabeledContent("Brightness") {
                Slider(value: brightnessSelection, in: 1...100) {
                    EmptyView()
                } minimumValueLabel: {
                    Image(systemName: "sun.min")
                } maximumValueLabel: {
                    Image(systemName: "sun.max")
                }
                .frame(width: 220)
            }

            Button("Test Lights") { Task { await testLights() } }
                .disabled(testing || appState.config.lightIDs.isEmpty || appState.hueClient == nil)
            if let testResult {
                Text(testResult).foregroundStyle(.secondary)
            }
        }
    }

    private var colorSelection: Binding<Color> {
        Binding(
            get: {
                let rgb = appState.config.onAirColor
                return Color(.sRGB, red: rgb.red, green: rgb.green, blue: rgb.blue)
            },
            set: { color in
                guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return }
                appState.config.onAirColor = RGBColor(
                    red: rgb.redComponent, green: rgb.greenComponent, blue: rgb.blueComponent
                )
            }
        )
    }

    private var brightnessSelection: Binding<Double> {
        Binding(
            get: { appState.config.onAirBrightness },
            set: { appState.config.onAirBrightness = $0 }
        )
    }

    /// 選択中の全ランプを ON AIR 色で 3 秒間点灯して元の状態に戻す。
    private func testLights() async {
        guard let client = appState.hueClient else { return }
        let lightIDs = appState.config.lightIDs
        guard !lightIDs.isEmpty else { return }
        testing = true
        defer { testing = false }
        do {
            var before: [String: LightSettings] = [:]
            for lightID in lightIDs {
                before[lightID] = try await client.currentSettings(lightID: lightID)
            }
            let onAir = LightSettings(
                isOn: true,
                color: appState.config.onAirColor.xy,
                brightness: appState.config.onAirBrightness
            )
            for lightID in lightIDs {
                try await client.apply(onAir, to: lightID)
            }
            try await Task.sleep(for: .seconds(3))
            for (lightID, settings) in before {
                try await client.apply(settings, to: lightID)
            }
            testResult = String(localized: "Test succeeded.")
        } catch {
            testResult = error.localizedDescription
        }
    }
}
