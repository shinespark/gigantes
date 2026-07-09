import AppKit
import Foundation

/// アプリの表示言語。
///
/// アプリ単位の AppleLanguages(UserDefaults)を書き換え、再起動で反映する。
/// AppleLanguages はグローバルドメインの値も検索されて「システム設定のまま」と
/// 区別できないため、明示的な選択は専用キーに別途保存する。
enum AppLanguage: String, CaseIterable {
    case system
    case english = "en"
    case japanese = "ja"

    private static let preferenceKey = "AppLanguage"

    static var current: AppLanguage {
        UserDefaults.standard.string(forKey: preferenceKey)
            .flatMap(AppLanguage.init) ?? .system
    }

    func apply() {
        let defaults = UserDefaults.standard
        if self == .system {
            defaults.removeObject(forKey: Self.preferenceKey)
            defaults.removeObject(forKey: "AppleLanguages")
        } else {
            defaults.set(rawValue, forKey: Self.preferenceKey)
            defaults.set([rawValue], forKey: "AppleLanguages")
        }
    }

    /// 言語変更を反映するためにアプリを再起動する。
    /// 子プロセスは親の終了後 launchd に引き継がれるため、terminate 後も open が実行される。
    static func relaunchApp() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 0.5; /usr/bin/open -n \"\(Bundle.main.bundlePath)\""]
        try? process.run()
        NSApp.terminate(nil)
    }
}
