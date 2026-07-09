# Huemdall 設計ドキュメント

macOS のカメラ使用状態を検知し、Philips Hue ライトの色を変更することで「オンラインミーティング中」であることを家族に知らせるメニューバー常駐アプリ。

- リポジトリ名: `huemdall`
- 最低ターゲット: **macOS 14 (Sonoma)+**
- 言語 / UI: Swift / SwiftUI (`MenuBarExtra`)
- プロジェクト管理: XcodeGen(`project.yml` をコミットし、`.xcodeproj` は生成物として管理しない)
- 配布: GitHub で OSS として公開

---

## 1. 要件

### 1.1 機能要件(v1)

- Mac のカメラ(内蔵・外付けを問わず)がいずれかのプロセスで使用開始されたことを検知する
- 検知したら、指定した Hue ライトを「ON AIR 色」(例: 赤)に変更する
- カメラ使用が終了したら、ライトを**会議開始前の状態に復元**する(on/off・色・輝度)
- メニューバーから現在の状態(ON AIR / 待機中)を確認できる
- 設定画面で以下を構成できる
  - Hue Bridge の発見・ペアリング(リンクボタン方式)
  - 対象ライトの選択
  - ON AIR 時の色・輝度

### 1.2 非機能要件

- クラウドを経由せず、LAN 内で完結する(Hue Bridge ローカル API 使用)
- カメラ映像・音声には一切アクセスしない(使用状態フラグのみ監視)
- application key などの秘密情報は Keychain に保存する
- 検知はイベント駆動とし、ポーリングによる常時 CPU 消費を避ける

### 1.3 将来拡張(v2 以降)

- 複数ライト / Hue シーンへの対応(実装済み)
- 手動オーバーライド(メニューバーから強制 ON AIR / 解除。グローバルショートカット含め実装済み)
- マイク使用状態の検知は誤検知リスク(常時マイクを掴むアプリ等)を考慮し、**対応しない**方針とした

---

## 2. 全体アーキテクチャ

```
┌───────────────────────────────────────────┐
│  MenuBarExtra (SwiftUI)                   │
│  ・状態アイコン表示 (idle / onAir)          │
│  ・設定画面 (オンボーディング含む)           │
├───────────────────────────────────────────┤
│  MeetingStateMachine                      │
│  ・idle ⇄ onAir の状態遷移                 │
│  ・デバウンス処理                           │
│  ・スナップショット取得/復元のオーケストレーション │
├─────────────────────┬─────────────────────┤
│  ActivityDetector    │  HueClient          │
│  (protocol)          │  ・CLIP API v2      │
│   └ CameraDetector   │  ・Bridge 発見       │
│   └ (MicDetector)    │  ・StateSnapshot    │
│   └ (Composite)      │  ・Keychain 連携     │
└─────────────────────┴─────────────────────┘
```

レイヤー間は protocol で疎結合にし、検知手段の追加(マイク等)や Hue 以外の出力先(将来的な拡張)に備える。

---

## 3. カメラ検知層

### 3.1 検知方式

CoreMediaIO のデバイスプロパティ `kCMIODevicePropertyDeviceIsRunningSomewhere` を監視する。

- 「いずれかのプロセスがこのデバイスを使用中か」が `Bool` で取得できる
- `CMIOObjectAddPropertyListenerBlock` でリスナー登録し、イベント駆動で変化を受け取る(ポーリング不要)。ブロック版は DispatchQueue 指定のため run loop は不要
- リスナーは**変化のみ**通知するため、起動時とデバイス増減時には初期値を明示的に読み取る
- カメラ映像には触れないため、**カメラ利用許可(TCC)のダイアログは発生しない**
- Zoom / Google Meet / Teams / FaceTime など、アプリケーション非依存で検知できる

### 3.2 対象デバイスの扱い

- 特定デバイスに固定せず、**システム上の全ビデオデバイスを列挙し「いずれかが running」で ON 判定**とする(外付け Web カメラ対応)
- デバイスの接続・切断(`kCMIOHardwarePropertyDevices` の変化)も監視し、リスナーを張り直す
- リスナーブロックの削除には既知の不具合報告(FB13398940)があるため、ハードウェアレベルのリスナーはアプリ生存中保持し、hot-plug 時は再列挙・再読取で対応する

### 3.3 抽象化インターフェース

```swift
protocol ActivityDetector {
    /// true = 検知対象がアクティブ(カメラ使用中など)
    var isActive: AsyncStream<Bool> { get }
}
```

- v1 実装: `CameraDetector`
- v2 で `MicDetector`(CoreAudio `kAudioDevicePropertyDeviceIsRunningSomewhere`)を追加し、複数 detector の OR を取る `CompositeDetector` を挟む設計とする

---

## 4. 状態機械とデバウンス

### 4.1 状態遷移

