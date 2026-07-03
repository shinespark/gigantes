import Foundation

/// ランプに書き込む(または読み取った)設定値。nil のフィールドは変更しない。
struct LightSettings: Equatable, Sendable {
    var isOn: Bool?
    var color: CIEXYColor?
    var brightness: Double?
}

/// Hue ランプ操作の抽象化。実装は CLIP v2 の `HueClient`(Phase 4)。
protocol HueControlling: Sendable {
    func currentSettings(lightID: String) async throws -> LightSettings
    func apply(_ settings: LightSettings, to lightID: String) async throws
}
