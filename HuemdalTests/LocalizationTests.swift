import XCTest
@testable import Huemdal

final class LocalizationTests: XCTestCase {

    /// リポジトリの Huemdal/ ソースディレクトリ(#filePath から辿る)。
    private static let sourceRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // HuemdalTests/
        .deletingLastPathComponent()  // リポジトリルート
        .appendingPathComponent("Huemdal")

    // MARK: - 翻訳の解決

    func testJapaneseLocalizationResolves() throws {
        let jaPath = try XCTUnwrap(
            Bundle.main.path(forResource: "ja", ofType: "lproj"),
            "ja.lproj がアプリバンドルに含まれていない"
        )
        let ja = try XCTUnwrap(Bundle(path: jaPath))
        let value = ja.localizedString(forKey: "Launch at login", value: "MISSING", table: nil)
        XCTAssertNotEqual(value, "MISSING")
        XCTAssertNotEqual(value, "Launch at login", "日本語訳が英語のまま")
    }

    // MARK: - キー網羅(String Catalog は手書き管理のため、入れ忘れをここで検出する)

    /// ソース中のローカライズ対象リテラルがすべて Localizable.xcstrings に
    /// 日本語訳付き(state == "translated")で登録されていることを検証する。
    func testAllSourceStringsHaveJapaneseTranslation() throws {
        let catalogKeys = try japaneseTranslatedKeys()
        let sourceKeys = try localizableLiteralsInSources()

        XCTAssertFalse(sourceKeys.isEmpty, "ソースからリテラルを抽出できていない")
        let missing = sourceKeys.subtracting(catalogKeys).sorted()
        XCTAssertTrue(
            missing.isEmpty,
            "Localizable.xcstrings に日本語訳がないキー: \(missing)"
        )
    }

    private func japaneseTranslatedKeys() throws -> Set<String> {
        let url = Self.sourceRoot.appendingPathComponent("Resources/Localizable.xcstrings")
        let data = try Data(contentsOf: url)
        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let strings = try XCTUnwrap(json["strings"] as? [String: Any])

        var keys = Set<String>()
        for (key, entry) in strings {
            guard let entry = entry as? [String: Any],
                  let localizations = entry["localizations"] as? [String: Any],
                  let ja = localizations["ja"] as? [String: Any],
                  let unit = ja["stringUnit"] as? [String: Any],
                  unit["state"] as? String == "translated"
            else { continue }
            keys.insert(key)
        }
        return keys
    }

    /// SwiftUI ビュー / String(localized:) の文字列リテラルをソースから抽出する。
    /// interpolation(\( )を含むものは verbatim 扱いのため対象外。
    private func localizableLiteralsInSources() throws -> Set<String> {
        let patterns = [
            #"(?:Text|Button|Section|Toggle|Picker|LabeledContent|ColorPicker)\("((?:[^"\\]|\\[^(])+)""#,
            #"String\(localized: "((?:[^"\\]|\\[^(])+)""#,
        ]
        // stepRow(1, "...") や三項演算子の "..." : "..." など、引数位置のリテラル。
        // API パス等を誤検出しないよう UI/ 配下のみに適用する(verbatim: は対象外)
        let uiOnlyPattern = #"(?:\?|,|(?<!verbatim):)\s*"((?:[^"\\]|\\[^(])+)"\s*(?::|\)|,)"#
        let regexes = try patterns.map { try NSRegularExpression(pattern: $0) }
        let uiOnlyRegex = try NSRegularExpression(pattern: uiOnlyPattern)

        var keys = Set<String>()
        let enumerator = try XCTUnwrap(
            FileManager.default.enumerator(at: Self.sourceRoot, includingPropertiesForKeys: nil)
        )
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let source = try String(contentsOf: url, encoding: .utf8)
            let range = NSRange(source.startIndex..., in: source)
            var applicableRegexes = regexes
            if url.pathComponents.contains("UI") {
                applicableRegexes.append(uiOnlyRegex)
            }
            for regex in applicableRegexes {
                regex.enumerateMatches(in: source, range: range) { match, _, _ in
                    guard let match, let keyRange = Range(match.range(at: 1), in: source) else { return }
                    let key = String(source[keyRange])
                    // 記号のみ・SF Symbols 名などユーザー向け文言でないものを除外
                    guard key.rangeOfCharacter(from: .whitespaces) != nil || key.count > 3,
                          key.range(of: #"^[a-z0-9.]+$"#, options: .regularExpression) == nil
                    else { return }
                    keys.insert(key)
                }
            }
        }
        return keys
    }
}
