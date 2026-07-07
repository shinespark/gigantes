import Foundation
import Observation

/// アプリ全体の表示状態。
enum AppPhase: Equatable {
    /// Bridge・ランプが未設定で、監視を開始できない状態
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

/// UserDefaults に永続化するユーザー設定(秘密情報は含まない)。
struct AppConfig: Codable, Equatable {
    var bridgeIP: String?
    var bridgeID: String?
    var lightIDs: [String] = []
    var onAirColor: RGBColor = .red
    var onAirBrightness: Double = 100
    /// Force ON AIR のグローバルショートカット。nil = 明示的に解除された状態
    var hotkey: HotkeyShortcut? = .default

    var isComplete: Bool {
        bridgeIP != nil && bridgeID != nil && !lightIDs.isEmpty
    }

    init() {}

    // カスタム Codable の理由:
    // - フィールド追加後も旧バージョンで保存した JSON を decode できるようにする
    //   (synthesized 実装ではキー欠落で全体が失敗し、Bridge 設定ごと初期化されてしまう)
    // - hotkey は「キーなし(旧設定)= デフォルト適用」と「null(明示的な解除)= nil」を
    //   区別する必要があるため、encode 時に nil を null として明示的に書く
    private enum CodingKeys: String, CodingKey {
        case bridgeIP, bridgeID, lightIDs, onAirColor, onAirBrightness, hotkey
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bridgeIP = try container.decodeIfPresent(String.self, forKey: .bridgeIP)
        bridgeID = try container.decodeIfPresent(String.self, forKey: .bridgeID)
        lightIDs = try container.decodeIfPresent([String].self, forKey: .lightIDs) ?? []
        onAirColor = try container.decodeIfPresent(RGBColor.self, forKey: .onAirColor) ?? .red
        onAirBrightness = try container.decodeIfPresent(Double.self, forKey: .onAirBrightness) ?? 100
        if container.contains(.hotkey) {
            hotkey = try container.decodeIfPresent(HotkeyShortcut.self, forKey: .hotkey)
        } else {
            hotkey = .default
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(bridgeIP, forKey: .bridgeIP)
        try container.encodeIfPresent(bridgeID, forKey: .bridgeID)
        try container.encode(lightIDs, forKey: .lightIDs)
        try container.encode(onAirColor, forKey: .onAirColor)
        try container.encode(onAirBrightness, forKey: .onAirBrightness)
        try container.encode(hotkey, forKey: .hotkey)
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

        guard !config.lightIDs.isEmpty, let hue = hueClient else {
            phase = .unconfigured
            return
        }
        phase = .idle

        let coordinator = MeetingCoordinator(
            detector: detector,
            hue: hue,
            snapshots: snapshots,
            configuration: .init(
                lightIDs: config.lightIDs,
                onAirColor: config.onAirColor.xy,
                onAirBrightness: config.onAirBrightness
            ),
            onPhaseChange: { [weak self] phase in
                Task { @MainActor in self?.phase = phase }
            }
        )
        self.coordinator = coordinator
        coordinatorTask = Task { await coordinator.run() }
    }
}
