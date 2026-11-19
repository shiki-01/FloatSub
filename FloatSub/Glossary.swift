import SwiftUI

/// 用語（固有名詞・専門用語）の登録規則。SpeechAnalyzer の contextual strings に渡す。
enum GlossaryRules {
    /// 登録数と 1 語の長さの上限。contextual strings の一般的な目安に合わせる。
    static let maxTerms = 100
    static let maxLength = 100

    /// 入力欄の文字列を、改行・カンマ・読点で分けて用語にする。
    static func parse(_ input: String) -> [String] {
        input.components(separatedBy: CharacterSet(charactersIn: "\n,、，"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { String($0.prefix(maxLength)) }
    }

    /// 用語を追加する。大文字小文字を区別せず重複を除き、上限を超える分は捨てる。
    static func adding(_ input: String, to terms: [String]) -> [String] {
        var result = terms
        for term in parse(input) where result.count < maxTerms {
            if !result.contains(where: { $0.caseInsensitiveCompare(term) == .orderedSame }) {
                result.append(term)
            }
        }
        return result
    }
}

/// 用語の登録画面。変更は CaptureSession.glossary に反映され、設定として保存される。
struct GlossaryView: View {
    @Bindable var session: CaptureSession
    @State private var input = ""

    var body: some View {
        List {
            Section {
                HStack {
                    TextField("用語（複数は改行かカンマで区切る）", text: $input, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit(add)
                    Button("追加", action: add)
                        .disabled(GlossaryRules.parse(input).isEmpty || session.glossary.count >= GlossaryRules.maxTerms)
                }
            } footer: {
                Text("人名、製品名、専門用語などを登録すると、文字起こしでその綴りが選ばれやすくなります。翻訳は端末の翻訳機能が行うため、訳語は指定できません。登録は \(GlossaryRules.maxTerms) 件までです。")
            }
            Section("登録済み（\(session.glossary.count) 件）") {
                ForEach(session.glossary, id: \.self) { Text($0) }
                    .onDelete { session.glossary.remove(atOffsets: $0) }
            }
        }
        .navigationTitle("用語の登録")
        .toolbar { EditButton() }
    }

    private func add() {
        session.glossary = GlossaryRules.adding(input, to: session.glossary)
        input = ""
    }
}
