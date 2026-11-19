import Foundation

/// 音声の時間軸（取り込んだ音声の累積秒）と、その音声を文字起こしへ渡した実時刻（systemUptime）の対応表。
/// 文字起こし結果の音声範囲から、「その音声がいつ届いたか」を引いて遅延を求めるために使う。
/// 取り込み側の Thread（feed）と結果の受信側から呼ばれるため、ロックで保護する。
final class AudioTimeline: @unchecked Sendable {
    private struct Entry {
        let audioEnd: Double
        let uptime: TimeInterval
    }

    private let lock = NSLock()
    private var entries: [Entry] = []
    private var fedSeconds = 0.0

    /// 音声を流し込んだ時点で呼ぶ。seconds はそのバッファの長さ。
    func recordFed(seconds: Double) {
        lock.lock(); defer { lock.unlock() }
        fedSeconds += seconds
        entries.append(Entry(audioEnd: fedSeconds, uptime: ProcessInfo.processInfo.systemUptime))
        // 結果は数秒遅れで届くため、直近分だけ保持する
        if entries.count > 8000 { entries.removeFirst(2000) }
    }

    /// 指定した音声位置（秒）の音声を流し込んだ時刻。保持範囲外なら nil。
    func uptime(atAudio audioSeconds: Double) -> TimeInterval? {
        lock.lock(); defer { lock.unlock() }
        guard let first = entries.first, let last = entries.last, audioSeconds.isFinite else { return nil }
        if audioSeconds <= first.audioEnd { return first.uptime }
        if audioSeconds >= last.audioEnd { return last.uptime }
        // audioEnd が audioSeconds 以上になる最初の要素を二分探索する
        var low = 0
        var high = entries.count - 1
        while low < high {
            let mid = (low + high) / 2
            if entries[mid].audioEnd >= audioSeconds { high = mid } else { low = mid + 1 }
        }
        return entries[low].uptime
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        entries.removeAll()
        fedSeconds = 0
    }
}

/// 遅延の種類。音声が届いた時刻を起点に、どの段階までの時間かを表す。
enum LatencyKind: String, CaseIterable {
    /// 文字起こしの確定結果が届くまで
    case recognition = "認識（確定）"
    /// 確定した原文の翻訳にかかった時間
    case translation = "翻訳"
    /// 確定した訳を字幕に出すまでの合計
    case caption = "字幕（確定訳）"
}

/// 遅延の集計。直近の標本だけを保持し、平均と最大を返す。メインアクターから使う。
@MainActor
struct LatencyStats {
    private var samples: [LatencyKind: [Double]] = [:]
    private static let keep = 50

    mutating func add(_ kind: LatencyKind, seconds: Double) {
        guard seconds.isFinite, seconds >= 0 else { return }
        var list = samples[kind, default: []]
        list.append(seconds)
        if list.count > Self.keep { list.removeFirst(list.count - Self.keep) }
        samples[kind] = list
    }

    mutating func reset() { samples.removeAll() }

    /// 画面表示用の要約（種類ごとに 1 行）。標本がなければ空文字。
    var summary: String {
        LatencyKind.allCases.compactMap { kind -> String? in
            guard let list = samples[kind], !list.isEmpty else { return nil }
            let mean = list.reduce(0, +) / Double(list.count)
            let maxValue = list.max() ?? 0
            return "\(kind.rawValue): 平均 \(String(format: "%.2f", mean)) 秒 / 最大 \(String(format: "%.2f", maxValue)) 秒（直近 \(list.count) 件）"
        }.joined(separator: "\n")
    }
}