```
                 camera ON (デバウンス経過)
        ┌──────────────────────────────────┐
        │                                  ▼
   ┌────────┐                         ┌────────┐
   │  idle  │                         │ onAir  │
   └────────┘                         └────────┘
        ▲                                  │
        └──────────────────────────────────┘
                 camera OFF (デバウンス経過)
```

### 4.2 デバウンスの必要性

Zoom のプレビュー画面などでカメラが短時間に ON/OFF を繰り返すケースがある。デバウンスなしだと以下の事故が起きる:

- ライトがチカチカと点滅する
- **ON AIR 色に変更済みの状態を「会議前の状態」としてスナップショットしてしまい、復元先が壊れる**

対策として、状態変化から **2〜3 秒の安定待ち**を入れてから遷移を確定する。デバウンス時間は定数として切り出し、必要なら設定項目化する。

### 4.3 遷移時のアクション

| 遷移 | アクション |
|---|---|
| idle → onAir | ① 対象ライトの現在状態を GET しスナップショット保存 → ② ON AIR 色に変更 |
| onAir → idle | スナップショットの状態をライトに書き戻し → スナップショット破棄 |

スナップショット取得(①)は**必ず色変更(②)より先**に行う。

---

## 5. Hue 連携層

### 5.1 API

**CLIP API v2** を使用する(v1 は非推奨方向のため新規実装では採用しない)。

- エンドポイント例: `PUT https://<bridge-ip>/clip/v2/resource/light/<id>`
- 認証: `hue-application-key` ヘッダ
- 色指定: CIE xy 色空間 + brightness
- ペイロードはネスト形式: `"on": {"on": true}` / `"dimming": {"brightness": 0–100}` / `"color": {"xy": {"x": …, "y": …}}`(v1 の `"xy": [x, y]` 配列形式とは異なる)
- v2 の light ID は UUID。表示名は `light.metadata.name` を使い、空の場合は owner の `device` リソースから取得する

### 5.2 Bridge 発見とペアリング

1. **発見**: mDNS(`_hue._tcp.local`)を第一候補、失敗時は `https://discovery.meethue.com` にフォールバック
   - mDNS の TXT レコードから `bridgeid` が取得できるため優先する
   - `discovery.meethue.com` はレート制限(~1 リクエスト/15 分)があるため、手動探索時に 1 回だけ呼ぶ
2. **ペアリング**: ユーザーにブリッジのリンクボタンを押してもらい、`POST /api` で application key を取得
   - body: `{"devicetype": "Huemdall#<hostname>", "generateclientkey": true}`
   - ボタン未押下時は `error type 101` が返るため、UI は 1〜2 秒間隔で最大 30 秒程度ポーリングする
   - レスポンスの `username` が `hue-application-key` ヘッダの値。`clientkey` は Entertainment API 用で v1 スコープでは未使用
3. 取得した key(`username`)は **Keychain** に保存(UserDefaults に平文で置かない)

### 5.3 TLS の扱い

Bridge の証明書は自己署名のため、素朴に検証すると失敗する。公開物として以下の方針をとる:

- Signify(Philips Hue)の**ルート CA 証明書をアプリにバンドル**し、`SecTrustSetAnchorCertificates` + anchors-only でそれをアンカーとして検証する
- IP 直指定で接続するためホスト名検証は通らない。代わりに **leaf 証明書の CN == 小文字の Bridge ID** を照合する(Bridge ID は mDNS TXT の `bridgeid` または未認証の `/api/0/config` から取得)
- 未更新の古いブリッジは自己署名証明書(subject == issuer)のままでルート CA 検証に失敗する。この場合も検証は緩めず「ブリッジのファームウェアを更新してください」というエラーを表示する
- `URLSession` delegate で検証を無効化するだけの実装は**採用しない**

### 5.4 状態スナップショット

```swift
struct LightSnapshot: Codable {
    let lightId: String
    let isOn: Bool
    let colorXY: CIEXYColor?
    let brightness: Double?
    let capturedAt: Date
}
```

- 取得したスナップショットは **UserDefaults に永続化**する
- 目的: 会議中にアプリがクラッシュ / 再起動した場合、起動時に「復元し損ねたスナップショット」を検出してライトを復元できるようにするため
- 復元完了時に破棄する

### 5.5 エッジケースの方針(v1)

| ケース | 方針 |
|---|---|
| 会議中にライトを手動操作された | 会議終了時に**問答無用でスナップショットへ復元**する(README に明記) |
| 会議中のアプリクラッシュ | 起動時に残存スナップショットを検出し復元。ただし**起動時点でカメラが使用中**の場合は会議継続中とみなし、復元せずスナップショットを保持したまま onAir 状態で開始する(状態機械は初期状態を受け取れる設計にする) |
| 会議中に Bridge と通信不能 | リトライ(指数バックオフ、上限あり)。失敗時はメニューバーにエラー表示 |
| 対象ライトが物理的に電源 OFF | API エラーをメニューバーに表示、状態機械は継続 |

---

## 6. UI / UX

