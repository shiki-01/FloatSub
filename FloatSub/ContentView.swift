import SwiftUI
import ReplayKit
import Translation

struct ContentView: View {
    @State private var session = CaptureSession()
    @State private var options = LanguageOptions()
    @State private var probeReport = ""
    @State private var exportContent = ExportContent.both
    @State private var shareItem: ShareItem?
    @State private var confirmClear = false
    @State private var exportError = ""

    var body: some View {
        NavigationStack {
            List {
                controlSection
                inputSection
                if session.captureSource == .microphone { liveSubtitleSection }
                languageSection
                glossarySection
                subtitleSection
                pipSection
                historySection
                transcriptSection
                detailSection
            }
            .navigationTitle("FloatSub")
            .onAppear {
                session.pip.prepare()
                session.applySubtitleStyle()
            }
            .task {
                await options.loadTargets()
                await options.loadSources(target: session.targetLanguageIdentifier)
                fixSelection()
            }
            // 設定の保存と、字幕の見た目の反映
            .onChange(of: session.settingsSnapshot) {
                session.saveSettings()
                session.applySubtitleStyle()
                session.updateGlossary()
            }
            // 翻訳先を変えたら、翻訳できる原語だけに絞り直す
            .onChange(of: session.targetLanguageIdentifier) {
                Task {
                    await options.loadSources(target: session.targetLanguageIdentifier)
                    fixSelection()
                }
            }
            .sheet(item: $shareItem) { item in ShareSheet(url: item.url) }
            .confirmationDialog("履歴をすべて削除しますか？", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("すべて削除", role: .destructive) { session.clearHistory() }
            } message: {
                Text("文字起こしと訳の履歴を削除します。元に戻せません。")
            }
            // マイクの権限がないとき、設定アプリへの案内を出す
            .alert("マイクを使用できません", isPresented: $session.microphoneDenied) {
                Button("設定を開く") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
                Button("閉じる", role: .cancel) {}
            } message: {
                Text("マイクの音声を文字起こしするには、設定アプリの FloatSub でマイクを許可してください。音声は端末内で処理され、外部へは送信されません。")
            }
            // 言語モデルが未導入のとき、システムのダウンロード確認を出すために必要
            .translationTask(session.translationConfiguration) { translationSession in
                await session.handleDownload(translationSession)
            }
        }
    }

    // MARK: - セクション

