import SwiftUI
import ReplayKit
import Translation

struct ContentView: View {
    @State private var session = CaptureSession()
    @State private var probeReport = ""

    private var startTitle: String {
        session.captureSource == .replayKit ? "1. 受信と文字起こしを開始" : "開始（共有対象を選択）"
    }

    var body: some View {
        NavigationStack {
            List {
                Section("操作") {
                    Picker("原語", selection: $session.localeIdentifier) {
                        Text("English (US)").tag("en-US")
                        Text("English (UK)").tag("en-GB")
                    }
                    .disabled(session.isRunning)
                    Picker("取り込み方式", selection: $session.captureSource) {
                        ForEach(CaptureSource.available) { Text($0.title).tag($0) }
                    }
                    .disabled(session.isRunning)
                    Button(session.isRunning ? "停止" : startTitle) {
                        Task { session.isRunning ? await session.stop() : await session.start() }
                    }
                    if session.captureSource == .replayKit {
                        BroadcastStartButton()
                            .disabled(!session.isRunning)
                    } else if !session.isRunning {
                        Text("開始すると共有ピッカーが開きます。画面全体の共有を開始し、YouTube などで音声を再生してください。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("字幕 PiP") {
                    PiPLayerView(controller: session.pip)
                        .aspectRatio(SubtitleRenderer.size.width / SubtitleRenderer.size.height, contentMode: .fit)
                        .listRowInsets(EdgeInsets())
                    LabeledContent("状態", value: session.pip.status)
                    Button(session.pip.isActive ? "PiP を終了" : "PiP を開始") {
                        session.pip.isActive ? session.pip.stop() : session.pip.start()
                    }
                    .disabled(!session.pip.isPossible && !session.pip.isActive)
                }

                Section("取り込み診断") {
                    LabeledContent("取り込み状態", value: session.captureStatus)
                    if session.captureSource == .replayKit {
                        LabeledContent("拡張の接続", value: session.extensionConnected ? "接続中" : "未接続")
                    }
                    LabeledContent("受信バッファ数", value: "\(session.receivedBuffers)")
                    LabeledContent("サンプルレート", value: String(format: "%.0f Hz", session.receivedSampleRate))
                    ProgressView(value: min(Double(session.level) * 8, 1)) { Text("音声レベル (RMS)") }
                }

                Section("文字起こしと日本語訳") {
                    LabeledContent("翻訳", value: session.translationStatus)
                    ForEach(session.segments) { segment in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(segment.text).foregroundStyle(.secondary)
                            Text(segment.translation ?? "（翻訳待ち）")
                                .font(.headline)
                        }
                    }
                    if !session.volatileText.isEmpty {
                        Text(session.volatileText).foregroundStyle(.secondary)
                    }
                }

                #if SCK_PROBE && canImport(ScreenCaptureKit)
                Section("ScreenCaptureKit 検証") {
                    Button("ピッカーを開き 30 秒間の音声取得を試行") {
                        Task { probeReport = await SCKProbe().run() }
                    }
                    if !probeReport.isEmpty { Text(probeReport).font(.caption.monospaced()) }
                }
                #endif

                Section("ログ") {
                    ForEach(Array(session.logs.enumerated()), id: \.offset) {
                        Text($0.element).font(.caption.monospaced())
                    }
                }
            }
            .navigationTitle("FloatSub")
            .onAppear { session.pip.prepare() }
            // 言語モデルが未導入のとき、システムのダウンロード確認を出すために必要
            .translationTask(session.translationConfiguration) { translationSession in
                await session.handleDownload(translationSession)
            }
        }
    }
}

/// RPSystemBroadcastPickerView を SwiftUI のボタンから起動する。
/// 標準のピッカーは小さなアイコンのため、内部の UIButton を押下して拡張選択シートを開く。
struct BroadcastStartButton: View {
    @State private var trigger = 0

    var body: some View {
        ZStack {
            BroadcastPicker(trigger: trigger).frame(width: 1, height: 1).opacity(0.01)
            Button("2. 画面収録（音声取り込み）を開始") { trigger += 1 }
        }
    }
}

private struct BroadcastPicker: UIViewRepresentable {
    let trigger: Int

    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let picker = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
        picker.preferredExtension = Bundle.main.object(forInfoDictionaryKey: "BroadcastExtensionID") as? String
        picker.showsMicrophoneButton = false
        return picker
    }

    func updateUIView(_ picker: RPSystemBroadcastPickerView, context: Context) {
        guard trigger > 0, context.coordinator.last != trigger else { return }
        context.coordinator.last = trigger
        (picker.subviews.compactMap { $0 as? UIButton }.first)?.sendActions(for: .touchUpInside)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var last = 0 }
}
