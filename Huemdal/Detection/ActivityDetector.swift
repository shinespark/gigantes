import Foundation

/// カメラなどの検知対象がアクティブかどうかをイベント駆動で通知する。
///
/// ストリームは購読開始時に必ず現在値を 1 つ emit し、以降は変化のみ通知する。
protocol ActivityDetector: Sendable {
    var isActive: AsyncStream<Bool> { get }
}
