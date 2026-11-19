import SwiftUI
import ReplayKit
import Translation
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var session = CaptureSession()
    @State private var options = LanguageOptions()
    @State private var probeReport = ""
    @State private var exportContent = ExportContent.both
    @State private var shareItem: ShareItem?
    @State private var confirmClear = false
    @State private var exportError = ""
    @State private var showFileImporter = false
    @State private var confirmFileReplace = false
    @State private var showPlayback = false
    @State private var savedItems = SavedItemStore()
    @State private var wordPickerSegment: TranscriptSegment?
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            List {
                controlSection
                inputSection
                fileSection
                if session.captureSource == .microphone { liveSubtitleSection }
                languageSection
                glossarySection
                soundSection
                speakerSection
                subtitleSection
                pipSection
                historySection
                savedSection
                transcriptSection
                detailSection
            }
            .navigationTitle("FloatSub")
            .onAppear {
                session.pip.prepare()
                session.applySubtitleStyle()
            }
            .task {
                // コントロールセンターから起動された場合の依頼（初回起動では scenePhase の変化が来ない）
                await session.consumeLaunchRequests()
            }
            .task {
                await options.loadTargets()
                await options.loadSources(target: session.targetLanguageIdentifier)
                fixSelection()
            }
            // 前面へ戻ったとき、背面や高負荷で滞留した翻訳を再開する
            .onChange(of: scenePhase) {
                if scenePhase == .active {
                    Task { await session.resumeTranslations() }
                    Task { await session.consumeLaunchRequests() }
                }
            }
            // 設定の保存と、字幕の見た目の反映
            .onChange(of: session.settingsSnapshot) {
                session.saveSettings()
                session.applySubtitleStyle()
            }
            // 翻訳先を変えたら、翻訳できる原語だけに絞り直す
            .onChange(of: session.targetLanguageIdentifier) {
                Task {
                    await options.loadSources(target: session.targetLanguageIdentifier)
                    fixSelection()
                }
            }
            .sheet(item: $shareItem) { item in ShareSheet(url: item.url) }
            .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.audio, .movie]) { result in
                if case .success(let url) = result { session.startFileTranscription(url) }
            }
            .confirmationDialog("現在の履歴は、ファイルの結果で置き換えられます", isPresented: $confirmFileReplace, titleVisibility: .visible) {
                Button("置き換えて続ける", role: .destructive) { showFileImporter = true }
            }
            .sheet(isPresented: $showPlayback) {
                if let url = session.playbackURL {
                    FilePlaybackView(url: url, segments: session.segments, style: session.currentStyle)
                }
            }
            .sheet(item: $wordPickerSegment) { segment in WordPickerView(segment: segment, store: savedItems) }
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
            .disabled(session.isTranscribingFile)
            LabeledContent("状態", value: session.captureStatus)
            LabeledContent("翻訳", value: session.translationStatus)
            if session.captureSource == .replayKit, session.isRunning {
                BroadcastStartButton()
            }
            if !session.launchNotice.isEmpty {
                Label(session.launchNotice, systemImage: "captions.bubble.fill")
                    .font(.footnote.bold())
                    .foregroundStyle(Color.accentColor)
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

    /// 音声・動画ファイルの文字起こし。結果は履歴に入り、書き出しも共通。
    private var fileSection: some View {
        Section {
            if session.isTranscribingFile {
                ProgressView(value: session.fileProgress) { Text(session.fileStatus) }
                Button("中止", role: .destructive) { session.cancelFileTranscription() }
            } else {
                Button("ファイルを文字起こし", systemImage: "doc.badge.waveform") {
                    if session.segments.isEmpty { showFileImporter = true } else { confirmFileReplace = true }
                }
                .disabled(session.isRunning)
                if !session.fileStatus.isEmpty { LabeledContent("状態", value: session.fileStatus) }
                if session.playbackURL != nil {
                    Button("字幕付きで再生", systemImage: "play.rectangle") { showPlayback = true }
                }
            }
        } header: {
            Text("ファイル")
        } footer: {
            Text("音声・動画ファイルを端末内で文字起こしし、翻訳します。結果は下の履歴に入り、テキスト・SRT で書き出せます。原語と翻訳先は「言語」の設定を使います。")
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
                    .foregroundStyle(session.displayTranslation.isEmpty ? Color.secondary : Color(uiColor: session.textColor.uiColor))
                    .opacity(session.displayIsProvisional ? 0.5 : 1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
            .listRowBackground(Color(red: 0.05, green: 0.06, blue: 0.09).opacity(session.backgroundOpacity))
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

    private var soundSection: some View {
        Section {
            Toggle("音の認識（笑い・音楽・拍手など）", isOn: $session.soundRecognition)
                .disabled(session.isRunning)
        } footer: {
            Text("オンにすると、笑い声・音楽・拍手・歓声を検出し、「[笑い]」「[音楽]」のように字幕と履歴に出します。音楽だけが鳴っている間は翻訳を控えます。端末内の解析で、次の開始から有効です。")
        }
    }

    private var speakerSection: some View {
        Section {
            Toggle("話者分離（話者1・話者2…）", isOn: $session.speakerDiarization)
                .disabled(session.isRunning)
        } footer: {
            Text("オンにすると、字幕と履歴に「話者1」「話者2」のラベルを付けます。端末内の Core ML モデルで処理しますが、初回の開始時にモデルを外部（huggingface.co）からダウンロードします。誤り率は 20〜30% 程度が目安で、同時に話す場面や話者が多い場面では乱れます。次の開始から有効です。")
        }
    }

    private var glossarySection: some View {
        Section {
            NavigationLink {
                GlossaryView(session: session)
            } label: {
                LabeledContent("用語の登録", value: "\(session.glossary.count) 件")
            }
        } footer: {
            Text("固有名詞や専門用語の表記ゆれを、確定した文字起こしや翻訳文の中で登録した語へ置き換えます。")
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
            Picker("訳の文字色", selection: $session.textColor) {
                ForEach(SubtitleTextColor.allCases) { Text($0.title).tag($0) }
            }
            VStack(alignment: .leading) {
                Text("背景の濃さ（\(Int(session.backgroundOpacity * 100))%）")
                Slider(value: $session.backgroundOpacity, in: 0.3...1.0, step: 0.1)
            }
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

    private var savedSection: some View {
        Section {
            NavigationLink {
                SavedItemsView(store: savedItems)
            } label: {
                LabeledContent("保存した単語・文", value: "\(savedItems.items.count) 件")
            }
        } footer: {
            Text("下の履歴の項目を長押しすると、文や単語を保存できます。")
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
                    Text((segment.speaker.map { "\($0): " } ?? "") + segment.text).foregroundStyle(.secondary)
                    Text(segment.translation ?? segment.provisionalTranslation
                         ?? (segment.isTranslationAbandoned ? "（翻訳できません）" : "（翻訳待ち）"))
                        .font(.headline)
                        .opacity(segment.translation == nil ? 0.5 : 1)
                }
                .contextMenu {
                    if segment.kind == .speech {
                    Button("文を保存", systemImage: "bookmark") {
                        savedItems.add(kind: .sentence, text: segment.text, translation: segment.translation ?? "")
                    }
                    Button("単語を選んで保存", systemImage: "textformat.abc") { wordPickerSegment = segment }
                    }
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
                LabeledContent("端末の熱状態", value: session.thermalStateText)
                LabeledContent("未翻訳の滞留", value: "\(session.pendingTranslationCount) 件")
                if session.abandonedTranslationCount > 0 {
                    LabeledContent("翻訳をあきらめた文節", value: "\(session.abandonedTranslationCount) 件")
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
