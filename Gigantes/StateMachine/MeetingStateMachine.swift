import Foundation

/// idle ⇄ onAir の遷移とデバウンスを担う純粋な状態機械。
///
/// 副作用は一切持たず、イベントを受けて実行すべき `Effect` の列を返す。
/// タイマーや Hue API の実行は `MeetingCoordinator` が担う。
struct MeetingStateMachine {
    enum State: Equatable {
        case idle
        case onAir
    }

    enum Event: Equatable {
        /// カメラ使用状態の生の変化(デバウンス前)
        case rawActivityChanged(Bool)
        /// スケジュールしたデバウンスタイマーの発火
        case debounceFired(token: Int)
    }

    enum Effect: Equatable {
        /// 指定時間後に `debounceFired(token:)` を届けるタイマーを開始する
        case scheduleDebounce(token: Int, duration: Duration)
        /// 進行中のデバウンスタイマーを取り消す
        case cancelDebounce
        /// ランプの現在状態をスナップショット保存してから ON AIR 色に変更する
        case captureSnapshotThenSetOnAir
        /// スナップショットをランプへ書き戻し、成功したら破棄する
        case restoreSnapshot
    }

    /// Zoom のプレビュー等での ON/OFF フラップを吸収する安定待ち時間
    static let onAirDebounce: Duration = .seconds(2)
    static let idleDebounce: Duration = .seconds(3)

    private(set) var state: State
    private var pendingTarget: State?
    private var pendingToken = 0

    init(initialState: State = .idle) {
        state = initialState
    }

    mutating func handle(_ event: Event) -> [Effect] {
        switch event {
        case .rawActivityChanged(let active):
            let target: State = active ? .onAir : .idle

            if target == state {
                // 現在の状態に戻る変化。進行中の遷移があれば取り消すだけでよい
                guard pendingTarget != nil else { return [] }
                pendingTarget = nil
                return [.cancelDebounce]
            }
            if pendingTarget == target {
                // 同じ遷移がすでにスケジュール済み
                return []
            }

            pendingToken += 1
            pendingTarget = target
            let duration = target == .onAir ? Self.onAirDebounce : Self.idleDebounce
            return [.cancelDebounce, .scheduleDebounce(token: pendingToken, duration: duration)]

        case .debounceFired(let token):
            // 取り消し済み・古いタイマーの発火は無視する
            guard token == pendingToken, let target = pendingTarget else { return [] }
            pendingTarget = nil
            state = target
            return target == .onAir ? [.captureSnapshotThenSetOnAir] : [.restoreSnapshot]
        }
    }
}
