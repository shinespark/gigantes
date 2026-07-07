import Foundation

/// ランプに書き込む(または読み取った)設定値。nil のフィールドは変更しない。
/// `color`(xy)と `mirek`(色温度)は排他で、どちらか一方のみ値を持つ。
struct LightSettings: Equatable, Sendable {
    var isOn: Bool?
    var color: CIEXYColor?
    var brightness: Double?
    var mirek: Int?
}

/// Hue ランプ操作の抽象化。実装は CLIP v2 の `HueClient`。
protocol HueControlling: Sendable {
    func listLights() async throws -> [HueLight]
    func currentSettings(lightID: String) async throws -> LightSettings
    func apply(_ settings: LightSettings, to lightID: String) async throws
    /// シーンの recall が変更するランプの ID 一覧(適用直前に毎回取得する)
    func sceneLightIDs(sceneID: String) async throws -> [String]
    func recallScene(sceneID: String) async throws
}
