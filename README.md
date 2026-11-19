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

## 使い方

1. FloatSub を開き、「開始」を押す。共有ピッカーが開くので、画面全体の共有を開始する（開始のたびに必要）。
2. YouTube などで音声を再生する。他アプリへ切り替えると、字幕の PiP が自動で表示される。
3. 「言語」で原語と翻訳先を選ぶ。「字幕の表示」で原文の表示と文字サイズを変える。設定は保存される。
4. 終了するときは、FloatSub に戻って「停止」を押す。

制約:

- iOS の PiP は同時に 1 つだけ。YouTube など他アプリの PiP が開いている間は、字幕の PiP を表示できない。
- 取り込み方式の既定は ScreenCaptureKit（iOS 27）。「詳細」から ReplayKit（拡張）へ切り替えられる。判断の経緯は `docs/CAPTURE_DECISION.md`。

## フェーズの状況

| フェーズ | 内容 | 状況 |
|---|---|---|
| 1 | 音声取り込みと文字起こし | 実機で確認済み |
| 2 | 端末内翻訳（Translation framework） | 実機で確認済み |
| 3 | 字幕の PiP 表示 | 実機で確認済み |
| 4 | 言語選択、開始・停止、表示設定、安定化 | 実装済み、実機確認待ち |

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
