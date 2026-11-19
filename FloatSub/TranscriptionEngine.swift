import Foundation
import AVFoundation
import Speech

struct TranscriptSegment: Identifiable {
    let id = UUID()
    let text: String
    /// 日本語訳。翻訳完了まで nil
    var translation: String?
    /// 確定訳が届くまで仮に出す暫定訳（薄く表示する）
    var provisionalTranslation: String?
    /// 音声の時間軸（取り込んだ音声の累積秒）での位置
    var audioStart = 0.0
    var audioEnd = 0.0
}

/// 文字起こしの 1 結果。途中結果（volatile）と確定結果の両方に使う。
struct TranscriptionResult {
    let text: String
    let isFinal: Bool
    /// この結果が覆う音声の範囲（音声の時間軸、秒）
    let audioStart: Double
    let audioEnd: Double
    /// audioEnd の音声を文字起こしへ流し込んだ時刻（systemUptime）。遅延の計測に使う
    let capturedUptime: TimeInterval?
    /// 結果を受け取った時刻（systemUptime）
    let receivedUptime: TimeInterval
}

/// SpeechAnalyzer / SpeechTranscriber による端末内ストリーミング文字起こし。
final class TranscriptionEngine {
    /// 途中結果（volatile）。確定すると isFinal = true で届く
    var onResult: ((TranscriptionResult) -> Void)?
    var onLog: ((String) -> Void)?
    /// 結果の受信が異常終了したとき（文字起こしが続行できない）
    var onFailure: ((Error) -> Void)?

    private var analyzer: SpeechAnalyzer?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var analyzerFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?
    /// 音声の時間軸と実時刻の対応（遅延の計測用）
    let timeline = AudioTimeline()

    /// 実行時の対応可否判定。
    /// 指示書の supportsDevice 相当。iOS 26 の SDK では SpeechTranscriber.isAvailable が該当する。
    static var isSupported: Bool { SpeechTranscriber.isAvailable }

    /// 用語を認識の手がかり（contextual strings）として analyzer に渡す。開始前・実行中のどちらでも呼べる。
    private func applyContext(_ terms: [String], to analyzer: SpeechAnalyzer) async {
        let context = AnalysisContext()
        context.contextualStrings = [.general: terms]
        do {
            try await analyzer.setContext(context)
            onLog?("用語を \(terms.count) 件、認識に反映しました")
        } catch {
            onLog?("用語の反映に失敗: \(error.localizedDescription)")
        }
    }

    /// 実行中に用語が変わったとき。
    func updateGlossary(_ terms: [String]) async {
        guard let analyzer else { return }
        await applyContext(terms, to: analyzer)
    }

    func start(localeIdentifier: String, glossary: [String] = []) async throws {
        guard Self.isSupported else { throw EngineError.unsupportedDevice }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: localeIdentifier)) else {
            throw EngineError.unsupportedLocale(localeIdentifier)
        }
        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        // 端末の音声モデルの状況を記録する（OS 管理のアセットのため、アプリ側でバージョンは選べない）
        let installed = await SpeechTranscriber.installedLocales.map(\.identifier).sorted()
        onLog?("OS \(ProcessInfo.processInfo.operatingSystemVersionString) / 導入済み音声モデル: \(installed.joined(separator: ", "))")

        // 言語モデルが未取得なら AssetInventory 経由でダウンロードする
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            onLog?("言語モデルを取得中 (\(locale.identifier))")
            try await request.downloadAndInstall()
            onLog?("言語モデルの取得が完了しました")
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        onLog?("analyzer 入力形式: \(analyzerFormat.map { "\($0.sampleRate)Hz \($0.channelCount)ch \($0.commonFormat.rawValue)" } ?? "不明")")

        if !glossary.isEmpty { await applyContext(glossary, to: analyzer) }
        timeline.reset()
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        self.continuation = continuation
        self.analyzer = analyzer

        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    guard let self else { break }
                    let received = ProcessInfo.processInfo.systemUptime
                    let start = result.range.start.seconds
                    let end = result.range.end.seconds
                    let audioStart = start.isFinite ? start : 0
                    let audioEnd = end.isFinite ? end : audioStart
                    self.onResult?(TranscriptionResult(
                        text: String(result.text.characters), isFinal: result.isFinal,
                        audioStart: audioStart, audioEnd: audioEnd,
                        capturedUptime: self.timeline.uptime(atAudio: audioEnd), receivedUptime: received))
                }
            } catch {
                self?.onLog?("文字起こしエラー: \(error.localizedDescription)")
                self?.onFailure?(error)
            }
        }
        try await analyzer.start(inputSequence: stream)
    }

    /// 受信した音声を analyzer の入力形式へ変換して流し込む。受信 Thread から呼ぶ（単一 Thread 前提）。
    func feed(_ buffer: AVAudioPCMBuffer) {
        guard let continuation, let target = analyzerFormat else { return }
        if converter == nil || converterInputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: target)
            converterInputFormat = buffer.format
        }
        guard let converter else { return }
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, out.frameLength > 0 else { return }
        timeline.recordFed(seconds: Double(out.frameLength) / target.sampleRate)
        continuation.yield(AnalyzerInput(buffer: out))
    }

    func stop() async {
        continuation?.finish()
        continuation = nil
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        resultsTask?.cancel()
        resultsTask = nil
        analyzer = nil
        converter = nil
    }

    enum EngineError: LocalizedError {
        case unsupportedDevice
        case unsupportedLocale(String)
        var errorDescription: String? {
            switch self {
            case .unsupportedDevice: "この端末は SpeechTranscriber に対応していません"
            case .unsupportedLocale(let id): "ロケール \(id) は SpeechTranscriber で未対応です"
            }
        }
    }
}
