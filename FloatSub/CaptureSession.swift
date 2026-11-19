import Foundation
import AVFoundation
import Observation
import Translation

/// 音声の取り込み方式。実機検証（iOS 27）で ScreenCaptureKit の取得を確認したため、既定は ScreenCaptureKit。
enum CaptureSource: String, CaseIterable, Identifiable {
    case screenCaptureKit
    case replayKit

    var id: String { rawValue }

    var title: String {
        switch self {
        case .screenCaptureKit: "ScreenCaptureKit"
        case .replayKit: "ReplayKit（拡張）"
        }
    }

    /// 現在の SDK で使える方式（ScreenCaptureKit は iOS 27 SDK のみ）
    static var available: [CaptureSource] {
        #if canImport(ScreenCaptureKit)
        [.screenCaptureKit, .replayKit]
        #else
        [.replayKit]
        #endif
    }

    static var preferred: CaptureSource { available[0] }
}

enum CaptureError: LocalizedError {
    case unsupported
    var errorDescription: String? { "この SDK では ScreenCaptureKit を利用できません" }
}

/// 統括。無音再生（実行維持）→ 翻訳準備 → 文字起こし → socket 待受、の順に起動する。
/// 確定した文節ごとに、Translation framework で日本語へ翻訳する。
@MainActor
@Observable
final class CaptureSession {
    var isRunning = false
    var localeIdentifier = "en-US"
    var captureSource = CaptureSource.preferred
    /// 取り込みの状態（画面表示用）
    var captureStatus = "停止"
    var targetLanguageIdentifier = "ja"
    // 字幕の表示設定
    var showOriginal = true
    /// 話している途中の原文（確定前）も PiP に出すか
    var showLiveOriginal = false
    var fontScale = 1.0
    var volatileText = ""
    var segments: [TranscriptSegment] = []
    var logs: [String] = []
    /// 音声から字幕までの遅延の集計（詳細欄に表示）
    var latencySummary = ""
    private var latencyStats = LatencyStats()

    // 取り込み診断（実機での検証用）
    var extensionConnected = false
    var receivedBuffers = 0
    var receivedSampleRate = 0.0
    var level: Float = 0 // 直近バッファの RMS

    // 翻訳
    var translationStatus = "未準備"
    /// 非 nil になると、ContentView の translationTask が言語モデルのダウンロード確認を出す
    var translationConfiguration: TranslationSession.Configuration?

    private let keepAlive = KeepAlive()
    private let receiver = AudioReceiver()
    #if canImport(ScreenCaptureKit)
    private let sckSource = SCKAudioSource()
    #endif
    private let engine = TranscriptionEngine()
    private let translator = TranslationEngine()
    /// 字幕の PiP 表示
    let pip = PiPController()
    private var isTranslating = false
    /// 開始処理の多重実行を防ぐ（isRunning は開始完了後に立つため別に持つ）
    private var isStarting = false

    /// 保存対象の設定。変更の検知（onChange）に使う。
    struct SettingsSnapshot: Equatable {
        var locale: String
        var target: String
        var source: CaptureSource
        var showOriginal: Bool
        var showLiveOriginal: Bool
        var fontScale: Double
    }

    var settingsSnapshot: SettingsSnapshot {
        SettingsSnapshot(locale: localeIdentifier, target: targetLanguageIdentifier, source: captureSource,
                         showOriginal: showOriginal, showLiveOriginal: showLiveOriginal, fontScale: fontScale)
    }

    init() {
        let d = UserDefaults.standard
        if let v = d.string(forKey: "locale") { localeIdentifier = v }
        if let v = d.string(forKey: "target") { targetLanguageIdentifier = v }
        if let raw = d.string(forKey: "captureSource"), let v = CaptureSource(rawValue: raw),
           CaptureSource.available.contains(v) { captureSource = v }
        if d.object(forKey: "showOriginal") != nil { showOriginal = d.bool(forKey: "showOriginal") }
        showLiveOriginal = d.bool(forKey: "showLiveOriginal")
        if d.object(forKey: "fontScale") != nil { fontScale = d.double(forKey: "fontScale") }
    }

    func saveSettings() {
        let d = UserDefaults.standard
        d.set(localeIdentifier, forKey: "locale")
        d.set(targetLanguageIdentifier, forKey: "target")
        d.set(captureSource.rawValue, forKey: "captureSource")
        d.set(showOriginal, forKey: "showOriginal")
        d.set(showLiveOriginal, forKey: "showLiveOriginal")
        d.set(fontScale, forKey: "fontScale")
    }