    private var controlSection: some View {
        Section {
            Button {
                Task { session.isRunning ? await session.stop() : await session.start() }
            } label: {
                Label(session.isRunning ? "停止" : "開始",
                      systemImage: session.isRunning ? "stop.circle.fill" : "play.circle.fill")
                    .font(.headline)
            }
            .tint(session.isRunning ? .red : .accentColor)
            LabeledContent("状態", value: session.captureStatus)
            LabeledContent("翻訳", value: session.translationStatus)
            if session.captureSource == .replayKit, session.isRunning {
                BroadcastStartButton()
            }
            if !session.isRunning {
                Text(startHint)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// 取り込み元の選択。実行中は変更できない。
    private var inputSection: some View {
        Section("入力") {
            Picker("取り込み元", selection: $session.captureSource) {
                ForEach(CaptureSource.available) { Text($0.title).tag($0) }
            }
            .disabled(session.isRunning)
        }
    }

    /// マイク使用時の字幕。PiP を使わず、アプリ内だけで字幕を見られるようにする。
    private var liveSubtitleSection: some View {
        Section("字幕") {
            VStack(alignment: .leading, spacing: 8) {
                if session.showOriginal, !session.displayOriginal.isEmpty {
                    Text(session.displayOriginal)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Text(session.displayTranslation.isEmpty ? "字幕を待っています" : session.displayTranslation)
                    .font(.system(size: 22 * session.fontScale, weight: .bold))
                    .foregroundStyle(session.displayTranslation.isEmpty ? .secondary : .primary)
                    .opacity(session.displayIsProvisional ? 0.5 : 1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    private var startHint: String {
        switch session.captureSource {
        case .microphone:
            "開始するとマイクの音声を文字起こしし、翻訳を上の「字幕」に表示します。他のアプリへ切り替えると、字幕は PiP の小窓に表示されます。初回はマイクの許可を求められます。"
        case .screenCaptureKit:
            "開始すると共有ピッカーが開きます。画面全体の共有を開始し、YouTube などで音声を再生してください。字幕は PiP の小窓に表示されます。"
        case .replayKit:
            "開始後に「画面収録（音声取り込み）」を押し、FloatSub Broadcast を選んでください。"
        }
    }

    private var languageSection: some View {
        Section("言語") {
            Picker("原語", selection: $session.localeIdentifier) {
                ForEach(options.sources) { Text($0.name).tag($0.id) }
            }
            Picker("翻訳先", selection: $session.targetLanguageIdentifier) {
                ForEach(options.targets) { Text($0.name).tag($0.id) }
            }
        }
        .disabled(session.isRunning)
    }

    private var glossarySection: some View {
        Section {
            NavigationLink {
                GlossaryView(session: session)
            } label: {
                LabeledContent("用語の登録", value: "\(session.glossary.count) 件")
            }
        } footer: {
            Text("固有名詞や専門用語を登録すると、文字起こしの精度が上がります。")
        }
    }

    private var subtitleSection: some View {
        Section("字幕の表示") {
            Toggle("原文を表示", isOn: $session.showOriginal)
            Toggle("話している途中の原文も表示", isOn: $session.showLiveOriginal)
                .disabled(!session.showOriginal)
            Toggle("暫定訳を表示（薄く表示）", isOn: $session.showProvisional)
            Picker("文字サイズ", selection: $session.fontScale) {
                Text("小").tag(0.8)
                Text("標準").tag(1.0)
                Text("大").tag(1.2)
                Text("特大").tag(1.4)
            }
            .pickerStyle(.segmented)
        }
    }

    private var pipSection: some View {
        Section {
            PiPLayerView(controller: session.pip)
                .aspectRatio(SubtitleRenderer.size.width / SubtitleRenderer.size.height, contentMode: .fit)
                .listRowInsets(EdgeInsets())
            LabeledContent("状態", value: session.pip.status)
            Button(session.pip.isActive ? "PiP を終了" : "PiP を開始") {
                session.pip.isActive ? session.pip.stop() : session.pip.start()
            }
            .disabled(!session.pip.isPossible && !session.pip.isActive)
        } header: {
            Text("字幕 PiP")
        } footer: {
            Text("iOS の PiP は同時に 1 つだけです。YouTube など他アプリの PiP が開いている間は、字幕の PiP を表示できません。")
        }
    }

    private var historySection: some View {
        Section {
            Picker("書き出す内容", selection: $exportContent) {
                ForEach(ExportContent.allCases) { Text($0.title).tag($0) }
            }
            Button("テキストで書き出す", systemImage: "square.and.arrow.up") { export(srt: false) }
            Button("SRT で書き出す", systemImage: "captions.bubble") { export(srt: true) }
            Button("履歴をすべて削除", systemImage: "trash", role: .destructive) { confirmClear = true }
            if !exportError.isEmpty { Text(exportError).font(.footnote).foregroundStyle(.red) }
        } header: {
            Text("履歴（\(session.segments.count) 件）")
        } footer: {
            Text("履歴は端末のメモリ上だけに保持され、アプリを終了すると消えます。時刻は、取り込んだ音声の開始からの経過時間です。")
        }
        .disabled(session.segments.isEmpty)
    }

    /// 履歴をファイルにして共有シートを開く。
    private func export(srt: Bool) {
        exportError = ""
        let body = srt ? HistoryExporter.srt(session.segments, content: exportContent)
                       : HistoryExporter.text(session.segments, content: exportContent)
        do {
            shareItem = ShareItem(url: try HistoryExporter.writeTemporaryFile(body, fileExtension: srt ? "srt" : "txt"))
        } catch {
            exportError = "書き出しに失敗しました: \(error.localizedDescription)"
        }
    }

    private var transcriptSection: some View {
        Section("文字起こしと日本語訳") {
            if !session.volatileText.isEmpty {
                Text(session.volatileText).foregroundStyle(.secondary).opacity(0.6)
            }
            // 新しい順に表示する
            ForEach(session.segments.reversed()) { segment in
                VStack(alignment: .leading, spacing: 4) {
                    Text(segment.text).foregroundStyle(.secondary)
                    Text(segment.translation ?? segment.provisionalTranslation ?? "（翻訳待ち）")
                        .font(.headline)
                        .opacity(segment.translation == nil ? 0.5 : 1)
                }
            }
        }
    }

    private var detailSection: some View {
        Section {
            DisclosureGroup("詳細（取り込み方式・診断・ログ）") {
                if session.captureSource == .replayKit {
                    LabeledContent("拡張の接続", value: session.extensionConnected ? "接続中" : "未接続")
                }
                LabeledContent("受信バッファ数", value: "\(session.receivedBuffers)")
                LabeledContent("サンプルレート", value: String(format: "%.0f Hz", session.receivedSampleRate))
                ProgressView(value: min(Double(session.level) * 8, 1)) { Text("音声レベル (RMS)") }
                if !session.latencySummary.isEmpty {
                    Text("音声から字幕までの遅延")
                    Text(session.latencySummary).font(.caption.monospaced()).textSelection(.enabled)
                }

                #if SCK_PROBE && canImport(ScreenCaptureKit)
                Button("ScreenCaptureKit 検証（30 秒）") {
                    Task { probeReport = await SCKProbe().run() }
                }
                if !probeReport.isEmpty { Text(probeReport).font(.caption.monospaced()) }
                #endif

                ForEach(Array(session.logs.enumerated()), id: \.offset) {
                    Text($0.element).font(.caption.monospaced())
                }
            }
        }
    }

    /// 選択中の言語が候補にないとき、先頭の候補へ切り替える。
    private func fixSelection() {
        if !options.sources.contains(where: { $0.id == session.localeIdentifier }), let first = options.sources.first {
            session.localeIdentifier = first.id
        }
        if !options.targets.contains(where: { $0.id == session.targetLanguageIdentifier }), let first = options.targets.first {
            session.targetLanguageIdentifier = first.id
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
            Button("画面収録（音声取り込み）を開始") { trigger += 1 }
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
