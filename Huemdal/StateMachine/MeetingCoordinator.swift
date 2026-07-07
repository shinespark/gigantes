import Foundation
import os

/// 検知ストリーム・デバウンスタイマー・Hue API 呼び出しを結線する actor。
///
/// 状態遷移の判断はすべて `MeetingStateMachine` に委譲し、
/// この actor は Effect の実行(タイマー、スナップショット、ライト操作)だけを行う。
actor MeetingCoordinator {
    struct Configuration: Sendable {
        enum ColorTarget: Sendable {
            case lights([String])
            /// Bridge 上の全ライト。ON AIR のたびに解決するため、後から追加したライトも含む
            case allLights
        }

        enum OnAirAction: Sendable {
            /// 対象ライトを単色に変更する
            case color(target: ColorTarget, color: CIEXYColor, brightness: Double)
            /// Hue シーンを適用する(対象ライトは適用直前にシーンから解決する)
            case scene(sceneID: String)
        }

        var onAirAction: OnAirAction
    }

    private static let logger = Logger(subsystem: "dev.shinespark.huemdal", category: "MeetingCoordinator")
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
        if !snapshots.load().isEmpty {
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
        switch configuration.onAirAction {
        case .color(let target, let color, let brightness):
            let lightIDs: [String]
            switch target {
            case .lights(let ids):
                lightIDs = ids
            case .allLights:
                // 解決できなければライトには一切触らない(シーンの対象解決と同じ方針)
                var resolvedIDs: [String] = []
                let resolved = await withRetry("resolve all lights") {
                    resolvedIDs = try await self.hue.listLights().map(\.id)
                }
                guard resolved else { return }
                lightIDs = resolvedIDs
            }

            let snapshotted = await captureSnapshots(for: lightIDs)

            let onAir = LightSettings(isOn: true, color: color, brightness: brightness)
            var anyApplied = false
            for lightID in lightIDs where snapshotted.contains(lightID) {
                let applied = await withRetry("set onAir color for light \(lightID)") {
                    try await self.hue.apply(onAir, to: lightID)
                }
                anyApplied = anyApplied || applied
            }
            if anyApplied {
                onPhaseChange(.onAir)
            }

        case .scene(let sceneID):
            // シーンは Hue アプリ側で編集され得るため、対象ライトは毎回解決する
            var lightIDs: [String] = []
            let resolved = await withRetry("resolve lights of scene \(sceneID)") {
                lightIDs = try await self.hue.sceneLightIDs(sceneID: sceneID)
            }
            // 解決できなければライトには一切触らない(復元できなくなるため)
            guard resolved else { return }

            let snapshotted = await captureSnapshots(for: lightIDs)
            // 1 件もスナップショットできていなければ recall しない
            guard lightIDs.isEmpty || lightIDs.contains(where: snapshotted.contains) else { return }

            let recalled = await withRetry("recall scene \(sceneID)") {
                try await self.hue.recallScene(sceneID: sceneID)
            }
            if recalled {
                onPhaseChange(.onAir)
            }
        }
    }

    /// 指定ライトの現在状態をスナップショットに追記し、ライトを変更する前に必ず永続化する。
    /// 既存のスナップショットは上書きしない(復元先を壊さない)。
    /// - Returns: スナップショットが存在する(以前から含む)ライト ID の集合。
    ///   取得に失敗したライトはここに含まれず、呼び出し側は ON AIR 対象から外す。
    private func captureSnapshots(for lightIDs: [String]) async -> Set<String> {
        var captured = snapshots.load()
        let alreadyCaptured = Set(captured.map(\.lightID))

        for lightID in lightIDs where !alreadyCaptured.contains(lightID) {
            _ = await withRetry("capture snapshot for light \(lightID)") {
                let current = try await self.hue.currentSettings(lightID: lightID)
                captured.append(LightSnapshot(
                    lightID: lightID,
                    isOn: current.isOn ?? true,
                    colorXY: current.color,
                    brightness: current.brightness,
                    mirek: current.mirek,
                    capturedAt: Date()
                ))
            }
        }

        snapshots.save(captured)
        return Set(captured.map(\.lightID))
    }

    private func restoreSnapshot() async {
        let all = snapshots.load()
        guard !all.isEmpty else {
            onPhaseChange(.idle)
            return
        }

        // 復元に失敗したライトのスナップショットだけを残し、次回の復元に備える
        var remaining: [LightSnapshot] = []
        for snapshot in all {
            let settings = LightSettings(
                isOn: snapshot.isOn,
                color: snapshot.colorXY,
                brightness: snapshot.brightness,
                mirek: snapshot.mirek
            )
            let restored = await withRetry("restore snapshot for light \(snapshot.lightID)") {
                try await self.hue.apply(settings, to: snapshot.lightID)
            }
            if !restored {
                remaining.append(snapshot)
            }
        }

        if remaining.isEmpty {
            snapshots.clear()
            onPhaseChange(.idle)
        } else {
            snapshots.save(remaining)
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