    /// 表示設定を PiP の字幕へ反映する。
    func applySubtitleStyle() {
        pip.apply(style: SubtitleStyle(showOriginal: showOriginal, fontScale: CGFloat(fontScale)))
    }

    private var sourceLanguage: Locale.Language {
        Locale(identifier: localeIdentifier).language
    }
    private var targetLanguage: Locale.Language {
        Locale.Language(identifier: targetLanguageIdentifier)
    }

    func start() async {
        guard !isRunning, !isStarting else { return }
        isStarting = true
        defer { isStarting = false }
        log("開始処理")
        pip.onLog = { [weak self] msg in self?.log(msg) }
        do {
            try keepAlive.start()
            log("無音再生を開始（実行維持）")

            await prepareTranslation()

            engine.onLog = { [weak self] msg in Task { @MainActor in self?.log(msg) } }
            engine.onFailure = { [weak self] error in
                Task { @MainActor in
                    guard let self, self.isRunning else { return }
                    self.captureStatus = "文字起こしが停止しました"
                    self.log("文字起こしが続行できないため停止します: \(error.localizedDescription)")
                    await self.stop()
                    self.captureStatus = "文字起こしが停止しました"
                }
            }
            engine.onResult = { [weak self] result in
                Task { @MainActor in self?.handleResult(result) }
            }
            latencyStats.reset()
            latencySummary = ""
            try await engine.start(localeIdentifier: localeIdentifier)
            log("文字起こし準備完了 (\(localeIdentifier))")

            let handler = makeBufferHandler()
            switch captureSource {
            case .replayKit:
                receiver.onEvent = { [weak self] msg in
                    Task { @MainActor in
                        self?.extensionConnected = msg.contains("接続しました")
                        self?.captureStatus = msg
                        self?.log(msg)
                    }
                }
                receiver.onBuffer = handler
                try receiver.start()
                captureStatus = "拡張の接続待ち"
                log("socket 待受を開始。画面収録（ブロードキャスト）を開始してください")
            case .screenCaptureKit:
                try await startScreenCaptureKit(handler)
            }
            isRunning = true
        } catch {
            log("開始に失敗: \(error.localizedDescription)")
            await stop()
        }
    }

    func stop() async {
        receiver.stop()
        #if canImport(ScreenCaptureKit)
        await sckSource.stop()
        #endif
        captureStatus = "停止"
        await engine.stop()
        keepAlive.stop()
        translator.reset()
        pip.stop()
        translationConfiguration = nil
        translationStatus = "未準備"
        isRunning = false
        extensionConnected = false
        log("停止しました")
    }

    // MARK: - 取り込み

    /// 受信した音声を文字起こしへ流し、診断値を更新する。取り込み側の Thread から呼ばれる。
    private func makeBufferHandler() -> (AVAudioPCMBuffer) -> Void {
        return { [weak self] buffer in
            guard let self else { return }
            self.engine.feed(buffer)
            let rms = Self.rms(buffer)
            let rate = buffer.format.sampleRate
            Task { @MainActor in
                self.receivedBuffers += 1
                self.receivedSampleRate = rate
                self.level = rms
            }
        }
    }

    /// 共有ピッカーで共有対象（画面全体）を選んでもらい、音声の取り込みを開始する。
    private func startScreenCaptureKit(_ handler: @escaping (AVAudioPCMBuffer) -> Void) async throws {
        #if canImport(ScreenCaptureKit)
        sckSource.onBuffer = handler
        sckSource.onEvent = { [weak self] msg in
            Task { @MainActor in
                self?.captureStatus = msg
                self?.log(msg)
            }
        }
        sckSource.onStopped = { [weak self] error in
            Task { @MainActor in
                guard let self, self.isRunning else { return }
                self.log("ScreenCaptureKit のストリームが停止しました: \(error.localizedDescription)")
                await self.stop()
                self.captureStatus = "共有が停止しました（開始し直してください）"
            }
        }
        captureStatus = "共有対象の選択待ち"
        log("共有ピッカーを開きます。画面全体の共有を開始してください")
        try await sckSource.start()
        captureStatus = "ScreenCaptureKit で取り込み中"
        log("ScreenCaptureKit の取り込みを開始しました。他アプリで音声を再生してください")
        #else
        throw CaptureError.unsupported
        #endif
    }

    // MARK: - 翻訳

