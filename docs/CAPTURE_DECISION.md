# 音声取り込み方式の判断記録

## 結論

主経路は ScreenCaptureKit（iOS 27）、フォールバックは ReplayKit（Broadcast Upload Extension）とする。

## 根拠（実機・iPhone 16e、iOS 27）

| 経路 | 結果 |
|---|---|
| ScreenCaptureKit（`SCContentSharingPicker` → `SCStream`、`capturesAudio`） | 他アプリ再生中に 30 秒で 1532 バッファ、最大ピーク 0.83、48000 Hz・1ch・Float32。アプリを背面にしても継続 |
| ReplayKit（拡張 → Unix domain socket → 本体） | 2388 バッファ、44100 Hz。英語の文字起こしと日本語訳まで表示を確認 |

## SDK 側の事実（iOS 27.1 SDK のヘッダー）

- `SCShareableContent` とディスプレイ指定の `SCContentFilter` は iOS で使えない（`API_UNAVAILABLE(ios)`）。
- iOS で使えるのは `SCContentSharingPicker`（`ios(27.0)`）経由の経路。`SCStream`、`SCStreamOutputType.audio`、`capturesAudio` などは `ios(27.0)`。
- iOS 26.5 SDK には `ScreenCaptureKit` モジュール自体がない。

## 運用上の注意

- 共有の開始は、起動のたびに利用者の操作（ピッカーでの選択）が必要。
- ScreenCaptureKit と ReplayKit は同時に使わない（画面収録が重複するため）。
- 未確認: 長時間（数十分）の継続、バックグラウンドでのメモリ・電力、他アプリの PiP が先に開いている場合の挙動。
