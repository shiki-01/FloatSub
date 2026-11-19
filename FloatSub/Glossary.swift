import SwiftUI

/// 置換をかける対象。
enum GlossaryTarget: String, Codable, CaseIterable, Identifiable {
    case transcript
    case translation
    case both

    var id: String { rawValue }
    var title: String {
        switch self {
        case .transcript: "文字起こし"
        case .translation: "翻訳文"
        case .both: "両方"
        }
    }
}

/// 用語の登録 1 件。from に一致した語を to へ置き換える。
/// SpeechTranscriber（長文用）は contextual strings を使えないため、確定した文字起こしと翻訳文への置換で認識と訳を揃える。
struct GlossaryEntry: Codable, Identifiable, Equatable {
    var id = UUID()
    var from: String
    var to: String
    var target: GlossaryTarget = .both
}

/// 用語の置換規則。Foundation だけに依存する。
enum GlossaryRules {
    /// 登録数と 1 語の長さの上限
    static let maxEntries = 200
    static let maxLength = 100

    private static func isASCIIWordCharacter(_ c: Character) -> Bool {
        c.isASCII && (c.isLetter || c.isNumber)
    }

    /// text へ、対象に該当する登録を適用する。長い語を先に置換し、置換後の文字列は再置換しない。
    /// 英数字で始まる・終わる語は、前後が英数字でない場合にだけ一致させる（"AI" が "MAIN" の中で置換されない）。
    /// 大文字小文字は区別しない。
    static func apply(_ text: String, entries: [GlossaryEntry], target: GlossaryTarget) -> String {
        let active = entries
            .filter { !$0.from.isEmpty && ($0.target == target || $0.target == .both) }
            .sorted { $0.from.count > $1.from.count }
        guard !active.isEmpty, !text.isEmpty else { return text }

        // 1 回の走査で置換する（置換結果が別の登録に再び一致するのを防ぐ）
        let patterns = active.map { entry -> String in
            var pattern = NSRegularExpression.escapedPattern(for: entry.from)
            if let first = entry.from.first, isASCIIWordCharacter(first) { pattern = "(?<![A-Za-z0-9])" + pattern }
            if let last = entry.from.last, isASCIIWordCharacter(last) { pattern += "(?![A-Za-z0-9])" }
            return "(" + pattern + ")"
        }
        guard let regex = try? NSRegularExpression(pattern: patterns.joined(separator: "|"), options: [.caseInsensitive]) else {
            return text
        }
        let ns = text as NSString
        var result = ""
        var location = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: location, length: match.range.location - location))
            // どの選択肢に一致したか（キャプチャグループの番号）で置換先を決める
            var replacement = ns.substring(with: match.range)
            for (index, entry) in active.enumerated() where match.range(at: index + 1).location != NSNotFound {
                replacement = entry.to
                break
            }
            result += replacement
            location = match.range.location + match.range.length
        }
        result += ns.substring(from: location)
        return result
    }

    /// 入力を整えて追加する。空の語、同じ語・同じ対象の重複、上限を超える分は追加しない。
    static func adding(from: String, to: String, target: GlossaryTarget, entries: [GlossaryEntry]) -> [GlossaryEntry] {
        let from = String(from.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxLength))
        let to = String(to.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxLength))
        guard !from.isEmpty, entries.count < maxEntries else { return entries }
        var result = entries
        if let index = result.firstIndex(where: { $0.from.caseInsensitiveCompare(from) == .orderedSame && $0.target == target }) {
            result[index].to = to
        } else {
            result.append(GlossaryEntry(from: from, to: to, target: target))
        }
        return result
    }
}

/// 用語の登録画面。変更は CaptureSession.glossary に反映され、設定として保存される。
struct GlossaryView: View {
    @Bindable var session: CaptureSession
    @State private var from = ""
    @State private var to = ""
    @State private var target = GlossaryTarget.both

    var body: some View {
        List {
            Section {
                TextField("置き換えられる語（例: open ai）", text: $from)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("置き換え後の語（例: OpenAI）", text: $to)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Picker("対象", selection: $target) {
                    ForEach(GlossaryTarget.allCases) { Text($0.title).tag($0) }
                }
                Button("追加", action: add)
                    .disabled(from.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || session.glossary.count >= GlossaryRules.maxEntries)
            } footer: {
                Text("確定した文字起こしや翻訳文の中で、左の語を右の語へ置き換えます。大文字小文字は区別しません。例: 文字起こしの「open ai」を「OpenAI」へ、翻訳文の「オープンエーアイ」を「OpenAI」へ。登録は \(GlossaryRules.maxEntries) 件までです。")
            }
            Section("登録済み（\(session.glossary.count) 件）") {
                ForEach(session.glossary) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(entry.from) → \(entry.to.isEmpty ? "（削除）" : entry.to)")
                        Text(entry.target.title).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .onDelete { session.glossary.remove(atOffsets: $0) }
            }
        }
        .navigationTitle("用語の登録")
        .toolbar { EditButton() }
    }

    private func add() {
        session.glossary = GlossaryRules.adding(from: from, to: to, target: target, entries: session.glossary)
        from = ""
        to = ""
    }
}
