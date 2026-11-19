import Foundation
import AVFoundation
import Observation
import Translation

/// 音声の取り込み方式。実機検証（iOS 27）で ScreenCaptureKit の取得を確認したため、既定は ScreenCaptureKit。
enum CaptureSource: String, CaseIterable, Identifiable {
    case screenCaptureKit
    case replayKit
    case microphone

    var id: String { rawValue }

    var title: String {
        switch self {
        case .screenCaptureKit: "画面共有（ScreenCaptureKit）"
        case .replayKit: "画面共有（ReplayKit 拡張）"
        case .microphone: "マイク"
        }
    }

    /// 現在の SDK で使える方式（ScreenCaptureKit は iOS 27 SDK のみ）
    static var available: [CaptureSource] {
        #if canImport(ScreenCaptureKit)
        [.screenCaptureKit, .replayKit, .microphone]
        #else
        [.replayKit, .microphone]
        #endif
    }

    static var preferred: CaptureSource { available[0] }
}

enum CaptureError: LocalizedError {
    case unsupported
    case microphoneDenied
    var errorDescription: String? {
        switch self {
        case .unsupported: "この SDK では ScreenCaptureKit を利用できません"
        case .microphoneDenied: "マイクの使用が許可されていません"
        }
    }
}

/// 統括。無音再生（実行維持）→ 翻訳準備 → 文字起こし → socket 待受、の順に起動する。
/// 確定した文節ごとに、Translation framework で日本語へ翻訳する。
@MainActor
@Observable
final class CaptureSession {
    var isRunning = false
    var localeIdentifier = "en-US"
    var captureSource = CaptureSource.preferred
    /// 取り込みの状態（画面表示用）
    var captureStatus = "停止"
    var targetLanguageIdentifier = "ja"
    // 字幕の表示設定
    var showOriginal = true
    /// 話している途中の原文（確定前）も PiP に出すか
    var showLiveOriginal = false
    /// 話している途中の訳（暫定訳）を薄く表示するか
    var showProvisional = true
    /// 笑い声・音楽・拍手などの非音声イベントを検出して字幕と履歴に出すか（既定はオフ）
    var soundRecognition = false
    /// 話者を分離して、字幕と履歴に話者ラベルを付けるか（既定はオフ）
    var speakerDiarization = false
    var fontScale = 1.0
    /// 字幕フレームの背景の不透明度と、訳文の文字色
    var backgroundOpacity = 1.0
    var textColor = SubtitleTextColor.white
    /// 話している途中の原文のうち、区切り（履歴へ移した部分）を除いた残り
    var volatileText = ""
    /// アプリ内の字幕表示用（PiP と同じ内容）。マイク使用時など、PiP を使わずに見る場合に使う
    var displayOriginal = ""
    var displayTranslation = ""
    /// 表示中の訳が暫定訳（確定前）か
    var displayIsProvisional = false
    /// マイクの権限がないとき true。ContentView が設定アプリへの案内を出す
    var microphoneDenied = false
    /// 登録した用語。確定した文字起こしと翻訳文へ置換をかける
    var glossary: [GlossaryEntry] = []
    var segments: [TranscriptSegment] = []
    var logs: [String] = []
    /// 音声から字幕までの遅延の集計（詳細欄に表示）
    var latencySummary = ""
    /// 端末の熱状態（診断表示用）
    var thermalState = ProcessInfo.processInfo.thermalState
    private var thermalObserver: NSObjectProtocol?
    private var latencyStats = LatencyStats()

    // 取り込み診断（実機での検証用）
    var extensionConnected = false
    var receivedBuffers = 0
    var receivedSampleRate = 0.0
    var level: Float = 0 // 直近バッファの RMS

    // 翻訳
    var translationStatus = "未準備"
    /// 非 nil になると、ContentView の translationTask が言語モデルのダウンロード確認を出す
    var translationConfiguration: TranslationSession.Configuration?

    private let keepAlive = KeepAlive()
    private let receiver = AudioReceiver()
    private let micSource = MicrophoneAudioSource()
    #if canImport(ScreenCaptureKit)
    private let sckSource = SCKAudioSource()
    #endif
    private let engine = TranscriptionEngine()
    private let translator = TranslationEngine()
    /// 字幕の PiP 表示
    let pip = PiPController()
    /// 翻訳処理が動いている間の開始時刻（systemUptime）。nil なら停止中
    private var flushingSince: TimeInterval?
    /// 翻訳処理を作り直すたびに進め、古い処理を打ち切る
    private var flushGeneration = 0
    private var watchdogTask: Task<Void, Never>?
    // 途中結果の処理
    private var chunker = UtteranceChunker()
    private var volatileFull = ""
    private var volatileStart = 0.0
    private var volatileEnd = 0.0
    private var volatileCaptured: TimeInterval?
    /// 現在の残りの先頭にあたる音声位置
    private var restAudioStart: Double?
    // 話者分離
    private var speakerDiarizer: SpeakerDiarizer?
    private var speakerTask: Task<Void, Never>?
    // 非音声イベント
    private var soundDetector: SoundEventDetector?
    /// 字幕に出している非音声イベントの表記（[音楽] など）
    private var soundCaption: String?
    private var soundCaptionTask: Task<Void, Never>?
    /// 検出中のイベントの履歴上の文節
    private var activeSoundSegments: [SoundLabel: UUID] = [:]
    /// 音楽だけが鳴っている間は true。翻訳を抑制する
    private var musicSuppressed = false
    /// コントロールセンターから開いたときの案内（画面共有の開始手前で表示）
    var launchNotice = ""
    // ファイルの文字起こし
    var isTranscribingFile = false
    var fileProgress = 0.0
    var fileStatus = ""
    /// 文字起こしを終えたファイル（アプリ内の再生用に複製したもの）
    var playbackURL: URL?
    private var fileTask: Task<Void, Never>?
    /// ファイルの処理中は、途中結果を使わず確定結果だけを履歴にする
    private var fileMode = false
    private var provisionalTask: Task<Void, Never>?
    private var pauseTask: Task<Void, Never>?
    private var provisionalSource = ""
    private var provisionalTranslation = ""
    /// 区切りや確定のたびに増やし、実行中の暫定訳の結果を捨てる目印にする
    private var provisionalGeneration = 0
    /// 開始処理の多重実行を防ぐ（isRunning は開始完了後に立つため別に持つ）
    private var isStarting = false

