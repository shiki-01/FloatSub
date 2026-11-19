import AppIntents
import Foundation

/// コントロールセンターのボタンから本体へ渡す、開始の依頼。
/// App Group の UserDefaults を介して渡す（インテントの実行場所が本体でも拡張でも届く）。
enum FloatSubLaunchRequest: String {
    /// 画面共有: 共有ピッカーは本体の画面からしか開けないため、開始操作の手前まで案内する
    case screen
    /// マイク: ピッカーが不要なため、本体を開いてそのまま開始する
    case microphone

    private static let key = "launchRequest"

    private static var defaults: UserDefaults? {
        guard let id = Bundle.main.object(forInfoDictionaryKey: "AppGroupID") as? String else { return nil }
        return UserDefaults(suiteName: id)
    }

    static func post(_ request: FloatSubLaunchRequest) {
        defaults?.set(request.rawValue, forKey: key)
    }

    /// 保留中の依頼を取り出す（取り出すと消える）。
    static func take() -> FloatSubLaunchRequest? {
        guard let raw = defaults?.string(forKey: key) else { return nil }
        defaults?.removeObject(forKey: key)
        return FloatSubLaunchRequest(rawValue: raw)
    }
}

/// FloatSub を開き、画面共有の開始操作の手前まで進める。
struct OpenFloatSubForScreenIntent: AppIntent {
    static let title: LocalizedStringResource = "FloatSub を開く（画面共有）"
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        FloatSubLaunchRequest.post(.screen)
        return .result()
    }
}

/// FloatSub を開き、マイクの取り込みを開始する。
/// 音声セッションの有効化は前面のアプリでしか行えないため、コントロール単体（バックグラウンド）では開始・停止できない。
struct StartFloatSubMicrophoneIntent: AppIntent {
    static let title: LocalizedStringResource = "FloatSub を開く（マイク）"
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        FloatSubLaunchRequest.post(.microphone)
        return .result()
    }
}
