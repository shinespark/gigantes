import Foundation
import os

/// 検知ストリーム・デバウンスタイマー・Hue API 呼び出しを結線する actor。
///
/// 状態遷移の判断はすべて `MeetingStateMachine` に委譲し、
/// この actor は Effect の実行(タイマー、スナップショット、ランプ操作)だけを行う。
actor MeetingCoordinator {
    struct Configuration: Sendable {
        var lightID: String
        var onAirColor: CIEXYColor
        var onAirBrightness: Double
    }

    private static let logger = Logger(subsystem: "dev.shinespark.gigantes", category: "MeetingCoordinator")
    private static let maxRetryAttempts = 5

    private var machine = MeetingStateMachine()
    private let detector: any ActivityDetector
    private let hue: any HueControlling
    private let snapshots: any SnapshotStoring
    private let configuration: Configuration
    private let onPhaseChange: @Sendable (AppPhase) -> Void
    private var debounceTask: Task<Void, Never>?

    init(
        detector: any ActivityDetector,
        hue: any HueControlling,
        snapshots: any SnapshotStoring,
        configuration: Configuration,
        onPhaseChange: @escaping @Sendable (AppPhase) -> Void
    ) {
        self.detector = detector
        self.hue = hue
        self.snapshots = snapshots
        self.configuration = configuration
        self.onPhaseChange = onPhaseChange
    }

    /// 検知ストリームを購読し続ける。キャンセルされるまで戻らない。
    func run() async {
        var iterator = detector.isActive.makeAsyncIterator()
        guard let initiallyActive = await iterator.next() else { return }
        await start(initiallyActive: initiallyActive)

        while let active = await iterator.next() {
            guard !Task.isCancelled else { break }
            await handle(.rawActivityChanged(active))
        }
    }

    /// 起動時のリカバリ処理。
    ///
    /// 前回復元し損ねたスナップショットが残っている場合:
    /// - カメラ使用中なら会議継続中とみなし、復元せず onAir として再開する
    /// - 未使用なら即座に復元する
    private func start(initiallyActive: Bool) async {
        if snapshots.load() != nil {
            if initiallyActive {
                Self.logger.info("Leftover snapshot found while camera is active; resuming onAir")
                machine = MeetingStateMachine(initialState: .onAir)
                // オーバーライド解除時の判断に使う lastRawActivity を記録させる(遷移は起きない)
                _ = machine.handle(.rawActivityChanged(true))
                onPhaseChange(.onAir)
                return
            }
            Self.logger.info("Leftover snapshot found; restoring light state")
            await restoreSnapshot()
        }
        if initiallyActive {
            await handle(.rawActivityChanged(true))
        }
    }

    /// メニューバーからの強制 ON AIR / 解除。
    func setManualOverride(_ enabled: Bool) async {
        await handle(.manualOverrideChanged(enabled))
    }

    private func handle(_ event: MeetingStateMachine.Event) async {
        for effect in machine.handle(event) {
            await perform(effect)
        }
    }

    private func perform(_ effect: MeetingStateMachine.Effect) async {
        switch effect {
        case .cancelDebounce:
            debounceTask?.cancel()
            debounceTask = nil

        case .scheduleDebounce(let token, let duration):
            debounceTask = Task {
                do {
                    try await Task.sleep(for: duration)
                } catch {
                    return
                }
                await self.handle(.debounceFired(token: token))
            }

        case .captureSnapshotThenSetOnAir:
            await captureSnapshotThenSetOnAir()

        case .restoreSnapshot:
            await restoreSnapshot()
        }
    }

    private func captureSnapshotThenSetOnAir() async {
        let lightID = configuration.lightID

        // スナップショットが残っている場合は上書きしない(復元先を壊さない)
        if snapshots.load() == nil {
            let captured = await withRetry("capture snapshot") {
                let current = try await self.hue.currentSettings(lightID: lightID)
                self.snapshots.save(LightSnapshot(
                    lightID: lightID,
                    isOn: current.isOn ?? true,
                    colorXY: current.color,
                    brightness: current.brightness,
                    capturedAt: Date()
                ))
            }
            guard captured else { return }
        }

        let onAir = LightSettings(
            isOn: true,
            color: configuration.onAirColor,
            brightness: configuration.onAirBrightness
        )
        let applied = await withRetry("set onAir color") {
            try await self.hue.apply(onAir, to: lightID)
        }
        if applied {
            onPhaseChange(.onAir)
        }
    }

    private func restoreSnapshot() async {
        guard let snapshot = snapshots.load() else {
            onPhaseChange(.idle)
            return
        }
        let settings = LightSettings(
            isOn: snapshot.isOn,
            color: snapshot.colorXY,
            brightness: snapshot.brightness
        )
        let restored = await withRetry("restore snapshot") {
            try await self.hue.apply(settings, to: snapshot.lightID)
        }
        if restored {
            snapshots.clear()
            onPhaseChange(.idle)
        }
    }

    /// 指数バックオフ付きリトライ。全滅した場合はエラーを phase に反映して false を返す。
    private func withRetry(_ label: String, operation: () async throws -> Void) async -> Bool {
        var delay: Duration = .milliseconds(500)
        for attempt in 1...Self.maxRetryAttempts {
            do {
                try await operation()
                return true
            } catch {
                Self.logger.error("\(label) failed (attempt \(attempt)): \(error)")
                if attempt == Self.maxRetryAttempts {
                    onPhaseChange(.error(String(localized: "Hue Bridge unreachable")))
                    return false
                }
                try? await Task.sleep(for: delay)
                delay *= 2
            }
        }
        return false
    }
}
