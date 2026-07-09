import Foundation
import Observation

/// アプリ全体の表示状態。
enum AppPhase: Equatable {
    /// Bridge・ライトが未設定で、監視を開始できない状態
    case unconfigured
    case idle
    case onAir
    case error(String)

    var symbolName: String {
        switch self {
        case .unconfigured: "record.circle"
        case .idle: "record.circle"
        case .onAir: "record.circle.fill"
        case .error: "exclamationmark.triangle"
        }
    }

    var label: String {
        switch self {
        case .unconfigured: String(localized: "Not configured")
        case .idle: String(localized: "Standby")
        case .onAir: String(localized: "ON AIR")
        case .error(let message): message
        }
    }
}

/// ON AIR 時の動作モード。
enum OnAirMode: String, Codable {
    /// 選択したライトを単色に変更する
    case color
    /// Hue シーンを適用する(対象ライトはシーンが決める)
    case scene
}

/// UserDefaults に永続化するユーザー設定(秘密情報は含まない)。
struct AppConfig: Codable, Equatable {
    var bridgeIP: String?
    var bridgeID: String?
    var lightIDs: [String] = []
    /// true = Bridge 上の全ライトを対象にする(ON AIR のたびに解決するため、後から追加したライトも含む)
    var allLights = false
    var onAirMode: OnAirMode = .color
    var onAirColor: RGBColor = .red
    var onAirBrightness: Double = 100
    var onAirSceneID: String?
    /// "シーン名 – 部屋名" の表示用キャッシュ(再取得なしで表示するため)
    var onAirSceneName: String?
    /// Now ON AIR のグローバルショートカット。nil = 明示的に解除された状態
    var hotkey: HotkeyShortcut? = .default
    /// カメラ使用の自動検知で ON AIR を切り替えるか(OFF でも手動 ON AIR は使える)
    var cameraDetectionEnabled = true

    var isComplete: Bool {
        guard bridgeIP != nil, bridgeID != nil else { return false }
        switch onAirMode {
        case .color: return allLights || !lightIDs.isEmpty
        case .scene: return onAirSceneID != nil
        }
    }

    init() {}

    // カスタム Codable の理由:
    // - フィールド追加後も旧バージョンで保存した JSON を decode できるようにする
    //   (synthesized 実装ではキー欠落で全体が失敗し、Bridge 設定ごと初期化されてしまう)
    // - hotkey は「キーなし(旧設定)= デフォルト適用」と「null(明示的な解除)= nil」を
    //   区別する必要があるため、encode 時に nil を null として明示的に書く
    private enum CodingKeys: String, CodingKey {
        case bridgeIP, bridgeID, lightIDs, allLights, onAirMode, onAirColor, onAirBrightness
        case onAirSceneID, onAirSceneName, hotkey, cameraDetectionEnabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bridgeIP = try container.decodeIfPresent(String.self, forKey: .bridgeIP)
        bridgeID = try container.decodeIfPresent(String.self, forKey: .bridgeID)
        lightIDs = try container.decodeIfPresent([String].self, forKey: .lightIDs) ?? []
        allLights = try container.decodeIfPresent(Bool.self, forKey: .allLights) ?? false
        onAirMode = try container.decodeIfPresent(OnAirMode.self, forKey: .onAirMode) ?? .color
        onAirColor = try container.decodeIfPresent(RGBColor.self, forKey: .onAirColor) ?? .red
        onAirBrightness = try container.decodeIfPresent(Double.self, forKey: .onAirBrightness) ?? 100
        onAirSceneID = try container.decodeIfPresent(String.self, forKey: .onAirSceneID)
        onAirSceneName = try container.decodeIfPresent(String.self, forKey: .onAirSceneName)
        if container.contains(.hotkey) {
            hotkey = try container.decodeIfPresent(HotkeyShortcut.self, forKey: .hotkey)
        } else {
            hotkey = .default
        }
        cameraDetectionEnabled = try container.decodeIfPresent(Bool.self, forKey: .cameraDetectionEnabled) ?? true
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(bridgeIP, forKey: .bridgeIP)
        try container.encodeIfPresent(bridgeID, forKey: .bridgeID)
        try container.encode(lightIDs, forKey: .lightIDs)
        try container.encode(allLights, forKey: .allLights)
        try container.encode(onAirMode, forKey: .onAirMode)
        try container.encode(onAirColor, forKey: .onAirColor)
        try container.encode(onAirBrightness, forKey: .onAirBrightness)
        try container.encodeIfPresent(onAirSceneID, forKey: .onAirSceneID)
        try container.encodeIfPresent(onAirSceneName, forKey: .onAirSceneName)
        try container.encode(hotkey, forKey: .hotkey)
        try container.encode(cameraDetectionEnabled, forKey: .cameraDetectionEnabled)
    }

    private static let defaultsKey = "appConfig"