    /// 言語モデルの導入状況を確認する。未導入ならダウンロード確認の表示を要求する。
    private func prepareTranslation() async {
        let source = sourceLanguage
        let target = targetLanguage
        switch await translator.prepare(source: source, target: target) {
        case .ready:
            translationStatus = "準備完了"
            log("翻訳の準備完了 (\(localeIdentifier) → \(targetLanguageIdentifier))")
        case .needsDownload:
            translationStatus = "言語モデルのダウンロード待ち"
            log("翻訳の言語モデルが未導入です。表示される確認でダウンロードしてください")
            translationConfiguration = TranslationSession.Configuration(source: source, target: target)
        case .unsupported:
            translationStatus = "非対応の言語ペア"
            log("この言語ペアの翻訳は非対応です (\(localeIdentifier) → \(targetLanguageIdentifier))")
        }
    }

    /// translationTask から呼ばれる。言語モデルをダウンロードし、翻訳を再開する。
    func handleDownload(_ session: TranslationSession) async {
        do {
            try await session.prepareTranslation()
            log("翻訳の言語モデルを取得しました")
        } catch {
            translationStatus = "ダウンロード失敗"
            log("翻訳の言語モデル取得に失敗: \(error.localizedDescription)")
            return
        }
        translationConfiguration = nil
        await prepareTranslation()
        await flushTranslations()
    }

    /// 未翻訳の確定文節を古い順に 1 件ずつ翻訳する。多重起動は isTranslating で防ぐ。
    private func flushTranslations() async {
        guard !isTranslating, translator.isReady else { return }
        isTranslating = true
        defer { isTranslating = false }
        while let index = segments.firstIndex(where: { $0.translation == nil }) {
            let id = segments[index].id
            let text = segments[index].text
            let audioEnd = segments[index].audioEnd
            do {
                let began = ProcessInfo.processInfo.systemUptime
                let translated = try await translator.translate(text)
                if let i = segments.firstIndex(where: { $0.id == id }) {
                    segments[i].translation = translated
                }
                updatePiP()
                recordCaptionLatency(audioEnd: audioEnd, translationBegan: began)
            } catch {
                log("翻訳に失敗: \(error.localizedDescription)")
                // 失敗した文節は空訳にして無限ループを避ける
                if let i = segments.firstIndex(where: { $0.id == id }) {
                    segments[i].translation = "（翻訳失敗）"
                }
            }
        }
    }

    /// 最新の確定文節（原文と日本語訳）を PiP の字幕へ反映する。
    /// showLiveOriginal が有効なら、確定前の原文を原文欄に出す。
    private func updatePiP() {
        let last = segments.last
        let original = (showLiveOriginal && !volatileText.isEmpty) ? volatileText : (last?.text ?? "")
        let translation = last.map { $0.translation ?? "翻訳中…" } ?? ""
        guard !original.isEmpty || !translation.isEmpty else { return }
        pip.show(original: original, translation: translation)
    }

    /// 履歴の保持件数。長時間の利用でメモリが増え続けないようにする。
    private static let maxSegments = 300

    /// 確定訳を字幕へ出した時点の遅延を記録する（音声が届いてから表示までの合計と、翻訳単体の時間）。
    private func recordCaptionLatency(audioEnd: Double, translationBegan: TimeInterval) {
        let now = ProcessInfo.processInfo.systemUptime
        let translation = now - translationBegan
        latencyStats.add(.translation, seconds: translation)
        guard let captured = engine.timeline.uptime(atAudio: audioEnd) else { return }
        let total = now - captured
        latencyStats.add(.caption, seconds: total)
        latencySummary = latencyStats.summary
        log(String(format: "遅延 字幕（確定訳）%.2f 秒（うち翻訳 %.2f 秒）", total, translation))
    }

    private func handleResult(_ result: TranscriptionResult) {
        let text = result.text
        let isFinal = result.isFinal
        if isFinal {
            if let captured = result.capturedUptime {
                let recognition = result.receivedUptime - captured
                latencyStats.add(.recognition, seconds: recognition)
                log(String(format: "遅延 認識（確定）%.2f 秒", recognition))
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                segments.append(TranscriptSegment(text: trimmed, audioStart: result.audioStart, audioEnd: result.audioEnd))
                if segments.count > Self.maxSegments {
                    segments.removeFirst(segments.count - Self.maxSegments)
                }
                volatileText = ""
                updatePiP()
                Task { await flushTranslations() }
            }
            volatileText = ""
        } else {
            volatileText = text
            if showLiveOriginal { updatePiP() }
        }
    }

    func log(_ message: String) {
        let stamp = Date.now.formatted(date: .omitted, time: .standard)
        logs.append("\(stamp) \(message)")
        if logs.count > 200 { logs.removeFirst(logs.count - 200) }
    }

    nonisolated private static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let ch = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<Int(buffer.frameLength) { sum += ch[i] * ch[i] }
        return (sum / Float(buffer.frameLength)).squareRoot()
    }
}
