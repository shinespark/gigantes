import AppKit
import Carbon.HIToolbox

/// グローバルホットキーのキーコンボ。
///
/// SwiftUI.KeyboardShortcut と名前が衝突しないよう HotkeyShortcut とする。
/// `keyLabel` は録画時のキーボードレイアウトで確定した表示名を保持する
/// (後からレイアウトが変わっても表示が古くなるだけで動作には影響しない)。
struct HotkeyShortcut: Codable, Equatable {
    var keyCode: UInt16
    var carbonModifiers: UInt32
    var keyLabel: String

    /// デフォルトは ⌘⇧H
    static let `default` = HotkeyShortcut(
        keyCode: UInt16(kVK_ANSI_H),
        carbonModifiers: UInt32(cmdKey | shiftKey),
        keyLabel: "H"
    )

    /// macOS 標準の表記順(⌃⌥⇧⌘)で表示する。
    var displayString: String {
        var symbols = ""
        if carbonModifiers & UInt32(controlKey) != 0 { symbols += "⌃" }
        if carbonModifiers & UInt32(optionKey) != 0 { symbols += "⌥" }
        if carbonModifiers & UInt32(shiftKey) != 0 { symbols += "⇧" }
        if carbonModifiers & UInt32(cmdKey) != 0 { symbols += "⌘" }
        return symbols + keyLabel
    }

    /// ⌘ か ⌃ を含むか。macOS 15+ では ⇧/⌥ のみの修飾は登録エラーになるため必須。
    var hasRequiredModifier: Bool {
        carbonModifiers & UInt32(cmdKey | controlKey) != 0
    }

    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        // 矢印・F キーで勝手に立つ .function 等を落とす(Carbon に fn 修飾はない)
        let masked = flags.intersection([.command, .option, .control, .shift])
        var carbon: UInt32 = 0
        if masked.contains(.command) { carbon |= UInt32(cmdKey) }
        if masked.contains(.option) { carbon |= UInt32(optionKey) }
        if masked.contains(.control) { carbon |= UInt32(controlKey) }
        if masked.contains(.shift) { carbon |= UInt32(shiftKey) }
        return carbon
    }

    static func keyLabel(keyCode: UInt16, characters: String?) -> String {
        if let special = specialKeyLabels[keyCode] {
            return special
        }
        if let characters, !characters.isEmpty {
            return characters.uppercased()
        }
        return "Key \(keyCode)"
    }

    /// 印字されない(または charactersIgnoringModifiers が不適切な)キーの表示名。
    private static let specialKeyLabels: [UInt16: String] = [
        36: "⏎", 48: "⇥", 49: "␣", 51: "⌫", 53: "⎋", 76: "⌤",
        115: "↖", 117: "⌦", 119: "↘", 116: "⇞", 121: "⇟",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]
}
