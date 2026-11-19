import Foundation

/// 話している途中の文字起こし（volatile）を、確定を待たずに句読点で区切って翻訳へ渡すための判定。
/// 区切った部分（コミット済み）は正規化した文字列（英数字のみ・小文字）で覚え、
/// 以降の途中結果や確定結果から、コミット済みの部分を除いた残りを求める。Foundation だけに依存する。
struct UtteranceChunker {
    /// 文末として区切る記号。ASCII のものは後ろに空白が続くときだけ文末とみなす（"3.5" などを除く）
    private static let asciiTerminators: Set<Character> = [".", "?", "!"]
    private static let wideTerminators: Set<Character> = ["。", "？", "！"]
    /// 句読点で終わらない長い発話を区切る位置（読点・カンマ）
    private static let clauseSeparators: Set<Character> = [",", ";", "、", "，"]
    /// 文末の "." と紛らわしい略語
    private static let abbreviations: Set<String> = [
        "mr", "mrs", "ms", "dr", "prof", "sr", "jr", "st", "vs", "etc", "inc", "ltd", "co", "no", "e.g", "i.e", "u.s",
    ]
    /// 区切る最小の長さ（英数字の数）。これより短い断片は確定結果に任せる
    static let minChunkLength = 6
    /// 無音で区切る最小の長さ（英数字の数）
    static let minPauseChunkLength = 20
    /// 文末記号がなくても、残りがこの長さ（文字数）を超えたら読点で区切る
    static let longRestLength = 140

    /// コミット済みの部分の正規化文字列
    private var committedKey: [Character] = []

    mutating func reset() { committedKey.removeAll() }

    mutating func commit(_ chunk: String) { committedKey += Self.key(of: chunk) }

    /// 英数字だけを小文字で並べた比較用の文字列。
    static func key(of text: String) -> [Character] {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// text のうち、コミット済みの部分を除いた残り。途中で認識が修正されてコミット済みと食い違う場合は、
    /// 一致している範囲までをコミット済みとみなす。
    func rest(of text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !committedKey.isEmpty else { return trimmed }
        let textKey = Self.key(of: trimmed)
        var common = 0
        while common < committedKey.count, common < textKey.count, committedKey[common] == textKey[common] { common += 1 }
        guard common > 0 else { return trimmed }
        // 英数字を common 個ぶん読み進め、その直後の記号・空白も読み飛ばす
        var consumed = 0
        var index = trimmed.startIndex
        while index < trimmed.endIndex, consumed < common {
            consumed += trimmed[index].lowercased().filter { $0.isLetter || $0.isNumber }.count
            index = trimmed.index(after: index)
        }
        while index < trimmed.endIndex, !(trimmed[index].isLetter || trimmed[index].isNumber) {
            index = trimmed.index(after: index)
        }
        return String(trimmed[index...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 残りのうち、文末で終わり、後ろにさらに文字が続く部分（確実に文として閉じた部分）を返す。
    /// 後ろに続きがない文末は、直後に訂正される可能性があるため返さない。
    func readyChunk(in rest: String) -> String? {
        let chars = Array(rest)
        var cut: Int?
        for i in chars.indices.dropLast() {
            let c = chars[i]
            let next = chars[i + 1]
            if Self.wideTerminators.contains(c) {
                cut = i
            } else if Self.asciiTerminators.contains(c), next.isWhitespace {
                if c == ".", Self.isAbbreviation(before: i, in: chars) { continue }
                cut = i
            }
        }
        // 句点がなくても長すぎる残りは、最後の読点で区切る
        if cut == nil, chars.count > Self.longRestLength {
            for i in chars.indices.dropLast() where Self.clauseSeparators.contains(chars[i]) { cut = i }
        }
        guard let cut else { return nil }
        let chunk = String(chars[...cut]).trimmingCharacters(in: .whitespacesAndNewlines)
        return Self.key(of: chunk).count >= Self.minChunkLength ? chunk : nil
    }

    /// 無音が続いたときに、残り全体を 1 つの区切りとして返す。短すぎる場合は nil。
    func pauseChunk(in rest: String) -> String? {
        let trimmed = rest.trimmingCharacters(in: .whitespacesAndNewlines)
        return Self.key(of: trimmed).count >= Self.minPauseChunkLength ? trimmed : nil
    }

    private static func isAbbreviation(before index: Int, in chars: [Character]) -> Bool {
        var start = index
        while start > 0, chars[start - 1].isLetter || chars[start - 1] == "." { start -= 1 }
        let word = String(chars[start..<index]).lowercased()
        // 1 文字の大文字（イニシャル）も略語として扱う
        return abbreviations.contains(word) || (word.count == 1 && word.first?.isLetter == true)
    }
}
