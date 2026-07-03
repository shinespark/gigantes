import XCTest
@testable import Gigantes

final class MeetingStateMachineTests: XCTestCase {

    // MARK: - idle → onAir

    func testCameraOnSchedulesOnAirDebounce() {
        var machine = MeetingStateMachine()

        let effects = machine.handle(.rawActivityChanged(true))

        XCTAssertEqual(effects, [
            .cancelDebounce,
            .scheduleDebounce(token: 1, duration: MeetingStateMachine.onAirDebounce),
        ])
        XCTAssertEqual(machine.state, .idle, "デバウンス経過までは遷移しない")
    }

    func testDebounceFiredTransitionsToOnAirAndCapturesSnapshotFirst() {
        var machine = MeetingStateMachine()
        _ = machine.handle(.rawActivityChanged(true))

        let effects = machine.handle(.debounceFired(token: 1))

        XCTAssertEqual(effects, [.captureSnapshotThenSetOnAir])
        XCTAssertEqual(machine.state, .onAir)
    }

    // MARK: - フラップ抑制

    func testFlapWithinDebounceDoesNotTransition() {
        var machine = MeetingStateMachine()
        _ = machine.handle(.rawActivityChanged(true))

        // デバウンス中にカメラが OFF に戻る
        let cancelEffects = machine.handle(.rawActivityChanged(false))
        XCTAssertEqual(cancelEffects, [.cancelDebounce])

        // 取り消し済みタイマーが遅れて発火しても無視される
        let staleEffects = machine.handle(.debounceFired(token: 1))
        XCTAssertEqual(staleEffects, [])
        XCTAssertEqual(machine.state, .idle)
    }

    func testRapidFlappingSupersedesOldTimer() {
        var machine = MeetingStateMachine()
        _ = machine.handle(.rawActivityChanged(true))   // token 1
        _ = machine.handle(.rawActivityChanged(false))  // cancel
        let effects = machine.handle(.rawActivityChanged(true))  // token 2

        XCTAssertEqual(effects, [
            .cancelDebounce,
            .scheduleDebounce(token: 2, duration: MeetingStateMachine.onAirDebounce),
        ])

        // 古い token の発火は無視、新しい token で遷移
        XCTAssertEqual(machine.handle(.debounceFired(token: 1)), [])
        XCTAssertEqual(machine.handle(.debounceFired(token: 2)), [.captureSnapshotThenSetOnAir])
        XCTAssertEqual(machine.state, .onAir)
    }

    func testDuplicateRawEventDoesNotRescheduleDebounce() {
        var machine = MeetingStateMachine()
        _ = machine.handle(.rawActivityChanged(true))

        let effects = machine.handle(.rawActivityChanged(true))

        XCTAssertEqual(effects, [], "同じ遷移が進行中なら再スケジュールしない")
    }

    // MARK: - onAir → idle

    func testCameraOffSchedulesIdleDebounceThenRestores() {
        var machine = MeetingStateMachine()
        _ = machine.handle(.rawActivityChanged(true))
        _ = machine.handle(.debounceFired(token: 1))

        let scheduleEffects = machine.handle(.rawActivityChanged(false))
        XCTAssertEqual(scheduleEffects, [
            .cancelDebounce,
            .scheduleDebounce(token: 2, duration: MeetingStateMachine.idleDebounce),
        ])

        let effects = machine.handle(.debounceFired(token: 2))
        XCTAssertEqual(effects, [.restoreSnapshot])
        XCTAssertEqual(machine.state, .idle)
    }

    func testOnAirFlapDoesNotReSnapshot() {
        var machine = MeetingStateMachine()
        _ = machine.handle(.rawActivityChanged(true))
        _ = machine.handle(.debounceFired(token: 1))

        // onAir 中にカメラが一瞬 OFF → ON(Zoom の画面切替等)
        _ = machine.handle(.rawActivityChanged(false))
        let effects = machine.handle(.rawActivityChanged(true))

        XCTAssertEqual(effects, [.cancelDebounce], "onAir に戻るだけでスナップショットを取り直さない")
        XCTAssertEqual(machine.state, .onAir)
    }

    // MARK: - 起動時リカバリ

    func testInitialStateOnAirSupportsCrashRecovery() {
        var machine = MeetingStateMachine(initialState: .onAir)

        // カメラ ON のままなら何も起きない
        XCTAssertEqual(machine.handle(.rawActivityChanged(true)), [])
        XCTAssertEqual(machine.state, .onAir)

        // カメラ OFF でデバウンス後に復元
        _ = machine.handle(.rawActivityChanged(false))
        XCTAssertEqual(machine.handle(.debounceFired(token: 1)), [.restoreSnapshot])
        XCTAssertEqual(machine.state, .idle)
    }
}
