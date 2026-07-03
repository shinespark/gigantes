import Foundation

/// 会議開始前のランプ状態。会議終了時にこの状態へ復元する。
struct LightSnapshot: Codable, Equatable {
    let lightID: String
    let isOn: Bool
    let colorXY: CIEXYColor?
    let brightness: Double?
    let capturedAt: Date
}

/// スナップショットの永続化。
///
/// クラッシュ・再起動後に「復元し損ねたスナップショット」を検出できるよう
/// UserDefaults に保存する(秘密情報は含まない)。
protocol SnapshotStoring: Sendable {
    func load() -> LightSnapshot?
    func save(_ snapshot: LightSnapshot)
    func clear()
}

struct UserDefaultsSnapshotStore: SnapshotStoring {
    private static let key = "lightSnapshot"

    func load() -> LightSnapshot? {
        guard let data = UserDefaults.standard.data(forKey: Self.key) else { return nil }
        return try? JSONDecoder().decode(LightSnapshot.self, from: data)
    }

    func save(_ snapshot: LightSnapshot) {
        UserDefaults.standard.set(try? JSONEncoder().encode(snapshot), forKey: Self.key)
    }

    func clear() {
        UserDefaults.standard.removeObject(forKey: Self.key)
    }
}
