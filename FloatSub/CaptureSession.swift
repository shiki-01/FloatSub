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
    var volatileText = ""
    var segments: [TranscriptSegment] = []
    var logs: [String] = []

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
            engine.onResult = { [weak self] text, isFinal in
                Task { @MainActor in self?.handleResult(text, isFinal: isFinal) }
            }
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
            do {
                let translated = try await translator.translate(text)
                if let i = segments.firstIndex(where: { $0.id == id }) {
                    segments[i].translation = translated
                }
                updatePiP()
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
    private func updatePiP() {
        guard let last = segments.last else { return }
        pip.show(original: last.text, translation: last.translation ?? "翻訳中…")
    }

    private func handleResult(_ text: String, isFinal: Bool) {
        if isFinal {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                segments.append(TranscriptSegment(text: trimmed))
                updatePiP()
                Task { await flushTranslations() }
            }
            volatileText = ""
        } else {
            volatileText = text
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
