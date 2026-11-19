import Foundation
import Speech
import Translation
import Observation

struct LanguageOption: Identifiable, Hashable {
    let id: String
    let name: String
}

/// 言語選択の候補。端末が実際に対応している言語を実行時に取得する。
/// 原語は SpeechTranscriber が対応するロケールのうち、選択中の翻訳先へ翻訳できるものに絞る。
@MainActor
@Observable
final class LanguageOptions {
    static let fallbackSources = [
        LanguageOption(id: "en-US", name: "English (US)"),
        LanguageOption(id: "en-GB", name: "English (UK)"),
    ]
    static let fallbackTargets = [
        LanguageOption(id: "ja", name: "日本語"),
        LanguageOption(id: "en", name: "English"),
    ]

    var sources = LanguageOptions.fallbackSources
    var targets = LanguageOptions.fallbackTargets

    /// 翻訳先の候補（Translation framework が対応する言語）を取得する。
    func loadTargets() async {
        let languages = await LanguageAvailability().supportedLanguages
        var seen = Set<String>()
        var options: [LanguageOption] = []
        for language in languages {
            let id = language.minimalIdentifier
            guard seen.insert(id).inserted else { continue }
            options.append(LanguageOption(id: id, name: Locale.current.localizedString(forIdentifier: id) ?? id))
        }
        options.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if !options.isEmpty { targets = options }
    }

    /// 原語の候補を取得する。翻訳先へ翻訳できないロケールは除く。
    func loadSources(target: String) async {
        let locales = await SpeechTranscriber.supportedLocales
        let availability = LanguageAvailability()
        let targetLanguage = Locale.Language(identifier: target)
        var options: [LanguageOption] = []
        for locale in locales {
            let id = locale.identifier(.bcp47)
            let status = await availability.status(from: locale.language, to: targetLanguage)
            if status == .unsupported { continue }
            options.append(LanguageOption(id: id, name: Locale.current.localizedString(forIdentifier: id) ?? id))
        }
        options.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if !options.isEmpty { sources = options }
    }
}
