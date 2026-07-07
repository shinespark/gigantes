import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Form {
            if !isSetUp {
                SetupProgressSection()
            }
            GeneralSection()
            BridgeSection()
            LightSection()
            OnAirSection()
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .frame(minHeight: 500)
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
            if appState.config.onAirMode == .scene {
                stepRow(2, "Choose the ON AIR scene", done: appState.config.onAirSceneID != nil)
            } else {
                stepRow(2, "Choose the ON AIR lights", done: appState.config.allLights || !appState.config.lightIDs.isEmpty)
            }
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
    @State private var language = AppLanguage.current

    var body: some View {
        Section("General") {
            Picker("Language", selection: $language) {
                Text("System Default").tag(AppLanguage.system)
                Text(verbatim: "English").tag(AppLanguage.english)
                Text(verbatim: "日本語").tag(AppLanguage.japanese)
            }
            .onChange(of: language) { old, new in
                guard old != new else { return }
                new.apply()
                AppLanguage.relaunchApp()
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

            LabeledContent("Now ON AIR") {
                ShortcutRecorderView(
                    shortcut: hotkeyBinding,
                    onRecordingChanged: { appState.setHotkeyRecording($0) }
                )
            }
            if let hotkeyError = appState.hotkeyError {
                Text(hotkeyError).foregroundStyle(.red)
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
                        Text(verbatim: "\(bridge.ip) (\(bridge.id))").tag(bridge as DiscoveredBridge?)
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

// MARK: - ON AIR 対象の選択(モード + ランプ or シーン)

private struct LightSection: View {
    @Environment(AppState.self) private var appState
    @State private var lights: [HueLight] = []
    @State private var loadError: String?
    @State private var scenes: [HueScene] = []
    @State private var groupNames: [String: String] = [:]
    @State private var sceneLoadError: String?

    var body: some View {
        Section("Lights") {
            Picker("Mode", selection: modeSelection) {
                Text("Color").tag(OnAirMode.color)
                Text("Scene").tag(OnAirMode.scene)
            }
            .pickerStyle(.segmented)

            if appState.hueClient == nil {
                Text("Pair with a Hue Bridge first.").foregroundStyle(.secondary)
            } else {
                switch appState.config.onAirMode {
                case .color:
                    Toggle("All lights", isOn: allLightsBinding)
                    if appState.config.allLights {
                        Text("Every light on the bridge will be used, including lights added later.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(lights) { light in
                            Toggle(light.displayName, isOn: selectionBinding(for: light.id))
                        }
                        if let loadError {
                            Text(loadError).foregroundStyle(.red)
                        }
                        Button("Reload Lights") { Task { await loadLights() } }
                    }

                case .scene:
                    Picker("Scene", selection: sceneSelection) {
                        Text("None").tag(nil as String?)
                        ForEach(scenes) { scene in
                            Text(label(for: scene)).tag(scene.id as String?)
                        }
                    }
                    if let sceneLoadError {
                        Text(sceneLoadError).foregroundStyle(.red)
                    }
                    if isSavedSceneMissing {
                        Text("The selected scene was not found on the bridge. It may have been deleted.")
                            .foregroundStyle(.orange)
                    }
                    Button("Reload Scenes") { Task { await loadScenes() } }
                }
            }
        }
        .task(id: appState.config.bridgeID) {
            await loadLights()
            await loadScenes()
        }
    }

    private var modeSelection: Binding<OnAirMode> {
        Binding(
            get: { appState.config.onAirMode },
            set: { appState.config.onAirMode = $0 }
        )
    }

    private var allLightsBinding: Binding<Bool> {
        Binding(
            get: { appState.config.allLights },
            set: { appState.config.allLights = $0 }
        )
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

    private var isSavedSceneMissing: Bool {
        guard let sceneID = appState.config.onAirSceneID, !scenes.isEmpty else { return false }
        return !scenes.contains { $0.id == sceneID }
    }

    private func label(for scene: HueScene) -> String {
        if let groupID = scene.group?.rid, let groupName = groupNames[groupID] {
            return "\(scene.displayName) – \(groupName)"
        }
        return scene.displayName
    }

    private var sceneSelection: Binding<String?> {
        Binding(
            get: { appState.config.onAirSceneID },
            set: { sceneID in
                appState.config.onAirSceneID = sceneID
                appState.config.onAirSceneName = scenes
                    .first { $0.id == sceneID }
                    .map(label(for:))
            }
        )
    }

    private func loadScenes() async {
        guard let client = appState.hueClient else { return }
        do {
            let groups = try await client.listGroups()
            groupNames = Dictionary(
                groups.map { ($0.id, $0.metadata?.name ?? "") },
                uniquingKeysWith: { first, _ in first }
            )
            scenes = try await client.listScenes()
                .sorted { label(for: $0).localizedStandardCompare(label(for: $1)) == .orderedAscending }
            sceneLoadError = nil
        } catch {
            sceneLoadError = error.localizedDescription
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
            if appState.config.onAirMode == .color {
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
            }

            Button("Test") { Task { await runTest() } }
                .disabled(testing || appState.hueClient == nil || !testTargetSelected)
            if let testResult {
                Text(testResult).foregroundStyle(.secondary)
            }
        }
    }

    private var testTargetSelected: Bool {
        switch appState.config.onAirMode {
        case .color: appState.config.allLights || !appState.config.lightIDs.isEmpty
        case .scene: appState.config.onAirSceneID != nil
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

    /// ON AIR 動作(単色 or シーン)を 3 秒間適用して元の状態に戻す。
    private func runTest() async {
        guard let client = appState.hueClient else { return }
        testing = true
        defer { testing = false }
        do {
            let lightIDs: [String]
            switch appState.config.onAirMode {
            case .color:
                lightIDs = appState.config.allLights
                    ? try await client.listLights().map(\.id)
                    : appState.config.lightIDs
            case .scene:
                guard let sceneID = appState.config.onAirSceneID else { return }
                lightIDs = try await client.sceneLightIDs(sceneID: sceneID)
            }
            guard !lightIDs.isEmpty else { return }

            var before: [String: LightSettings] = [:]
            for lightID in lightIDs {
                before[lightID] = try await client.currentSettings(lightID: lightID)
            }

            switch appState.config.onAirMode {
            case .color:
                let onAir = LightSettings(
                    isOn: true,
                    color: appState.config.onAirColor.xy,
                    brightness: appState.config.onAirBrightness
                )
                for lightID in lightIDs {
                    try await client.apply(onAir, to: lightID)
                }
            case .scene:
                try await client.recallScene(sceneID: appState.config.onAirSceneID!)
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
