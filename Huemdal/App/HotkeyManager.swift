import Carbon.HIToolbox
import Foundation
import os

/// Carbon `RegisterEventHotKey` によるグローバルホットキーの登録・解除。
///
/// この方式は登録したコンボだけがアプリに届くため、
/// アクセシビリティや入力監視の権限を必要としない。
@MainActor
final class HotkeyManager {
    struct RegistrationError: Error {
        let status: OSStatus
    }

    private static let logger = Logger(subsystem: "dev.shinespark.huemdal", category: "HotkeyManager")

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var onPress: (() -> Void)?
    private var isPressed = false

    /// 単一ホットキーの登録。既存の登録があれば置き換える。
    func register(_ shortcut: HotkeyShortcut, onPress: @escaping () -> Void) throws {
        unregister()
        try installEventHandlerIfNeeded()

        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: 1)
        let status = RegisterEventHotKey(
            UInt32(shortcut.keyCode),
            shortcut.carbonModifiers,
            hotKeyID,
            GetEventDispatcherTarget(),
            0,
            &ref
        )
        guard status == noErr, let ref else {
            throw RegistrationError(status: status)
        }
        hotKeyRef = ref
        self.onPress = onPress
        Self.logger.info("Registered global hotkey: \(shortcut.displayString)")
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        hotKeyRef = nil
        onPress = nil
        isPressed = false
    }

    // "GGNT"
    private static let signature: OSType = {
        var result: OSType = 0
        for byte in "GGNT".utf8 {
            result = (result << 8) | OSType(byte)
        }
        return result
    }()

    private func installEventHandlerIfNeeded() throws {
        guard eventHandlerRef == nil else { return }

        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        let status = InstallEventHandler(
            GetEventDispatcherTarget(),
            { _, event, userData in
                guard let event, let userData else { return noErr }
                let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
                let kind = GetEventKind(event)
                // イベントディスパッチャターゲットのハンドラはメインスレッドで呼ばれる
                MainActor.assumeIsolated {
                    manager.handleHotKeyEvent(kind: kind)
                }
                return noErr
            },
            eventTypes.count,
            &eventTypes,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandlerRef
        )
        guard status == noErr else {
            throw RegistrationError(status: status)
        }
    }

    private func handleHotKeyEvent(kind: UInt32) {
        switch kind {
        case UInt32(kEventHotKeyPressed):
            // キーリピートによる二重トグルを防ぐ(押しっぱなしで 1 回だけ)
            guard !isPressed else { return }
            isPressed = true
            Self.logger.info("Global hotkey pressed")
            onPress?()
        case UInt32(kEventHotKeyReleased):
            isPressed = false
        default:
            break
        }
    }
}
