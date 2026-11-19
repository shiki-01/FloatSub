import Foundation
import AVFoundation
import Observation

/// Phase 1 の統括。無音再生（実行維持）→ socket 待受 → 文字起こし開始、の順に起動する。
@MainActor
@Observable
final class CaptureSession {
    var isRunning = false
    var localeIdentifier = "en-US"
    var volatileText = ""
    var segments: [TranscriptSegment] = []
    var logs: [String] = []

    // 取り込み診断（実機での検証用）
    var extensionConnected = false
    var receivedBuffers = 0
    var receivedSampleRate = 0.0
    var level: Float = 0 // 直近バッファの RMS

    private let keepAlive = KeepAlive()
    private let receiver = AudioReceiver()
    private let engine = TranscriptionEngine()

    func start() async {
        guard !isRunning else { return }
        log("開始処理")
        do {
            try keepAlive.start()
            log("無音再生を開始（実行維持）")

            engine.onLog = { [weak self] msg in Task { @MainActor in self?.log(msg) } }
            engine.onResult = { [weak self] text, isFinal in
                Task { @MainActor in self?.handleResult(text, isFinal: isFinal) }
            }
            try await engine.start(localeIdentifier: localeIdentifier)
            log("文字起こし準備完了 (\(localeIdentifier))")

            receiver.onEvent = { [weak self] msg in
                Task { @MainActor in
                    self?.extensionConnected = msg.contains("接続しました")
                    self?.log(msg)
                }
            }
            // 受信 Thread で変換・投入し、診断値のみ MainActor へ送る
            receiver.onBuffer = { [weak self] buffer in
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
            try receiver.start()
            log("socket 待受を開始。画面収録（ブロードキャスト）を開始してください")
            isRunning = true
        } catch {
            log("開始に失敗: \(error.localizedDescription)")
            await stop()
        }
    }

    func stop() async {
        receiver.stop()
        await engine.stop()
        keepAlive.stop()
        isRunning = false
        extensionConnected = false
        log("停止しました")
    }

    private func handleResult(_ text: String, isFinal: Bool) {
        if isFinal {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { segments.append(TranscriptSegment(text: trimmed)) }
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
