import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Form {
            BridgeSection()
            LightSection()
            OnAirSection()
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .frame(minHeight: 420)
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
        Section("Light") {
            if appState.hueClient == nil {
                Text("Pair with a Hue Bridge first.").foregroundStyle(.secondary)
            } else {
                Picker("ON AIR light", selection: lightSelection) {
                    Text("None").tag(nil as String?)
                    ForEach(lights) { light in
                        Text(light.displayName).tag(light.id as String?)
                    }
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

    private var lightSelection: Binding<String?> {
        Binding(
            get: { appState.config.lightID },
            set: { lightID in
                appState.config.lightID = lightID
                appState.config.lightName = lights.first { $0.id == lightID }?.displayName
            }
        )
    }

    private func loadLights() async {
        guard let client = appState.hueClient else { return }
        do {
            lights = try await client.listLights()
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

            Button("Test Light") { Task { await testLight() } }
                .disabled(testing || appState.config.lightID == nil || appState.hueClient == nil)
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

    /// ON AIR 色を 3 秒間点灯して元の状態に戻す。
    private func testLight() async {
        guard let client = appState.hueClient, let lightID = appState.config.lightID else { return }
        testing = true
        defer { testing = false }
        do {
            let before = try await client.currentSettings(lightID: lightID)
            let onAir = LightSettings(
                isOn: true,
                color: appState.config.onAirColor.xy,
                brightness: appState.config.onAirBrightness
            )
            try await client.apply(onAir, to: lightID)
            try await Task.sleep(for: .seconds(3))
            try await client.apply(before, to: lightID)
            testResult = String(localized: "Test succeeded.")
        } catch {
            testResult = error.localizedDescription
        }
    }
}
