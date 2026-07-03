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

/// UserDefaults に永続化するユーザー設定。
struct AppConfig: Codable, Equatable {
    var bridgeIP: String?
    var bridgeID: String?
    var lightID: String?
    var lightName: String?
    var onAirColor: CIEXYColor = .red
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

    init() {
        config = AppConfig.load()
        restartCoordinator()
    }

    /// 設定が揃っていれば監視を開始し、揃っていなければ停止する。
    /// 実際の Coordinator 結線は Phase 5 で実装する。
    private func restartCoordinator() {
        phase = config.isComplete ? .idle : .unconfigured
    }
}
