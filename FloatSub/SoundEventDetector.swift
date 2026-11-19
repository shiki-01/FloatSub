import Foundation
import AVFoundation
import SoundAnalysis

/// 検出する非音声イベントの種類。
enum SoundLabel: String, CaseIterable {
    case laughter
    case music
    case applause
    case cheering

    /// 字幕と履歴に出す表記
    var caption: String {
        switch self {
        case .laughter: "[笑い]"
        case .music: "[音楽]"
        case .applause: "[拍手]"
        case .cheering: "[歓声]"
        }
    }

    /// SoundAnalysis の内蔵分類器（version1）の識別子のうち、この種類にまとめるもの
    var identifiers: [String] {
        switch self {
        case .laughter: ["laughter", "giggle", "chuckle_chortle", "belly_laugh"]
        case .music: ["music", "singing"]
        case .applause: ["applause", "clapping"]
        case .cheering: ["cheering"]
        }
    }
}

/// 非音声イベントの開始・終了。time は音声の時間軸（取り込んだ音声の累積秒）。
struct SoundEvent {
    enum Phase { case began, ended }
    let label: SoundLabel
    let phase: Phase
    let time: Double
}

/// SoundAnalysis の内蔵分類器で、笑い声・音楽・拍手などを検出する（端末内で完結）。
/// 取り込み側の Thread から feed を呼ぶ。解析は専用のシリアルキューで行い、状態もそのキューだけで扱う。
final class SoundEventDetector: NSObject, SNResultsObserving, @unchecked Sendable {
    /// イベントの開始・終了（解析キューから呼ばれる）
    var onEvent: ((SoundEvent) -> Void)?
    /// 「音楽だけが鳴っていて、話し声が少ない」状態が変わったとき（翻訳の抑制に使う）
    var onMusicOnlyChange: ((Bool) -> Void)?

    /// 検出とみなす確信度と、終了とみなすまでの保持時間（秒）
    private static let threshold = 0.6
    private static let holdSeconds = 1.5
    /// 音楽だけとみなす、話し声の確信度の上限
    private static let speechCeiling = 0.4

    private let queue = DispatchQueue(label: "floatsub.sound")
    private var analyzer: SNAudioStreamAnalyzer?
    private var format: AVAudioFormat?
    private var framePosition: AVAudioFramePosition = 0
    private var timeOffset = 0.0
    private var lastAbove: [SoundLabel: Double] = [:]
    private var active = Set<SoundLabel>()
    private var musicOnly = false

    /// 受信した音声を解析へ渡す。バッファは呼び出し側で再利用されうるため、複製してから渡す。
    func feed(_ buffer: AVAudioPCMBuffer) {
        guard let copy = Self.copy(buffer) else { return }
        queue.async { [weak self] in self?.analyze(copy) }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            // 検出中のイベントを閉じる
            for label in active { onEvent?(SoundEvent(label: label, phase: .ended, time: lastAbove[label] ?? 0)) }
            analyzer?.removeAllRequests()
            analyzer = nil
            format = nil
            active.removeAll()
            lastAbove.removeAll()
            if musicOnly { musicOnly = false; onMusicOnlyChange?(false) }
        }
    }

    private func analyze(_ buffer: AVAudioPCMBuffer) {
        if analyzer == nil || format != buffer.format {
            if let format { timeOffset += Double(framePosition) / format.sampleRate }
            framePosition = 0
            let newAnalyzer = SNAudioStreamAnalyzer(format: buffer.format)
            do {
                let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
                try newAnalyzer.add(request, withObserver: self)
            } catch {
                return
            }
            analyzer = newAnalyzer
            format = buffer.format
        }
        analyzer?.analyze(buffer, atAudioFramePosition: framePosition)
        framePosition += AVAudioFramePosition(buffer.frameLength)
    }

    // MARK: SNResultsObserving

    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let result = result as? SNClassificationResult else { return }
        queue.async { [weak self] in self?.handle(result) }
    }

    private func handle(_ result: SNClassificationResult) {
        let time = timeOffset + result.timeRange.start.seconds
        func confidence(_ ids: [String]) -> Double {
            ids.compactMap { result.classification(forIdentifier: $0)?.confidence }.map(Double.init).max() ?? 0
        }
        for label in SoundLabel.allCases {
            if confidence(label.identifiers) >= Self.threshold {
                lastAbove[label] = time
                if active.insert(label).inserted {
                    onEvent?(SoundEvent(label: label, phase: .began, time: time))
                }
            } else if active.contains(label), time - (lastAbove[label] ?? time) >= Self.holdSeconds {
                active.remove(label)
                onEvent?(SoundEvent(label: label, phase: .ended, time: lastAbove[label] ?? time))
            }
        }
        let nowMusicOnly = active.contains(.music) && confidence(["speech"]) < Self.speechCeiling
        if nowMusicOnly != musicOnly {
            musicOnly = nowMusicOnly
            onMusicOnlyChange?(nowMusicOnly)
        }
    }

    private static func copy(_ source: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: source.frameLength) else { return nil }
        copy.frameLength = source.frameLength
        let from = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: source.audioBufferList))
        let to = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for (src, dst) in zip(from, to) {
            guard let s = src.mData, let d = dst.mData else { continue }
            memcpy(d, s, Int(min(src.mDataByteSize, dst.mDataByteSize)))
        }
        return copy
    }
}
