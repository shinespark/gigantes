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
    var lightID: String?
    var lightName: String?
    var onAirColor: RGBColor = .red
    var onAirBrightness: Double = 100

    var isComplete: Bool {
        bridgeIP != nil && bridgeID != nil && lightID != nil
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
            restartCoordinator()
        }
    }

    /// 強制 ON AIR の UI 表示状態(実際の遷移は coordinator 側の状態機械が判断する)
    private(set) var manualOverride = false

    let secrets: any SecretStoring = KeychainStore()
    private let detector = CameraDetector()
    private let snapshots = UserDefaultsSnapshotStore()
    private var coordinator: MeetingCoordinator?
    private var coordinatorTask: Task<Void, Never>?

    init() {
        config = AppConfig.load()
        restartCoordinator()
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

    /// メニューバーからの強制 ON AIR / 解除。
    func setManualOverride(_ enabled: Bool) {
        guard let coordinator else { return }
        manualOverride = enabled
        Task { await coordinator.setManualOverride(enabled) }
    }

    /// 設定が揃っていれば監視を開始し、揃っていなければ停止する。
    private func restartCoordinator() {
        coordinatorTask?.cancel()
        coordinatorTask = nil
        coordinator = nil
        manualOverride = false

        guard let lightID = config.lightID, let hue = hueClient else {
            phase = .unconfigured
            return
        }
        phase = .idle

        let coordinator = MeetingCoordinator(
            detector: detector,
            hue: hue,
            snapshots: snapshots,
            configuration: .init(
                lightID: lightID,
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
