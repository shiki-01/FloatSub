import Foundation
import AVFoundation
import FluidAudio

/// 端末内の話者分離（FluidAudio の LS-EEND、Core ML）。SpeechTranscriber には話者分離がないため、別に組み込む。
/// 取り込んだ音声を逐次渡し、「どの時間帯に誰が話したか」を保持する。字幕や履歴の文節には、その時間帯の話者を引いて付ける。
/// 推論は専用キューで行い、画面側からの問い合わせはロックで保護した結果の一覧だけを見る（推論を待たない）。
final class SpeakerDiarizer: @unchecked Sendable {
    private struct Span {
        let speaker: Int
        let start: Double
        let end: Double
    }

    private let queue = DispatchQueue(label: "floatsub.diarizer")
    private var diarizer: LSEENDDiarizer?

    private let lock = NSLock()
    private var spans: [Span] = []
    private var tentative: [Span] = []
    /// 話者が現れた順（表示は「話者1」から、この順で振る）
    private var order: [Int] = []

    /// モデルを準備する。初回はモデルをダウンロードする（HuggingFace）。
    func prepare() async throws {
        let created = try await LSEENDDiarizer(variant: .dihard3)
        queue.sync { diarizer = created }
    }

    /// 受信した音声を渡す。取り込み側の Thread から呼ぶ。バッファは複製（Float 配列）してからキューへ渡す。
    func feed(_ buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return }
        let samples = Array(UnsafeBufferPointer(start: channels[0], count: Int(buffer.frameLength)))
        let rate = buffer.format.sampleRate
        queue.async { [weak self] in self?.process(samples, sampleRate: rate) }
    }

    func stop() {
        queue.async { [weak self] in
            self?.diarizer?.cleanup()
            self?.diarizer = nil
        }
    }

    private func process(_ samples: [Float], sampleRate: Double) {
        guard let diarizer else { return }
        do {
            try diarizer.addAudio(samples, sourceSampleRate: sampleRate)
            // 1 回の追加で複数ステップ分が進むことがあるため、数回まで繰り返し取り出す
            for _ in 0..<8 {
                guard let update = try diarizer.process() else { break }
                absorb(finalized: update.finalizedSegments, tentative: update.tentativeSegments)
            }
        } catch {
            // 推論の失敗は握りつぶす（話者ラベルが付かないだけで、文字起こしと翻訳は続行する）
        }
    }

    private func absorb(finalized: [DiarizerSegment], tentative newTentative: [DiarizerSegment]) {
        lock.lock(); defer { lock.unlock() }
        func span(_ s: DiarizerSegment) -> Span {
            Span(speaker: s.speakerIndex, start: Double(s.startTime), end: Double(s.endTime))
        }
        spans.append(contentsOf: finalized.map(span))
        if spans.count > 5000 { spans.removeFirst(spans.count - 5000) }
        tentative = newTentative.map(span)
        for s in spans + tentative where !order.contains(s.speaker) { order.append(s.speaker) }
    }

    private func label(for speaker: Int) -> String {
        "話者\((order.firstIndex(of: speaker) ?? order.count) + 1)"
    }

    /// 指定した時間帯（音声の時間軸、秒）でもっとも長く話していた話者のラベル。情報がなければ nil。
    func label(from start: Double, to end: Double) -> String? {
        lock.lock(); defer { lock.unlock() }
        var overlap: [Int: Double] = [:]
        for s in spans + tentative {
            let length = min(end, s.end) - max(start, s.start)
            if length > 0 { overlap[s.speaker, default: 0] += length }
        }
        guard let best = overlap.max(by: { $0.value < $1.value })?.key else { return nil }
        return label(for: best)
    }

    /// もっとも新しい話者のラベル。話している途中の字幕に使う。
    func latestLabel() -> String? {
        lock.lock(); defer { lock.unlock() }
        guard let last = (spans + tentative).max(by: { $0.end < $1.end }) else { return nil }
        return label(for: last.speaker)
    }
}
