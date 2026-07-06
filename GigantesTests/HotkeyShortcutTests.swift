import AppKit
import Carbon.HIToolbox
import XCTest
@testable import Gigantes

final class HotkeyShortcutTests: XCTestCase {

    // MARK: - 修飾キー変換

    func testCarbonModifiersMapsEachFlag() {
        XCTAssertEqual(HotkeyShortcut.carbonModifiers(from: .command), UInt32(cmdKey))
        XCTAssertEqual(HotkeyShortcut.carbonModifiers(from: .option), UInt32(optionKey))
        XCTAssertEqual(HotkeyShortcut.carbonModifiers(from: .control), UInt32(controlKey))
        XCTAssertEqual(HotkeyShortcut.carbonModifiers(from: .shift), UInt32(shiftKey))
        XCTAssertEqual(
            HotkeyShortcut.carbonModifiers(from: [.command, .shift]),
            UInt32(cmdKey | shiftKey)
        )
    }

    func testCarbonModifiersIgnoresFunctionFlag() {
        // 矢印・F キーの keyDown では .function が勝手に立つ(Carbon に fn 修飾はない)
        XCTAssertEqual(
            HotkeyShortcut.carbonModifiers(from: [.command, .function]),
            UInt32(cmdKey)
        )
        XCTAssertEqual(HotkeyShortcut.carbonModifiers(from: .function), 0)
    }

    // MARK: - 表示

    func testDisplayStringUsesCanonicalModifierOrder() {
        let shortcut = HotkeyShortcut(
            keyCode: 31,
            carbonModifiers: UInt32(cmdKey | optionKey | controlKey | shiftKey),
            keyLabel: "O"
        )
        XCTAssertEqual(shortcut.displayString, "⌃⌥⇧⌘O")
    }

    func testDefaultShortcutIsCommandShiftG() {
        XCTAssertEqual(HotkeyShortcut.default.displayString, "⇧⌘G")
        XCTAssertTrue(HotkeyShortcut.default.hasRequiredModifier)
    }

    func testKeyLabelPrefersSpecialTableOverCharacters() {
        XCTAssertEqual(HotkeyShortcut.keyLabel(keyCode: 53, characters: "\u{1B}"), "⎋")
        XCTAssertEqual(HotkeyShortcut.keyLabel(keyCode: 123, characters: nil), "←")
        XCTAssertEqual(HotkeyShortcut.keyLabel(keyCode: 96, characters: nil), "F5")
        XCTAssertEqual(HotkeyShortcut.keyLabel(keyCode: 5, characters: "g"), "G")
        XCTAssertEqual(HotkeyShortcut.keyLabel(keyCode: 200, characters: nil), "Key 200")
    }

    // MARK: - 必須修飾キー

    func testHasRequiredModifierNeedsCommandOrControl() {
        XCTAssertTrue(HotkeyShortcut(keyCode: 5, carbonModifiers: UInt32(cmdKey), keyLabel: "G").hasRequiredModifier)
        XCTAssertTrue(HotkeyShortcut(keyCode: 5, carbonModifiers: UInt32(controlKey), keyLabel: "G").hasRequiredModifier)
        XCTAssertFalse(HotkeyShortcut(keyCode: 5, carbonModifiers: UInt32(optionKey | shiftKey), keyLabel: "G").hasRequiredModifier)
        XCTAssertFalse(HotkeyShortcut(keyCode: 5, carbonModifiers: 0, keyLabel: "G").hasRequiredModifier)
    }
}

final class AppConfigCodableTests: XCTestCase {

    func testLegacyConfigWithoutHotkeyKeyGetsDefaultAndKeepsBridgeSettings() throws {
        // v0.2 以前の保存形式(hotkey キーなし)
        let legacyJSON = Data("""
        {
            "bridgeIP": "192.0.2.1",
            "bridgeID": "0123456789abcdef",
            "lightID": "light-uuid",
            "lightName": "Desk lamp",
            "onAirColor": {"red": 1, "green": 0, "blue": 0},
            "onAirBrightness": 80
        }
        """.utf8)

        let config = try JSONDecoder().decode(AppConfig.self, from: legacyJSON)

        XCTAssertEqual(config.bridgeIP, "192.0.2.1")
        XCTAssertEqual(config.lightID, "light-uuid")
        XCTAssertEqual(config.onAirBrightness, 80)
        XCTAssertEqual(config.hotkey, .default, "旧設定にはデフォルトショートカットを適用する")
    }

    func testClearedHotkeySurvivesRoundTrip() throws {
        var config = AppConfig()
        config.hotkey = nil

        let decoded = try JSONDecoder().decode(
            AppConfig.self,
            from: JSONEncoder().encode(config)
        )

        XCTAssertNil(decoded.hotkey, "明示的な解除はデフォルトに戻らず nil のまま保持される")
    }

    func testCustomHotkeySurvivesRoundTrip() throws {
        var config = AppConfig()
        config.hotkey = HotkeyShortcut(keyCode: 31, carbonModifiers: UInt32(cmdKey | controlKey), keyLabel: "O")

        let decoded = try JSONDecoder().decode(
            AppConfig.self,
            from: JSONEncoder().encode(config)
        )

        XCTAssertEqual(decoded, config)
    }
}