    /// 保存対象の設定。変更の検知（onChange）に使う。
    struct SettingsSnapshot: Equatable {
        var locale: String
        var target: String
        var source: CaptureSource
        var showOriginal: Bool
        var showLiveOriginal: Bool
        var showProvisional: Bool
        var soundRecognition: Bool
        var speakerDiarization: Bool
        var fontScale: Double
        var backgroundOpacity: Double
        var textColor: SubtitleTextColor
        var glossary: [GlossaryEntry]
    }

    var settingsSnapshot: SettingsSnapshot {
        SettingsSnapshot(locale: localeIdentifier, target: targetLanguageIdentifier, source: captureSource,
                         showOriginal: showOriginal, showLiveOriginal: showLiveOriginal, showProvisional: showProvisional,
                         soundRecognition: soundRecognition, speakerDiarization: speakerDiarization, fontScale: fontScale, backgroundOpacity: backgroundOpacity, textColor: textColor, glossary: glossary)
    }

    /// 熱状態の表示名
    var thermalStateText: String {
        switch thermalState {
        case .nominal: "正常"
        case .fair: "やや高い"
        case .serious: "高い（暫定訳を停止中）"
        case .critical: "非常に高い（暫定訳を停止中）"
        @unknown default: "不明"
        }
    }

    /// 熱状態が高いときは、負荷の大きい暫定訳を止める。
    private var isThermallyConstrained: Bool {
        thermalState == .serious || thermalState == .critical
    }

