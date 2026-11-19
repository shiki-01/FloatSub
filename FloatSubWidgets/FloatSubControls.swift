import WidgetKit
import SwiftUI
import AppIntents

/// コントロールセンターのボタン（画面共有）。FloatSub を開き、開始操作の手前まで進める。
struct FloatSubScreenControl: ControlWidget {
    static let kind = "FloatSubScreenControl"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: OpenFloatSubForScreenIntent()) {
                Label("FloatSub", systemImage: "captions.bubble.fill")
            }
        }
        .displayName("FloatSub")
        .description("FloatSub を開き、画面共有の開始の手前まで進めます。")
    }
}

/// コントロールセンターのボタン（マイク）。FloatSub を開き、マイクの取り込みを開始する。
struct FloatSubMicrophoneControl: ControlWidget {
    static let kind = "FloatSubMicrophoneControl"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: StartFloatSubMicrophoneIntent()) {
                Label("FloatSub マイク", systemImage: "captions.bubble")
            }
        }
        .displayName("FloatSub マイク")
        .description("FloatSub を開き、マイクの文字起こしと翻訳を開始します。")
    }
}

@main
struct FloatSubWidgetBundle: WidgetBundle {
    var body: some Widget {
        FloatSubScreenControl()
        FloatSubMicrophoneControl()
    }
}
