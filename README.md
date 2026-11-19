# FloatSub

iPhone で再生中の他アプリの音声（主に YouTube の英語ポッドキャスト）を端末内で文字起こし・日本語翻訳し、Picture in Picture の字幕として表示する個人用アプリです。App Store には公開しません。

## 構成

| パス | 内容 |
|---|---|
| `FloatSub/` | 本体アプリ（SwiftUI） |
| `FloatSubBroadcast/` | Broadcast Upload Extension（他アプリ音声の取り込み） |
| `Shared/` | 本体と拡張で共有する socket 転送定義 |
| `project.yml` | XcodeGen 定義（`.xcodeproj` は CI 上で生成） |
| `docs/PHASE1.md` | Phase 1 の実機検証手順と報告項目 |

## ビルド設定（GitHub）

Repository variables:

- `BUNDLE_ID_PREFIX`: 例 `com.yourname`（本体は `<prefix>.floatsub`、拡張は `<prefix>.floatsub.broadcast`、App Group は `group.<prefix>.floatsub`）
- `DEVELOPMENT_TEAM`: Apple Developer の Team ID

Repository secrets（App Store Connect API キー、権限は App Manager 以上）:

- `ASC_KEY_ID` / `ASC_ISSUER_ID` / `ASC_KEY_P8`（`.p8` の全文）

事前準備:

1. App Store Connect で本体の Bundle ID `<prefix>.floatsub` のアプリレコードを作成します（TestFlight 配信に必要）。
2. Actions の `TestFlight` workflow を手動実行します。App Group と拡張の provisioning は `-allowProvisioningUpdates` により自動作成されます。
3. TestFlight アプリから iPhone 16e にインストールします。

`CI` workflow は署名なしのコンパイル確認で、push ごとに実行されます。Secrets は不要です。
