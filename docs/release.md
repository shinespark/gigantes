# リリース手順

`v*` のタグを push すると GitHub Actions([release.yml](../.github/workflows/release.yml))がビルド → 署名 → notarization → GitHub Release 作成まで自動で行う。

```sh
git tag v0.3.0
git push origin v0.3.0
```

- タグ名から `v` を除いたものが `MARKETING_VERSION`(CFBundleShortVersionString)になる
- 署名・notarization 用の Secrets が未設定の場合、そのステップはスキップされ **未署名の zip** が Release に添付される(初回起動は右クリック → 開く)

## 必要な GitHub Secrets

リポジトリの Settings → Secrets and variables → Actions に以下を登録する。

| Secret | 内容 |
|---|---|
| `MACOS_CERTIFICATE` | Developer ID Application 証明書(.p12)を base64 エンコードしたもの |
| `MACOS_CERTIFICATE_PWD` | .p12 のパスワード |
| `APPLE_ID` | Apple ID(メールアドレス) |
| `APPLE_TEAM_ID` | Team ID(developer.apple.com の Membership ページに記載) |
| `APPLE_APP_SPECIFIC_PASSWORD` | notarytool 用の App 用パスワード(appleid.apple.com で発行) |

### 証明書の用意

1. Xcode → Settings → Accounts → Manage Certificates → 「+」→ **Developer ID Application** を作成
2. Keychain Access で該当証明書(秘密鍵ごと)を選択 → 書き出し → .p12 形式(パスワードを設定)
3. base64 エンコードして Secret に登録:

   ```sh
   base64 -i certificate.p12 | gh secret set MACOS_CERTIFICATE
   gh secret set MACOS_CERTIFICATE_PWD  # プロンプトにパスワードを入力
   ```
