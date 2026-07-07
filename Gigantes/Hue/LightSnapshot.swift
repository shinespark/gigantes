import Foundation

/// 会議開始前のランプ状態。会議終了時にこの状態へ復元する。
/// `colorXY` と `mirek`(色温度)は排他で、どちらか一方のみ値を持つ。
struct LightSnapshot: Codable, Equatable {
    let lightID: String
    let isOn: Bool
    let colorXY: CIEXYColor?
    let brightness: Double?
    var mirek: Int?
    let capturedAt: Date
}

/// スナップショットの永続化(対象ランプごとに 1 件)。
///
/// クラッシュ・再起動後に「復元し損ねたスナップショット」を検出できるよう
/// UserDefaults に保存する(秘密情報は含まない)。
protocol SnapshotStoring: Sendable {
    func load() -> [LightSnapshot]
    func save(_ snapshots: [LightSnapshot])
    func clear()
}

struct UserDefaultsSnapshotStore: SnapshotStoring {
    private static let key = "lightSnapshot"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> [LightSnapshot] {
        guard let data = defaults.data(forKey: Self.key) else { return [] }
        return (try? JSONDecoder().decode([LightSnapshot].self, from: data)) ?? []
    }

    func save(_ snapshots: [LightSnapshot]) {
        defaults.set(try? JSONEncoder().encode(snapshots), forKey: Self.key)
    }

    func clear() {
        defaults.removeObject(forKey: Self.key)
    }
}
