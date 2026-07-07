# Huemdal

[English](README.md) | 日本語

カメラの利用状況に応じて、Philips Hue のライトの状態を変えられる macOS アプリです。カメラの利用を終えると元の状態に復元します。
リモート会議中などに、家族に「今は入ってこないで」というメッセージを伝えられます。

## 動作要件

- macOS 14 (Sonoma) 以降
- Philips Hue Bridge v2

## インストール

[Releases](https://github.com/shinespark/huemdal/releases) から最新の `Huemdal-<version>.zip` をダウンロードして展開し、`Huemdal.app` をアプリケーションフォルダに移動してください。リリースビルドは Developer ID で署名され Apple の公証(notarization)を受けているため、Gatekeeper の回避操作なしで起動できます。

## セットアップ

1. Huemdal を起動すると、メニューバーに表示されます
2. メニュー > 設定…(未設定時は セットアップ…)を開きます
3. Bridge タブで Hue Bridge を検索し、案内に従ってブリッジ本体のリンクボタンを押します
4. Lights タブで ライトを選びます
5. ライトの色と明るさを選ぶか、もしくはシーンに切り替えてHueアプリで設定したシーンを選べばセットアップ完了です

## プライバシー

- Huemdal は**カメラ映像やマイク音声には一切アクセスしません**。「いずれかのプロセスがこのカメラを使用中」というシステムフラグ(CoreMediaIO の `DeviceIsRunningSomewhere`)を読むだけです。そのため macOS のカメラ許可ダイアログも表示されません。
- 通信はすべてローカルネットワーク内で完結し、Hue Bridge と直接 TLS で通信します。インターネットへの送信は行いません。唯一の例外として、mDNS でのブリッジ発見に失敗した場合のみ `discovery.meethue.com` に 1 回問い合わせます。
