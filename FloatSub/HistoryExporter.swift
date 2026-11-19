import Foundation
import SwiftUI
import UIKit

/// 書き出しに含める内容。
enum ExportContent: String, CaseIterable, Identifiable {
    case both
    case translation
    case original

    var id: String { rawValue }
    var title: String {
        switch self {
        case .both: "原文と訳"
        case .translation: "訳のみ"
        case .original: "原文のみ"
        }
    }
}

/// 文字起こし履歴のテキスト・SRT への変換。Foundation だけに依存する。
/// 時刻は、取り込んだ音声の累積時間（開始からの経過）。
enum HistoryExporter {
    /// 1 件の字幕として出す行。訳が未完了の文節は原文だけを出す。
    private static func lines(_ segment: TranscriptSegment, content: ExportContent) -> [String] {
        var result = plainLines(segment, content: content)
        // 話者ラベルは先頭の行に付ける
        if segment.kind == .speech, let speaker = segment.speaker, !result.isEmpty { result[0] = "\(speaker): \(result[0])" }
        return result
    }

    private static func plainLines(_ segment: TranscriptSegment, content: ExportContent) -> [String] {
        if segment.kind == .sound { return [segment.text] }
        let translation = segment.translation?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch content {
        case .both: return [translation, segment.text].filter { !$0.isEmpty }
        case .translation: return [translation.isEmpty ? segment.text : translation]
        case .original: return [segment.text]
        }
    }

    /// 経過秒を "hh:mm:ss"（SRT は "hh:mm:ss,mmm"）にする。
    static func timestamp(_ seconds: Double, srt: Bool) -> String {
        let clamped = max(0, seconds.isFinite ? seconds : 0)
        let totalMillis = Int((clamped * 1000).rounded())
        let h = totalMillis / 3_600_000
        let m = totalMillis / 60_000 % 60
        let s = totalMillis / 1000 % 60
        let ms = totalMillis % 1000
        let base = String(format: "%02d:%02d:%02d", h, m, s)
        return srt ? base + String(format: ",%03d", ms) : base
    }

    /// テキスト形式。各文節を「[hh:mm:ss] 本文」で並べ、文節の間に空行を入れる。
    static func text(_ segments: [TranscriptSegment], content: ExportContent) -> String {
        segments.map { segment in
            let body = lines(segment, content: content)
            guard let first = body.first else { return "" }
            let head = "[\(timestamp(segment.audioStart, srt: false))] \(first)"
            return ([head] + body.dropFirst()).joined(separator: "\n")
        }
        .filter { !$0.isEmpty }
        .joined(separator: "\n\n") + "\n"
    }

    /// SRT 形式。表示時間が短すぎる・次の字幕と重なる場合は補正する。
    static func srt(_ segments: [TranscriptSegment], content: ExportContent) -> String {
        let minDuration = 1.0
        var blocks: [String] = []
        for (i, segment) in segments.enumerated() {
            let body = lines(segment, content: content)
            guard !body.isEmpty else { continue }
            let start = max(0, segment.audioStart)
            var end = max(segment.audioEnd, start + minDuration)
            if i + 1 < segments.count {
                // 次の字幕の開始までに収める（ただし最短の表示時間は確保する）
                let next = segments[i + 1].audioStart
                if next > start + 0.2 { end = min(end, max(next, start + 0.2)) }
            }
            blocks.append("\(blocks.count + 1)\n\(timestamp(start, srt: true)) --> \(timestamp(end, srt: true))\n" + body.joined(separator: "\n"))
        }
        return blocks.joined(separator: "\n\n") + "\n"
    }

    /// 一時ファイルへ書き出し、その URL を返す。ファイル名は共有先で分かるよう日時を含める。
    static func writeTemporaryFile(_ contents: String, fileExtension: String) throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: Date())
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("FloatSub-\(stamp).\(fileExtension)")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// 書き出しで作った一時ファイルをすべて消す。
    static func removeTemporaryFiles() {
        let dir = FileManager.default.temporaryDirectory
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.lastPathComponent.hasPrefix("FloatSub-") {
            try? FileManager.default.removeItem(at: file)
        }
    }
}

/// 共有シートへ渡すファイル。
struct ShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

/// UIActivityViewController の SwiftUI ラッパー。閉じたときに一時ファイルを消す。
struct ShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in
            try? FileManager.default.removeItem(at: url)
        }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
