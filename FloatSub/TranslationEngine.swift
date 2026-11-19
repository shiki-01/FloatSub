import Foundation
import Translation

/// Translation framework による端末内翻訳。
/// 言語モデルが導入済みなら TranslationSession(installedSource:target:) で SwiftUI 非依存に翻訳できる。
/// 未導入の場合は、SwiftUI の translationTask 経由でダウンロード許可を取る必要がある（CaptureSession が仲介する）。
@MainActor
final class TranslationEngine {
    enum Readiness {
        case ready
        case needsDownload
        case unsupported
    }

    enum EngineError: LocalizedError {
        case notReady
        var errorDescription: String? { "翻訳の準備ができていません" }
    }

    private var session: TranslationSession?
    var isReady: Bool { session != nil }

    /// 言語ペアの導入状況を確認し、導入済みなら翻訳セッションを作成する。
    func prepare(source: Locale.Language, target: Locale.Language) async -> Readiness {
        let status = await LanguageAvailability().status(from: source, to: target)
        switch status {
        case .installed:
            session = TranslationSession(installedSource: source, target: target)
            return .ready
        case .supported:
            session = nil
            return .needsDownload
        case .unsupported:
            session = nil
            return .unsupported
        @unknown default:
            session = nil
            return .unsupported
        }
    }

    /// 確定した文節を 1 件翻訳する。
    func translate(_ text: String) async throws -> String {
        guard let session else { throw EngineError.notReady }
        let response = try await session.translate(text)
        return response.targetText
    }

    func reset() {
        session = nil
    }
}
