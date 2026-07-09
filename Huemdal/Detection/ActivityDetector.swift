import Foundation

/// カメラなどの検知対象がアクティブかどうかをイベント駆動で通知する。
///
/// ストリームは購読開始時に必ず現在値を 1 つ emit し、以降は変化のみ通知する。
protocol ActivityDetector: Sendable {
    var isActive: AsyncStream<Bool> { get }
}

/// カメラ自動検知が OFF のときに使う、常に非アクティブな検知器。
/// 契約どおり現在値(false)を 1 回 emit して終了する。
/// coordinator の run() は初期処理(残留スナップショットの復元)だけ行って戻り、
/// 手動オーバーライドのイベント処理は actor として引き続き受け付ける。
struct DisabledActivityDetector: ActivityDetector {
    var isActive: AsyncStream<Bool> {
        AsyncStream { continuation in
            continuation.yield(false)
            continuation.finish()
        }
    }
}