    static func load(from defaults: UserDefaults = .standard) -> AppConfig {
        guard let data = defaults.data(forKey: defaultsKey),
              let config = try? JSONDecoder().decode(AppConfig.self, from: data) else {
            return AppConfig()
        }
        return config
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(try? JSONEncoder().encode(self), forKey: Self.defaultsKey)
    }
}

@Observable
@MainActor
final class AppState {
    private(set) var phase: AppPhase = .unconfigured

    var config: AppConfig {
        didSet {
            guard config != oldValue else { return }
            config.save()

            if config.hotkey != oldValue.hotkey {
                syncHotkey()
            }
            // ホットキーだけの変更で監視を再起動しない
            // (restartCoordinator は manualOverride を解除してしまうため)
            var newHueConfig = config
            newHueConfig.hotkey = nil
            var oldHueConfig = oldValue
            oldHueConfig.hotkey = nil
            if newHueConfig != oldHueConfig {
                restartCoordinator()
            }
        }
    }

    /// 強制 ON AIR の UI 表示状態(実際の遷移は coordinator 側の状態機械が判断する)
    private(set) var manualOverride = false

    /// ホットキー登録に失敗した場合のエラーメッセージ(設定画面に表示)
    private(set) var hotkeyError: String?

    let secrets: any SecretStoring = KeychainStore()
    private let detector = CameraDetector()
    private let snapshots = UserDefaultsSnapshotStore()
    private let hotkeyManager = HotkeyManager()
    private var coordinator: MeetingCoordinator?
    private var coordinatorTask: Task<Void, Never>?

    init() {
        config = AppConfig.load()
        restartCoordinator()
        syncHotkey()
    }

    /// 設定済みの Bridge に対する API クライアント。未設定・未ペアリングなら nil。
    var hueClient: HueClient? {
        guard let bridgeIP = config.bridgeIP,
              let bridgeID = config.bridgeID,
              let key = secrets.applicationKey(for: bridgeID) else {
            return nil
        }
        return HueClient(bridgeIP: bridgeIP, bridgeID: bridgeID, applicationKey: key)
    }

    /// すべての設定を初期状態に戻す。
    /// Keychain のペアリングキーと未復元スナップショットも削除する。
    func resetAllSettings() {
        if let bridgeID = config.bridgeID {
            secrets.deleteApplicationKey(for: bridgeID)
        }
        snapshots.clear()
        config = AppConfig()
    }

    /// エラー時にメニューバーから手動で再接続する。
    func retry() {
        restartCoordinator()
    }

    /// メニューバーまたはグローバルショートカットからの強制 ON AIR / 解除。
    func setManualOverride(_ enabled: Bool) {
        guard let coordinator else { return }
        manualOverride = enabled
        Task { await coordinator.setManualOverride(enabled) }
    }

    /// ショートカット録画中は既存ホットキーを一時解除する。
    /// 登録済みのコンボは Carbon が先に消費してしまい、録画モニタに届かないため。
    func setHotkeyRecording(_ active: Bool) {
        if active {
            hotkeyManager.unregister()
        } else {
            syncHotkey()
        }
    }

    /// 設定に応じてグローバルホットキーを登録し直す。
    /// Hue 未設定でも登録する(コールバック側の setManualOverride が no-op になるだけで安全)。
    private func syncHotkey() {
        hotkeyManager.unregister()
        hotkeyError = nil
        guard let shortcut = config.hotkey else { return }
        do {
            try hotkeyManager.register(shortcut) { [weak self] in
                guard let self else { return }
                self.setManualOverride(!self.manualOverride)
            }
        } catch {
            hotkeyError = String(localized: "Could not register the shortcut. It may be in use by the system.")
        }
    }

    /// 設定が揃っていれば監視を開始し、揃っていなければ停止する。
    private func restartCoordinator() {
        coordinatorTask?.cancel()
        coordinatorTask = nil
        coordinator = nil
        manualOverride = false

        let onAirAction: MeetingCoordinator.Configuration.OnAirAction
        switch config.onAirMode {
        case .color:
            guard config.allLights || !config.lightIDs.isEmpty else {
                phase = .unconfigured
                return
            }
            onAirAction = .color(
                target: config.allLights ? .allLights : .lights(config.lightIDs),
                color: config.onAirColor.xy,
                brightness: config.onAirBrightness
            )
        case .scene:
            guard let sceneID = config.onAirSceneID else {
                phase = .unconfigured
                return
            }
            onAirAction = .scene(sceneID: sceneID)
        }
        guard let hue = hueClient else {
            phase = .unconfigured
            return
        }
        phase = .idle

        let activityDetector: any ActivityDetector =
            config.cameraDetectionEnabled ? detector : DisabledActivityDetector()
        let coordinator = MeetingCoordinator(
            detector: activityDetector,
            hue: hue,
            snapshots: snapshots,
            configuration: .init(onAirAction: onAirAction),
            onPhaseChange: { [weak self] phase in
                Task { @MainActor in self?.phase = phase }
            }
        )
        self.coordinator = coordinator
        coordinatorTask = Task { await coordinator.run() }
    }
}