### 6.1 メニューバー

- `MenuBarExtra`(macOS 13+ API、本アプリは 14+)で常駐
- アイコンで状態を表現: 待機中 / ON AIR / エラー
- メニュー項目: 現在の状態、設定を開く、終了

### 6.2 設定画面 & オンボーディング

初回起動時のフロー:

1. Bridge を探索 → 見つかった Bridge を表示
2. 「リンクボタンを押してください」画面 → 押下を検知して key 取得
3. ライト一覧から対象ライトを選択
4. ON AIR 色・輝度を選択(デフォルト: 赤 / 100%)
5. テスト点灯ボタンで動作確認

設定はいつでもメニューバーから再構成可能とする。

### 6.3 ログイン時自動起動

`SMAppService.mainApp`(macOS 13+)でログイン項目への登録をトグルできるようにする。

---

## 7. セキュリティ / プライバシー

- カメラ映像・マイク音声には一切アクセスしない(デバイスの使用状態フラグのみ)
- `hue-application-key` は Keychain 保存
- 通信は LAN 内の Bridge のみ。外部への送信なし(Bridge 発見のフォールバック時のみ `discovery.meethue.com` へアクセス)
- **macOS 15 (Sequoia)+ のローカルネットワークプライバシー**: mDNS 探索と Bridge へのローカル HTTPS 接続に許可ダイアログが出る。Info.plist に `NSLocalNetworkUsageDescription` と `NSBonjourServices = ["_hue._tcp"]` を必ず含める。拒否されると探索も API 呼び出しも失敗するため、設定画面で `NWBrowser` の `.waiting`(policy denial)を検出して案内を表示する
- **App Sandbox は v1 では無効**(GitHub 配布のため必須ではなく、サンドボックス下での CMIO デバイス列挙の挙動が不明確なリスクを避ける)。notarization に必要な Hardened Runtime のみ有効にする
- この内容を README のプライバシーセクションに明記する

---

## 8. 配布

- **Developer ID 署名 + notarization** を基本線とする(Apple Developer Program 加入が前提)
- 加入しない期間の暫定運用: README に「初回起動時は右クリック → 開く」の手順を記載
- 将来的に Homebrew cask 対応を検討(notarization がほぼ前提となる)
- リリースは GitHub Releases に `.dmg` または `.zip` を添付。CI(GitHub Actions)でビルド → 署名 → notarize → リリースまで自動化するのが理想

---

## 9. プロジェクト構成(案)

```
huemdall/
├── project.yml                      # XcodeGen 定義(.xcodeproj は生成物)
├── Huemdall/
│   ├── App/
│   │   ├── HuemdallApp.swift        # @main, MenuBarExtra
│   │   └── AppState.swift           # @Observable なアプリ全体状態
│   ├── Detection/
│   │   ├── ActivityDetector.swift   # protocol
│   │   └── CameraDetector.swift     # CoreMediaIO 実装
│   ├── StateMachine/
│   │   ├── MeetingStateMachine.swift  # 純粋な event → [Effect] 状態機械
│   │   └── MeetingCoordinator.swift   # actor。detector/Hue/スナップショットの結線
│   ├── Hue/
│   │   ├── HueClient.swift          # CLIP v2
│   │   ├── HueModels.swift          # Codable 型、CIE xy 変換
│   │   ├── HueTLSDelegate.swift     # ルート CA アンカー + CN 検証
│   │   ├── BridgeDiscovery.swift    # mDNS + fallback
│   │   ├── LightSnapshot.swift
│   │   └── KeychainStore.swift
│   ├── UI/
│   │   ├── MenuBarView.swift
│   │   └── SettingsView.swift
│   └── Resources/
│       └── hue-root-ca.pem          # Signify ルート CA
├── HuemdallTests/
├── README.md
└── LICENSE
```

- 依存ライブラリは極力ゼロ(URLSession / Network.framework / CoreMediaIO の標準機能で完結)
- テスト: 状態機械とスナップショット復元ロジックはピュアな Swift として切り出し、単体テスト対象とする。`ActivityDetector` と `HueClient` は protocol 経由でモック差し替え可能にする

---

## 10. ロードマップ

| バージョン | 内容 | 状態 |
|---|---|---|
| v0.1 | カメラ検知 + 単一ライト制御 + 復元。設定は最小限 | 完了 |
| v0.2 | オンボーディング整備、ログイン時自動起動、エラー表示 | 完了 |
| v0.3 | 署名・notarization、GitHub Releases 配布 | 完了 |
| v0.4 | 手動オーバーライド + グローバルショートカット | 完了 |
| v0.5 | 複数ライトの同時制御 | 完了 |
| v0.6 | Hue シーン対応、All lights、色温度(mirek)復元の修正 | 完了 |
| v1.0 | README / ドキュメント整備、公開 | 未定 |

マイク検知(CompositeDetector)は誤検知リスクを考慮し、対応しないことにした。