    init() {
        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.thermalState = ProcessInfo.processInfo.thermalState
                self.log("端末の熱状態: \(self.thermalStateText)")
                if self.isThermallyConstrained { self.resetProvisional(); self.updatePiP() }
            }
        }
        let d = UserDefaults.standard
        if let v = d.string(forKey: "locale") { localeIdentifier = v }
        if let v = d.string(forKey: "target") { targetLanguageIdentifier = v }
        if let raw = d.string(forKey: "captureSource"), let v = CaptureSource(rawValue: raw),
           CaptureSource.available.contains(v) { captureSource = v }
        if d.object(forKey: "showOriginal") != nil { showOriginal = d.bool(forKey: "showOriginal") }
        showLiveOriginal = d.bool(forKey: "showLiveOriginal")
        soundRecognition = d.bool(forKey: "soundRecognition")
        speakerDiarization = d.bool(forKey: "speakerDiarization")
        if d.object(forKey: "showProvisional") != nil { showProvisional = d.bool(forKey: "showProvisional") }
        if d.object(forKey: "fontScale") != nil { fontScale = d.double(forKey: "fontScale") }
        if d.object(forKey: "backgroundOpacity") != nil { backgroundOpacity = d.double(forKey: "backgroundOpacity") }
        if let raw = d.string(forKey: "textColor"), let v = SubtitleTextColor(rawValue: raw) { textColor = v }
        if let data = d.data(forKey: "glossaryEntries"),
           let entries = try? JSONDecoder().decode([GlossaryEntry].self, from: data) { glossary = entries }
    }

    func saveSettings() {
        let d = UserDefaults.standard
        d.set(localeIdentifier, forKey: "locale")
        d.set(targetLanguageIdentifier, forKey: "target")
        d.set(captureSource.rawValue, forKey: "captureSource")
        d.set(showOriginal, forKey: "showOriginal")
        d.set(showLiveOriginal, forKey: "showLiveOriginal")
        d.set(showProvisional, forKey: "showProvisional")
        d.set(soundRecognition, forKey: "soundRecognition")
        d.set(speakerDiarization, forKey: "speakerDiarization")
        d.set(fontScale, forKey: "fontScale")
        d.set(backgroundOpacity, forKey: "backgroundOpacity")
        d.set(textColor.rawValue, forKey: "textColor")
        if let data = try? JSONEncoder().encode(glossary) { d.set(data, forKey: "glossaryEntries") }
    }

    /// 表示設定を PiP の字幕へ反映する。
    /// 現在の表示設定（アプリ内の再生で使う）
    var currentStyle: SubtitleStyle {
        SubtitleStyle(backgroundOpacity: CGFloat(backgroundOpacity), textColor: textColor,
                      showOriginal: showOriginal, fontScale: CGFloat(fontScale))
    }

    func applySubtitleStyle() {
        pip.apply(style: SubtitleStyle(backgroundOpacity: CGFloat(backgroundOpacity), textColor: textColor,
                                       showOriginal: showOriginal, fontScale: CGFloat(fontScale)))
        // 暫定訳を切ったときは、出ている暫定訳を捨てて確定した字幕へ戻す
        if !showProvisional, displayIsProvisional {
            resetProvisional()
            for i in segments.indices { segments[i].provisionalTranslation = nil }
            updatePiP()
        }
    }

    private var sourceLanguage: Locale.Language {
        Locale(identifier: localeIdentifier).language
    }
    private var targetLanguage: Locale.Language {
        Locale.Language(identifier: targetLanguageIdentifier)
    }

    func start() async {
        guard !isRunning, !isStarting, !isTranscribingFile else { return }
        isStarting = true
        launchNotice = ""
        defer { isStarting = false }
        log("開始処理")
        pip.onLog = { [weak self] msg in self?.log(msg) }
        microphoneDenied = false
        do {
            if captureSource == .microphone {
                // 権限の確認は、音声セッションを変更する前に行う
                guard await ensureMicrophonePermission() else { throw CaptureError.microphoneDenied }
            }
            try keepAlive.start(recording: captureSource == .microphone)
            log("無音再生を開始（実行維持）")

            await prepareTranslation()

            configureEngine()
            latencyStats.reset()
            latencySummary = ""
            try await engine.start(localeIdentifier: localeIdentifier)
            log("文字起こし準備完了 (\(localeIdentifier))")

            if soundRecognition { startSoundDetector() } else { soundDetector = nil }
            await startSpeakerDiarizer()
            let handler = makeBufferHandler()
            switch captureSource {
            case .replayKit:
                receiver.onEvent = { [weak self] msg in
                    Task { @MainActor in
                        self?.extensionConnected = msg.contains("接続しました")
                        self?.captureStatus = msg
                        self?.log(msg)
                    }
                }
                receiver.onBuffer = handler
                try receiver.start()
                captureStatus = "拡張の接続待ち"
                log("socket 待受を開始。画面収録（ブロードキャスト）を開始してください")
            case .screenCaptureKit:
                try await startScreenCaptureKit(handler)
            case .microphone:
                try startMicrophone(handler)
            }
            isRunning = true
            startWatchdog()
        } catch {
            log("開始に失敗: \(error.localizedDescription)")
            await stop()
            if case CaptureError.microphoneDenied = error {
                microphoneDenied = true
                captureStatus = "マイクの使用が許可されていません"
            }
        }
    }

    /// マイクの録音権限を確認し、未決定なら要求する。
    private func ensureMicrophonePermission() async -> Bool {
        switch MicrophoneAudioSource.permission {
        case .granted:
            return true
        case .denied:
            log("マイクの権限が拒否されています")
            return false
        default:
            let granted = await MicrophoneAudioSource.requestPermission()
            log(granted ? "マイクの権限が許可されました" : "マイクの権限が許可されませんでした")
            return granted
        }
    }

    private func startMicrophone(_ handler: @escaping (AVAudioPCMBuffer) -> Void) throws {
        micSource.onBuffer = handler
        micSource.onEvent = { [weak self] msg in
            Task { @MainActor in self?.log(msg) }
        }
        micSource.onStopped = { [weak self] error in
            Task { @MainActor in
                guard let self, self.isRunning else { return }
                self.log("マイクの取り込みが停止しました: \(error.localizedDescription)")
                await self.stop()
                self.captureStatus = "マイクが停止しました（開始し直してください）"
            }
        }
        try micSource.start()
        captureStatus = "マイクで取り込み中"
        log("マイクの取り込みを開始しました")
    }

    /// 文字起こしエンジンのコールバックを設定する（ライブ・ファイルで共通）。
    private func configureEngine() {
        engine.onLog = { [weak self] msg in Task { @MainActor in self?.log(msg) } }
        engine.onFailure = { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                if self.isTranscribingFile {
                    self.log("ファイルの文字起こしが続行できないため中止します: \(error.localizedDescription)")
                    self.fileTask?.cancel()
                    return
                }
                guard self.isRunning else { return }
                self.captureStatus = "文字起こしが停止しました"
                self.log("文字起こしが続行できないため停止します: \(error.localizedDescription)")
                await self.stop()
                self.captureStatus = "文字起こしが停止しました"
            }
        }
        engine.onResult = { [weak self] result in
            Task { @MainActor in self?.handleResult(result) }
        }
    }

    // MARK: - ファイルの文字起こし

    /// ファイルの文字起こしを始める。現在の履歴は置き換える。実行中のライブ取り込みとは同時に行えない。
    func startFileTranscription(_ url: URL) {
        guard !isRunning, !isStarting, !isTranscribingFile else { return }
        isTranscribingFile = true
        fileProgress = 0
        fileStatus = "準備中"
        fileTask = Task { await transcribeFile(url) }
    }

    /// コントロールセンターのボタンからの依頼を処理する。
    /// 画面共有は、共有ピッカーを本体の画面から開く必要があるため、取り込み元の選択までを行う。
    /// マイクはピッカーが不要なため、そのまま開始する。
    func handleLaunchRequest(_ request: FloatSubLaunchRequest) async {
        guard !isRunning, !isStarting, !isTranscribingFile else { return }
        switch request {
        case .screen:
            if captureSource == .microphone { captureSource = CaptureSource.available.first { $0 != .microphone } ?? .replayKit }
            launchNotice = "「開始」を押すと共有ピッカーが開きます。画面全体の共有を開始してください。"
            log("コントロールセンターから開きました（画面共有）")
        case .microphone:
            captureSource = .microphone
            launchNotice = ""
            log("コントロールセンターから開きました（マイク）")
            await start()
        }
    }

    /// 保留中の依頼があれば処理する。インテントの書き込みが前面化より遅れても拾えるよう、少し待って再確認する。
    func consumeLaunchRequests() async {
        for attempt in 0..<3 {
            if let request = FloatSubLaunchRequest.take() {
                await handleLaunchRequest(request)
                return
            }
            if attempt < 2 { try? await Task.sleep(for: .milliseconds(600)) }
        }
    }

    func cancelFileTranscription() {
        fileTask?.cancel()
    }

    /// 取り込みの速度の上限（実時間の何倍で解析へ渡すか）。メモリを抑えるために間隔を空ける
    private static let fileFeedSpeed = 15.0

    private func transcribeFile(_ url: URL) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        defer { isTranscribingFile = false; fileTask = nil }
        // 再生用に、アプリの一時領域へ複製する（共有元のアクセス権は処理後に手放すため）
        HistoryExporter.removeTemporaryFiles()
        let local = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloatSub-source-\(UUID().uuidString).\(url.pathExtension)")
        do {
            try FileManager.default.copyItem(at: url, to: local)
        } catch {
            fileStatus = "ファイルを読み込めません: \(error.localizedDescription)"
            log(fileStatus)
            return
        }
        playbackURL = nil
        segments.removeAll()
        resetProvisional()
        chunker.reset()
        restAudioStart = nil
        displayOriginal = ""
        displayTranslation = ""
        fileMode = true
        defer { fileMode = false }
        log("ファイルの文字起こしを開始: \(url.lastPathComponent)")

        let duration = await FileAudioReader.duration(of: local)
        await prepareTranslation()
        configureEngine()
        startWatchdog()
        defer { watchdogTask?.cancel(); watchdogTask = nil }
        do {
            try await engine.start(localeIdentifier: localeIdentifier)
            fileStatus = "文字起こし中"
            var fed = 0.0
            try await FileAudioReader.read(url: local) { buffer in
                engine.feed(buffer)
                let seconds = Double(buffer.frameLength) / buffer.format.sampleRate
                fed += seconds
                if duration > 0 { fileProgress = min(fed / duration, 1) }
                try await Task.sleep(for: .seconds(seconds / Self.fileFeedSpeed))
            }
            fileStatus = "結果を確定中"
            await engine.finishAndDrain()
            fileProgress = 1
        } catch is CancellationError {
            await engine.stop()
            fileStatus = "中止しました"
            log("ファイルの文字起こしを中止しました")
            playbackURL = segments.isEmpty ? nil : local
            return
        } catch {
            await engine.stop()
            fileStatus = "失敗: \(error.localizedDescription)"
            log("ファイルの文字起こしに失敗: \(error.localizedDescription)")
            return
        }
        fileStatus = "翻訳中"
        await flushTranslations()
        fileStatus = pendingTranslationCount == 0 ? "完了（\(segments.count) 件）" : "完了（未翻訳 \(pendingTranslationCount) 件）"
        playbackURL = local
        log("ファイルの文字起こしが完了しました")
    }

    func stop() async {
        receiver.stop()
        micSource.stop()
        #if canImport(ScreenCaptureKit)
        await sckSource.stop()
        #endif
        captureStatus = "停止"
        await engine.stop()
        keepAlive.stop()
        translator.reset()
        cancelPartialWork()
        soundDetector?.stop()
        soundDetector = nil
        speakerTask?.cancel()
        speakerTask = nil
        speakerDiarizer?.stop()
        speakerDiarizer = nil
        soundCaptionTask?.cancel()
        soundCaption = nil
        activeSoundSegments.removeAll()
        musicSuppressed = false
        watchdogTask?.cancel()
        watchdogTask = nil
        flushGeneration += 1
        flushingSince = nil
        pip.stop()
        translationConfiguration = nil
        translationStatus = "未準備"
        isRunning = false
        extensionConnected = false
        log("停止しました")
    }

    // MARK: - 取り込み

    /// 受信した音声を文字起こしへ流し、診断値を更新する。取り込み側の Thread から呼ばれる。
    private func makeBufferHandler() -> (AVAudioPCMBuffer) -> Void {
        let detector = soundDetector
        let diarizer = speakerDiarizer
        return { [weak self] buffer in
            guard let self else { return }
            self.engine.feed(buffer)
            detector?.feed(buffer)
            diarizer?.feed(buffer)
            let rms = Self.rms(buffer)
            let rate = buffer.format.sampleRate
            Task { @MainActor in
                self.receivedBuffers += 1
                self.receivedSampleRate = rate
                self.level = rms
            }
        }
    }

    /// 共有ピッカーで共有対象（画面全体）を選んでもらい、音声の取り込みを開始する。
    private func startScreenCaptureKit(_ handler: @escaping (AVAudioPCMBuffer) -> Void) async throws {
        #if canImport(ScreenCaptureKit)
        sckSource.onBuffer = handler
        sckSource.onEvent = { [weak self] msg in
            Task { @MainActor in
                self?.captureStatus = msg
                self?.log(msg)
            }
        }
        sckSource.onStopped = { [weak self] error in
            Task { @MainActor in
                guard let self, self.isRunning else { return }
                self.log("ScreenCaptureKit のストリームが停止しました: \(error.localizedDescription)")
                await self.stop()
                self.captureStatus = "共有が停止しました（開始し直してください）"
            }
        }
        captureStatus = "共有対象の選択待ち"
        log("共有ピッカーを開きます。画面全体の共有を開始してください")
        try await sckSource.start()
        captureStatus = "ScreenCaptureKit で取り込み中"
        log("ScreenCaptureKit の取り込みを開始しました。他アプリで音声を再生してください")
        #else
        throw CaptureError.unsupported
        #endif
    }

    // MARK: - 翻訳

    /// 言語モデルの導入状況を確認する。未導入ならダウンロード確認の表示を要求する。
    private func prepareTranslation() async {
        let source = sourceLanguage
        let target = targetLanguage
        switch await translator.prepare(source: source, target: target) {
        case .ready:
            translationStatus = "準備完了"
            log("翻訳の準備完了 (\(localeIdentifier) → \(targetLanguageIdentifier))")
        case .needsDownload:
            translationStatus = "言語モデルのダウンロード待ち"
            log("翻訳の言語モデルが未導入です。表示される確認でダウンロードしてください")
            translationConfiguration = TranslationSession.Configuration(source: source, target: target)
        case .unsupported:
            translationStatus = "非対応の言語ペア"
            log("この言語ペアの翻訳は非対応です (\(localeIdentifier) → \(targetLanguageIdentifier))")
        }
    }

    /// translationTask から呼ばれる。言語モデルをダウンロードし、翻訳を再開する。
    func handleDownload(_ session: TranslationSession) async {
        do {
            try await session.prepareTranslation()
            log("翻訳の言語モデルを取得しました")
        } catch {
            translationStatus = "ダウンロード失敗"
            log("翻訳の言語モデル取得に失敗: \(error.localizedDescription)")
            return
        }
        translationConfiguration = nil
        await prepareTranslation()
        await flushTranslations()
    }

    /// 未翻訳の文節の件数（再試行待ちを含み、あきらめたものを除く）。診断表示用。
    var pendingTranslationCount: Int {
        segments.filter { $0.translation == nil && !$0.isTranslationAbandoned }.count
    }

    /// 再試行をあきらめた文節の件数。診断表示用。
    var abandonedTranslationCount: Int {
        segments.filter { $0.isTranslationAbandoned }.count
    }

    /// 翻訳が止まっているとみなす時間。これを超えて翻訳が返らないときは、セッションを作り直して再開する
    private static let translationHangLimit = 20.0
    /// 滞留の確認間隔
    private static let watchdogInterval = Duration.seconds(5)

    /// 未翻訳の確定文節を古い順に翻訳する。失敗した文節は未翻訳のまま残し、間隔を空けて上限回数まで再試行する。
    /// 多重起動は flushingSince で防ぐ。長く返らない翻訳があれば、世代を進めて作り直す。
    private func flushTranslations() async {
        guard translator.isReady else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if let started = flushingSince {
            guard now - started >= Self.translationHangLimit else { return }
            log("翻訳が \(Int(now - started)) 秒返らないため、翻訳をやり直します")
            flushGeneration += 1
            flushingSince = nil
            await prepareTranslation()
            guard translator.isReady else { return }
        }
        let generation = flushGeneration
        flushingSince = ProcessInfo.processInfo.systemUptime
        defer { if generation == flushGeneration { flushingSince = nil } }
        while generation == flushGeneration, translator.isReady {
            let current = ProcessInfo.processInfo.systemUptime
            let candidates = segments.indices.filter { segments[$0].translation == nil && !segments[$0].isTranslationAbandoned }
            guard !candidates.isEmpty else { return }
            // 再試行の間隔が空いていない文節しか残っていないときは、最短の待ち時間だけ待つ
            guard let index = candidates.first(where: { segments[$0].retryAt <= current }) else {
                let wait = (candidates.map { segments[$0].retryAt }.min() ?? current) - current
                try? await Task.sleep(for: .seconds(max(0.2, wait)))
                continue
            }
            let id = segments[index].id
            let text = segments[index].text
            let audioEnd = segments[index].audioEnd
            do {
                let began = ProcessInfo.processInfo.systemUptime
                let translated = try await translate(text, urgent: true)
                guard generation == flushGeneration else { return }
                if let i = segments.firstIndex(where: { $0.id == id }) {
                    segments[i].translation = translated
                }
                updatePiP()
                recordCaptionLatency(audioEnd: audioEnd, translationBegan: began)
            } catch {
                guard generation == flushGeneration else { return }
                if let i = segments.firstIndex(where: { $0.id == id }) {
                    segments[i].translationAttempts += 1
                    let attempts = segments[i].translationAttempts
                    // 失敗のたびに待ち時間を延ばす（2 秒、4 秒、…最大 10 秒）
                    segments[i].retryAt = ProcessInfo.processInfo.systemUptime + min(Double(attempts) * 2, 10)
                    if segments[i].isTranslationAbandoned {
                        log("翻訳を断念しました（\(attempts) 回失敗）: \(error.localizedDescription)")
                        updatePiP()
                    } else {
                        log("翻訳に失敗（\(attempts)/\(TranscriptSegment.maxTranslationAttempts) 回）。あとで再試行します: \(error.localizedDescription)")
                    }
                }
            }
        }
    }

    /// 翻訳結果に用語の置換をかけて返す。
    private func translate(_ text: String, urgent: Bool) async throws -> String {
        let translated = try await translator.translate(text, urgent: urgent)
        return GlossaryRules.apply(translated, entries: glossary, target: .translation)
    }

    /// 未翻訳の文節が滞留していないかを定期的に確認し、止まっていれば翻訳を再開する。
    private func startWatchdog() {
        watchdogTask?.cancel()
        watchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.watchdogInterval)
                guard !Task.isCancelled, let self else { return }
                await self.resumeTranslations(resetAbandoned: false)
            }
        }
    }

    /// 未翻訳の文節があれば翻訳を再開する。前面へ戻ったときは、あきらめた文節にも再試行の機会を与える。
    func resumeTranslations(resetAbandoned: Bool = true) async {
        guard isRunning || !segments.isEmpty else { return }
        if resetAbandoned {
            for i in segments.indices where segments[i].isTranslationAbandoned {
                segments[i].translationAttempts = 0
                segments[i].retryAt = 0
            }
        }
        // 翻訳の準備が失われている場合（モデル導入後など）は準備し直す
        if !translator.isReady, translationConfiguration == nil { await prepareTranslation() }
        guard pendingTranslationCount > 0 else { return }
        if resetAbandoned { log("未翻訳 \(pendingTranslationCount) 件の翻訳を再開します") }
        await flushTranslations()
    }

    /// 字幕として出す内容を決めて、PiP とアプリ内表示へ反映する。
    /// 話している途中の残りに暫定訳があればそれを（薄く）出し、なければ最新の確定文節を出す。
    /// showLiveOriginal が有効なら、確定前の原文を原文欄に出す。
    private func updatePiP() {
        let last = segments.last
        let rest = volatileText
        var original: String
        var translation: String
        var isProvisional = false
        if let caption = soundCaption, rest.isEmpty {
            // 話している途中の残りがないときは、非音声イベントの表記を出す
            original = ""
            translation = caption
        } else if showProvisional, !rest.isEmpty, !provisionalTranslation.isEmpty {
            original = showLiveOriginal ? rest : ""
            translation = labeled(provisionalTranslation, speaker: speakerDiarizer?.latestLabel())
            isProvisional = true
        } else {
            original = (showLiveOriginal && !rest.isEmpty) ? rest : (last?.text ?? "")
            if let last {
                if let t = last.translation {
                    translation = last.kind == .speech ? labeled(t, speaker: last.speaker) : t
                } else if showProvisional, let p = last.provisionalTranslation {
                    // 確定訳が届くまで、直前の暫定訳を薄く出し続ける
                    translation = labeled(p, speaker: last.speaker)
                    isProvisional = true
                } else if last.isTranslationAbandoned {
                    translation = "（翻訳できません）"
                } else {
                    translation = "翻訳中…"
                }
            } else {
                translation = ""
            }
        }
        guard !original.isEmpty || !translation.isEmpty else { return }
        displayOriginal = original
        displayTranslation = translation
        displayIsProvisional = isProvisional
        pip.show(original: original, translation: translation, isProvisional: isProvisional)
    }

    /// 履歴の保持件数。長時間の利用でメモリが増え続けないようにする（履歴は端末のメモリ上だけに持つ）。
    private static let maxSegments = 2000

    /// 履歴をすべて削除する。表示中の字幕と、書き出しで作った一時ファイルも消す。
    func clearHistory() {
        segments.removeAll()
        resetProvisional()
        displayOriginal = ""
        displayTranslation = ""
        displayIsProvisional = false
        pip.show(original: "", translation: "字幕を待っています")
        HistoryExporter.removeTemporaryFiles()
        log("履歴を削除しました")
    }

    /// 確定訳を字幕へ出した時点の遅延を記録する（音声が届いてから表示までの合計と、翻訳単体の時間）。
    /// translationBegan が nil のときは、暫定訳の再利用などで翻訳を行っていない。
    private func recordCaptionLatency(audioEnd: Double, translationBegan: TimeInterval?) {
        let now = ProcessInfo.processInfo.systemUptime
        var detail = "（暫定訳を再利用）"
        if let translationBegan {
            let translation = now - translationBegan
            latencyStats.add(.translation, seconds: translation)
            detail = String(format: "（うち翻訳 %.2f 秒）", translation)
        }
        guard let captured = engine.timeline.uptime(atAudio: audioEnd) else { return }
        let total = now - captured
        latencyStats.add(.caption, seconds: total)
        latencySummary = latencyStats.summary
        log(String(format: "遅延 字幕（確定訳）%.2f 秒", total) + detail)
    }

    // MARK: - 話者分離

    /// 設定がオンなら、話者分離のモデルを準備して開始する。失敗しても文字起こしと翻訳は続ける。
    private func startSpeakerDiarizer() async {
        speakerDiarizer = nil
        guard speakerDiarization else { return }
        captureStatus = "話者分離のモデルを準備中（初回はダウンロード）"
        log("話者分離のモデルを準備しています")
        let diarizer = SpeakerDiarizer()
        do {
            try await diarizer.prepare()
        } catch {
            log("話者分離を使えません（話者ラベルなしで続行します）: \(error.localizedDescription)")
            return
        }
        speakerDiarizer = diarizer
        log("話者分離を有効にしました")
        // 文節の話者は、分離の結果が遅れて確定するため、直近の文節を定期的に付け直す
        speakerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1.5))
                guard !Task.isCancelled, let self else { return }
                self.refreshSpeakerLabels()
            }
        }
    }

    private func refreshSpeakerLabels() {
        guard let diarizer = speakerDiarizer else { return }
        var changed = false
        for i in segments.indices.suffix(30) where segments[i].kind == .speech {
            if let label = diarizer.label(from: segments[i].audioStart, to: segments[i].audioEnd), label != segments[i].speaker {
                segments[i].speaker = label
                changed = true
            }
        }
        if changed { updatePiP() }
    }

    /// 字幕の訳に話者ラベルを付ける。
    private func labeled(_ text: String, speaker: String?) -> String {
        guard let speaker, !text.isEmpty else { return text }
        return "\(speaker): \(text)"
    }

    // MARK: - 非音声イベント（笑い・音楽・拍手など）

    private func startSoundDetector() {
        let detector = SoundEventDetector()
        detector.onEvent = { [weak self] event in
            Task { @MainActor in self?.handleSound(event) }
        }
        detector.onMusicOnlyChange = { [weak self] musicOnly in
            Task { @MainActor in
                guard let self else { return }
                self.musicSuppressed = musicOnly
                self.log(musicOnly ? "音楽を検出：翻訳を抑制します" : "音楽が終わりました：翻訳を再開します")
                if musicOnly { self.resetProvisional() }
            }
        }
        soundDetector = detector
        log("音の認識を有効にしました")
    }

    /// 非音声イベントを字幕に出し、履歴に残す。音楽は鳴っている間、表記を出し続ける。
    private func handleSound(_ event: SoundEvent) {
        guard isRunning else { return }
        switch event.phase {
        case .began:
            let segment = TranscriptSegment(kind: .sound, text: event.label.caption, translation: event.label.caption,
                                            audioStart: event.time, audioEnd: event.time + 1)
            segments.append(segment)
            activeSoundSegments[event.label] = segment.id
            showSoundCaption(event.label.caption, keepWhileActive: event.label == .music)
        case .ended:
            if let id = activeSoundSegments.removeValue(forKey: event.label),
               let i = segments.firstIndex(where: { $0.id == id }) {
                segments[i].audioEnd = max(event.time, segments[i].audioStart + 1)
            }
            if event.label == .music, soundCaption == SoundLabel.music.caption {
                soundCaption = nil
                updatePiP()
            }
        }
    }

    private func showSoundCaption(_ caption: String, keepWhileActive: Bool) {
        soundCaptionTask?.cancel()
        soundCaption = caption
        updatePiP()
        if keepWhileActive { return }
        soundCaptionTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, let self else { return }
            self.soundCaption = nil
            self.updatePiP()
        }
    }

    // MARK: - 途中結果の処理（区切りと暫定訳）

    /// 暫定訳を作る最小の文字数と、翻訳を始める最小の間隔
    private static let provisionalMinChars = 4
    private static let provisionalInterval = 0.25
    /// 途中結果がこの時間変わらなければ、無音とみなして残りを区切る
    private static let pauseCommit = Duration.milliseconds(700)

    /// 履歴へ文節を追加する。reuse の訳（暫定訳）が同じ原文のものなら、翻訳を省いてそのまま確定訳にする。
    private func appendSegment(text: String, start: Double, end: Double) {
        var segment = TranscriptSegment(text: text, audioStart: start, audioEnd: end)
        segment.speaker = speakerDiarizer?.label(from: start, to: end)
        if musicSuppressed {
            // 音楽だけが鳴っている間の認識結果は、翻訳しない
            segment.translation = "♪"
        } else if showProvisional, !provisionalTranslation.isEmpty {
            if provisionalSource == text {
                segment.translation = provisionalTranslation
            } else {
                segment.provisionalTranslation = provisionalTranslation
            }
        }
        segments.append(segment)
        if segments.count > Self.maxSegments {
            segments.removeFirst(segments.count - Self.maxSegments)
        }
        // この区切りに対する暫定訳は役目を終えた。実行中の暫定訳の結果も捨てる
        resetProvisional()
        if segment.translation != nil {
            recordCaptionLatency(audioEnd: end, translationBegan: nil)
        }
    }

    private func resetProvisional() {
        provisionalGeneration += 1
        provisionalSource = ""
        provisionalTranslation = ""
    }

    /// 途中結果から、文末で閉じた部分を確定扱いにして履歴へ移す。
    private func commitReadyChunks() {
        while true {
            let rest = chunker.rest(of: volatileFull)
            guard let chunk = chunker.readyChunk(in: rest) else { return }
            commit(chunk, of: rest)
        }
    }

    /// rest の先頭 chunk を区切りとして履歴へ移す。音声の時刻は、文字数の比で按分する。
    private func commit(_ chunk: String, of rest: String) {
        let start = restAudioStart ?? volatileStart
        let ratio = Double(chunk.count) / Double(max(rest.count, 1))
        let end = start + max(0, volatileEnd - start) * min(ratio, 1)
        chunker.commit(chunk)
        restAudioStart = end
        appendSegment(text: chunk, start: start, end: end)
        volatileText = chunker.rest(of: volatileFull)
        updatePiP()
        Task { await flushTranslations() }
    }

    /// 途中結果が一定時間変わらなかったとき、残りを 1 つの区切りにする。
    private func schedulePauseCommit() {
        pauseTask?.cancel()
        pauseTask = Task { [weak self] in
            try? await Task.sleep(for: Self.pauseCommit)
            guard !Task.isCancelled, let self else { return }
            let rest = self.chunker.rest(of: self.volatileFull)
            guard let chunk = self.chunker.pauseChunk(in: rest) else { return }
            self.commit(chunk, of: rest)
        }
    }

    /// 話している途中の残りを翻訳して暫定訳にする。同時に 1 件だけ実行し、終わったら最新の残りで繰り返す。
    private func scheduleProvisional() {
        guard showProvisional, !musicSuppressed, !isThermallyConstrained, translator.isReady, provisionalTask == nil else { return }
        provisionalTask = Task { [weak self] in await self?.runProvisionalLoop() }
    }

    private func runProvisionalLoop() async {
        defer { provisionalTask = nil }
        while !Task.isCancelled {
            let text = volatileText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard showProvisional, !isThermallyConstrained, text.count >= Self.provisionalMinChars,
                  text != provisionalSource else { return }
            let generation = provisionalGeneration
            let captured = volatileCaptured
            let began = ProcessInfo.processInfo.systemUptime
            do {
                let translated = try await translate(text, urgent: false)
                // 待っている間に区切りや確定があった場合、この訳は古いので捨てる
                if generation == provisionalGeneration {
                    provisionalSource = text
                    provisionalTranslation = translated
                    updatePiP()
                    if let captured {
                        let latency = ProcessInfo.processInfo.systemUptime - captured
                        latencyStats.add(.provisional, seconds: latency)
                        latencySummary = latencyStats.summary
                    }
                }
            } catch {
                log("暫定訳の翻訳に失敗: \(error.localizedDescription)")
                return
            }
            let elapsed = ProcessInfo.processInfo.systemUptime - began
            if elapsed < Self.provisionalInterval {
                try? await Task.sleep(for: .seconds(Self.provisionalInterval - elapsed))
            }
        }
    }

    private func cancelPartialWork() {
        pauseTask?.cancel()
        pauseTask = nil
        provisionalTask?.cancel()
        provisionalTask = nil
        resetProvisional()
        chunker.reset()
        restAudioStart = nil
        volatileFull = ""
        volatileText = ""
    }

    private func handleResult(_ result: TranscriptionResult) {
        // 用語の置換（文字起こし側）は、区切りの判定や翻訳より前にかける
        let text = GlossaryRules.apply(result.text.trimmingCharacters(in: .whitespacesAndNewlines),
                                       entries: glossary, target: .transcript)
        if fileMode, !result.isFinal { return }
        if result.isFinal {
            pauseTask?.cancel()
            if let captured = result.capturedUptime {
                let recognition = result.receivedUptime - captured
                latencyStats.add(.recognition, seconds: recognition)
                log(String(format: "遅延 認識（確定）%.2f 秒", recognition))
            }
            // 区切り済みの部分を除いた残りだけを、最後の文節にする
            let remainder = chunker.rest(of: text)
            let start = restAudioStart ?? result.audioStart
            chunker.reset()
            restAudioStart = nil
            volatileFull = ""
            volatileText = ""
            if !remainder.isEmpty {
                appendSegment(text: remainder, start: start, end: max(result.audioEnd, start))
                updatePiP()
                Task { await flushTranslations() }
            } else {
                resetProvisional()
            }
        } else {
            volatileFull = text
            volatileStart = result.audioStart
            volatileEnd = result.audioEnd
            volatileCaptured = result.capturedUptime
            if restAudioStart == nil { restAudioStart = result.audioStart }
            commitReadyChunks()
            volatileText = chunker.rest(of: text)
            scheduleProvisional()
            schedulePauseCommit()
            if showLiveOriginal || showProvisional { updatePiP() }
        }
    }

    func log(_ message: String) {
        let stamp = Date.now.formatted(date: .omitted, time: .standard)
        logs.append("\(stamp) \(message)")
        if logs.count > 200 { logs.removeFirst(logs.count - 200) }
    }

    nonisolated private static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let ch = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<Int(buffer.frameLength) { sum += ch[i] * ch[i] }
        return (sum / Float(buffer.frameLength)).squareRoot()
    }
}
