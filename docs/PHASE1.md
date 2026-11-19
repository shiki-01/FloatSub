# Phase 1 検証手順

目的: 音声取り込み方式の確定と、英語音声の文字起こし表示の確認。

## 実装している取り込み経路

- 経路 A（ReplayKit）: Broadcast Upload Extension が `.audioApp` を mono Float32 に変換し、App Group コンテナ内の Unix domain socket で本体へ送る。本体は無音再生（`audio` background mode）で実行を維持する。
- 経路 B（ScreenCaptureKit 検証）: `SCK_PROBE` 付きビルドでのみ「ScreenCaptureKit 検証」ボタンが現れる。アプリ内プロセスで他アプリ音声が取得できるかを 10 秒間試行して報告する。

## 手順

1. TestFlight からインストールし、起動する。
2. ScreenCaptureKit 検証: 「10 秒間の音声取得を試行」を押した直後にホームへ戻り、YouTube（または Safari）で英語音声を 10 秒以上再生する。FloatSub へ戻り、レポート全文を控える。他アプリがバックグラウンド再生を許可しない場合は、再生が止まり音声バッファ 0 になる点に注意する。
3. ReplayKit 経路: 「1. 受信と文字起こしを開始」→「2. 画面収録（音声取り込み）を開始」→ FloatSub Broadcast を選択して開始 → YouTube に切り替えて英語ポッドキャストを再生する。
4. FloatSub へ戻り、次を確認する。

## 報告項目

- ScreenCaptureKit のコンパイル可否（CI の `sck-probe` ジョブ）と、実機でのレポート全文
- 拡張の接続状態、受信バッファ数、サンプルレート、音声レベル
- 文字起こしの表示有無、遅延の体感、YouTube を前面にした状態でバックグラウンド処理が継続するか
- 拡張のメモリ使用量（Xcode を使えないため、拡張が強制終了されないかで代用）
- `SpeechTranscriber.isAvailable` の値と、言語モデル取得の成否
