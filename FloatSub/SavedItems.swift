import SwiftUI
import Observation

/// 保存した単語または文。
struct SavedItem: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case word, sentence }

    var id = UUID()
    var kind: Kind
    /// 単語または文の原文
    var text: String
    /// 日本語訳（文の場合は訳文。単語は未翻訳のため空のことがある）
    var translation: String
    /// 単語を含んでいた文（単語のみ）
    var context: String
    var savedAt = Date()
}

/// 保存した単語・文の一覧。端末内の JSON ファイルへ保存する。
@MainActor
@Observable
final class SavedItemStore {
    private(set) var items: [SavedItem] = []

    private static var fileURL: URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true)) ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("saved_items.json")
    }

    init() {
        if let data = try? Data(contentsOf: Self.fileURL),
           let decoded = try? JSONDecoder().decode([SavedItem].self, from: data) {
            items = decoded
        }
    }

    /// 同じ種別・同じ原文がすでにあれば追加しない。追加したら true。
    @discardableResult
    func add(kind: SavedItem.Kind, text: String, translation: String, context: String = "") -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !items.contains(where: { $0.kind == kind && $0.text.caseInsensitiveCompare(trimmed) == .orderedSame })
        else { return false }
        items.insert(SavedItem(kind: kind, text: trimmed, translation: translation, context: context), at: 0)
        save()
        return true
    }

    func contains(kind: SavedItem.Kind, text: String) -> Bool {
        items.contains { $0.kind == kind && $0.text.caseInsensitiveCompare(text) == .orderedSame }
    }

    func remove(ids: [UUID]) {
        items.removeAll { ids.contains($0.id) }
        save()
    }

    func removeAll() {
        items.removeAll()
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: Self.fileURL, options: .atomic)
    }

    /// 文から、保存の候補にする単語を取り出す（記号を除き、重複と 1 文字の語を除く）。
    static func words(in sentence: String) -> [String] {
        var seen = Set<String>()
        return sentence
            .components(separatedBy: CharacterSet.letters.union(CharacterSet(charactersIn: "'’-")).inverted)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "'’-")) }
            .filter { $0.count > 1 && seen.insert($0.lowercased()).inserted }
    }
}

/// 保存した項目の一覧画面。単語と文を切り替えて見返し、削除できる。
struct SavedItemsView: View {
    var store: SavedItemStore
    @State private var filter = SavedItem.Kind.word
    @State private var confirmClear = false

    private var shown: [SavedItem] { store.items.filter { $0.kind == filter } }

    var body: some View {
        List {
            Picker("種別", selection: $filter) {
                Text("単語").tag(SavedItem.Kind.word)
                Text("文").tag(SavedItem.Kind.sentence)
            }
            .pickerStyle(.segmented)
            if shown.isEmpty {
                Text("保存した\(filter == .word ? "単語" : "文")はありません。履歴の項目を長押しして保存できます。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(shown) { item in
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.text).font(.headline)
                    if !item.translation.isEmpty { Text(item.translation) }
                    if !item.context.isEmpty {
                        Text(item.context).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .onDelete { offsets in store.remove(ids: offsets.map { shown[$0].id }) }
        }
        .navigationTitle("保存した項目（\(store.items.count)）")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { EditButton() }
            ToolbarItem(placement: .bottomBar) {
                Button("すべて削除", role: .destructive) { confirmClear = true }.disabled(store.items.isEmpty)
            }
        }
        .confirmationDialog("保存した項目をすべて削除しますか？", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("すべて削除", role: .destructive) { store.removeAll() }
        }
    }
}

/// 履歴の 1 文から、単語を選んで保存する画面。
struct WordPickerView: View {
    let segment: TranscriptSegment
    var store: SavedItemStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(segment.text)
                    if let translation = segment.translation { Text(translation).foregroundStyle(.secondary) }
                }
                Section("単語を選んで保存") {
                    ForEach(SavedItemStore.words(in: segment.text), id: \.self) { word in
                        Button {
                            store.add(kind: .word, text: word, translation: "", context: segment.text)
                        } label: {
                            HStack {
                                Text(word)
                                Spacer()
                                if store.contains(kind: .word, text: word) { Image(systemName: "checkmark").foregroundStyle(.green) }
                            }
                        }
                    }
                }
            }
            .navigationTitle("単語の保存")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完了") { dismiss() } } }
        }
    }
}
