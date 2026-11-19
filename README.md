# FloatSub

iPhone で再生中の他アプリの音声（主に YouTube の英語ポッドキャスト）を端末内で文字起こしし、日本語に翻訳して、Picture in Picture の字幕として他アプリの上に表示する個人用アプリです。App Store には公開しません。外部サーバー、課金 API、アカウント登録は使わず、処理はすべて端末内で完結します。

## 動作環境

- iPhone（動作確認: iPhone 16e）
- iOS 27 以降

## 使い方

1. FloatSub を開き、「入力」で取り込み元を選ぶ。画面共有の場合は「開始」を押すと共有ピッカーが開くので、画面全体の共有を開始する（開始のたびに必要）。マイクの場合は共有が不要で、初回にマイクの許可を求められる。
2. YouTube などで音声を再生する。他アプリへ切り替えると、字幕の PiP が自動で表示される。
3. 「言語」で原語と翻訳先を選ぶ。「字幕の表示」で原文の表示と文字サイズを変える。設定は保存される。
4. 終了するときは、FloatSub に戻って「停止」を押す。

マイクを選ぶと、対面会話や講義の音声を文字起こしできる。字幕はアプリ内の「字幕」欄にも表示される。他アプリへ切り替えたときは、PiP の小窓に表示される。

制約:

- iOS の PiP は同時に 1 つだけ。YouTube など他アプリの PiP が開いている間は、字幕の PiP を表示できない。
- 共有の開始は、起動のたびに利用者の操作が必要（iOS の仕様）。

## 仕組み

| 処理 | 使用技術 |
|---|---|
| 音声の取り込み | ScreenCaptureKit（`SCContentSharingPicker` と `SCStream`）。フォールバックとして ReplayKit（Broadcast Upload Extension） |
| 文字起こし | Speech framework の `SpeechAnalyzer` と `SpeechTranscriber`（端末内、途中結果を逐次出力） |
| 翻訳 | Translation framework（端末内、確定した文節ごと） |
| 字幕の表示 | 字幕を描画した映像フレームを `AVSampleBufferDisplayLayer` へ流し、`AVPictureInPictureController` で表示 |
| 実行維持 | PiP の再生と、`audio` background mode による無音再生 |

取り込み方式の判断の経緯は `docs/CAPTURE_DECISION.md` にあります。

## ディレクトリ

| パス | 内容 |
|---|---|
| `FloatSub/` | 本体アプリ（SwiftUI） |
| `FloatSubBroadcast/` | Broadcast Upload Extension（フォールバックの取り込み） |
| `Shared/` | 本体と拡張で共有する socket 転送定義 |
| `project.yml` | XcodeGen 定義（`.xcodeproj` は CI 上で生成） |
| `tools/` | アプリアイコンの生成スクリプト |
| `docs/` | 検証手順と判断記録 |

## ビルドと配信

Mac に Xcode を入れず、GitHub Actions でビルドして TestFlight へ配信します。

- `CI`: push ごとに署名なしでコンパイルを確認する（Secrets 不要）。
- `TestFlight`: 手動実行。署名付きでビルドし、App Store Connect へアップロードする。ランナーは `xcode-27`（Xcode 27.2）。

設定（GitHub の Settings → Secrets and variables → Actions）:

| 種別 | 名前 | 内容 |
|---|---|---|
| Variable | `BUNDLE_ID_PREFIX` | 例 `com.yourname`（本体は `<prefix>.floatsub`、拡張は `<prefix>.floatsub.broadcast`、App Group は `group.<prefix>.floatsub`） |
| Variable | `DEVELOPMENT_TEAM` | Apple Developer の Team ID |
| Secret | `ASC_KEY_ID` | App Store Connect API キーの Key ID |
| Secret | `ASC_ISSUER_ID` | 同 Issuer ID |
| Secret | `ASC_KEY_P8` | `.p8` の全文（アクセス権は Admin を推奨） |

事前準備（Apple Developer / App Store Connect）:

1. App Group `group.<prefix>.floatsub` を登録する。
2. App ID `<prefix>.floatsub` と `<prefix>.floatsub.broadcast` を登録し、どちらにも上記 App Group を割り当てる。
3. App Store Connect に、`<prefix>.floatsub` のアプリレコードを作成する。

## 開発状況

Phase 4 までは実機（iPhone 16e）で確認済み。Phase 5 は CI でのコンパイル確認までが完了しており、次の項目は実機での確認が必要。

| 機能 | 状態 | 実機で確認する項目 |
|---|---|---|
| マイク入力モード | 実装済み・実機確認待ち | 初回の許可ダイアログ、拒否時の案内（設定アプリへの導線）、マイクでの文字起こしと翻訳、アプリ内字幕の表示、他アプリへ切り替えたときの PiP と実行維持、イヤホンの抜き差し後の復帰 |

## ライセンス

MIT License。詳細は `LICENSE` を参照。
