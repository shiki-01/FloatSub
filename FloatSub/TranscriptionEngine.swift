import Foundation
import AVFoundation
import Speech

struct TranscriptSegment: Identifiable {
    let id = UUID()
    let text: String
    /// 日本語訳。翻訳完了まで nil
    var translation: String?
}

/// SpeechAnalyzer / SpeechTranscriber による端末内ストリーミング文字起こし。
final class TranscriptionEngine {
    /// 途中結果（volatile）。確定すると isFinal = true で届く
    var onResult: ((String, Bool) -> Void)?
    var onLog: ((String) -> Void)?
    /// 結果の受信が異常終了したとき（文字起こしが続行できない）
    var onFailure: ((Error) -> Void)?

    private var analyzer: SpeechAnalyzer?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var analyzerFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?

    /// 実行時の対応可否判定。
    /// 指示書の supportsDevice 相当。iOS 26 の SDK では SpeechTranscriber.isAvailable が該当する。
    static var isSupported: Bool { SpeechTranscriber.isAvailable }

    func start(localeIdentifier: String) async throws {
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

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        self.continuation = continuation
        self.analyzer = analyzer

        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    self?.onResult?(String(result.text.characters), result.isFinal)
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
