import AVFoundation
import AVKit
import Observation
import SwiftUI

/// 字幕の Picture in Picture 表示。
/// 字幕を描画した映像フレームを AVSampleBufferDisplayLayer に流し、AVPictureInPictureController で小窓表示する。
/// PiP が再生中であることが、バックグラウンドでのアプリ実行維持も担う。
/// そのため、字幕に変化がなくても一定間隔で同じフレームを再投入し続ける。
@MainActor
@Observable
final class PiPController: NSObject {
    var status = "未準備"
    var isActive = false
    var isPossible = false

    let displayLayer = AVSampleBufferDisplayLayer()
    var onLog: ((String) -> Void)?

    private var pip: AVPictureInPictureController?
    private var possibleObservation: NSKeyValueObservation?
    private var timebase: CMTimebase?
    private var heartbeat: Timer?
    private var lastPixelBuffer: CVPixelBuffer?
    private var currentOriginal = ""
    private var currentTranslation = "字幕を待っています"
    private var style = SubtitleStyle()

    override init() {
        super.init()
        displayLayer.videoGravity = .resizeAspect
    }

    // MARK: - 準備

    /// レイヤーが画面に載った後に呼ぶ。PiP コントローラとタイムベースを作成する。
    func prepare() {
        guard pip == nil else { return }
        guard AVPictureInPictureController.isPictureInPictureSupported() else {
            status = "この端末は PiP に対応していません"
            return
        }
        configureTimebase()

        let source = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: displayLayer, playbackDelegate: self)
        let controller = AVPictureInPictureController(contentSource: source)
        controller.delegate = self
        // 他アプリへ切り替えたときに自動で PiP を開始する
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        // ライブ表示のため、スキップ操作を出さない
        controller.requiresLinearPlayback = true
        possibleObservation = controller.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] c, _ in
            let possible = c.isPictureInPicturePossible
            Task { @MainActor in
                self?.isPossible = possible
                self?.status = possible ? "開始できます" : "準備中"
            }
        }
        pip = controller
        render()
    }

    private func configureTimebase() {
        var tb: CMTimebase?
        CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault, sourceClock: CMClockGetHostTimeClock(), timebaseOut: &tb)
        guard let tb else { return }
        CMTimebaseSetTime(tb, time: .zero)
        CMTimebaseSetRate(tb, rate: 1)
        displayLayer.controlTimebase = tb
        timebase = tb
    }

    // MARK: - 開始・停止

    func start() {
        prepare()
        guard let pip else { return }
        startHeartbeat()
        if pip.isPictureInPicturePossible {
            pip.startPictureInPicture()
        } else {
            status = "PiP をまだ開始できません（画面にレイヤーが表示されているか確認）"
        }
    }

    func stop() {
        pip?.stopPictureInPicture()
        stopHeartbeat()
    }

    // MARK: - 字幕の更新

    /// 字幕を更新する。空文字は直前の表示を維持しない（空表示になる）。
    func show(original: String, translation: String) {
        currentOriginal = original
        currentTranslation = translation
        render()
    }

    /// 表示設定を変更し、現在の字幕を描き直す。
    func apply(style newStyle: SubtitleStyle) {
        guard newStyle != style else { return }
        style = newStyle
        render()
    }

    private func render() {
        guard let pixelBuffer = SubtitleRenderer.makePixelBuffer(
            original: currentOriginal, translation: currentTranslation, style: style) else { return }
        lastPixelBuffer = pixelBuffer
        enqueue(pixelBuffer)
    }

    private func enqueue(_ pixelBuffer: CVPixelBuffer) {
        guard let timebase else { return }
        let now = CMTimebaseGetTime(timebase)
        guard let sampleBuffer = SubtitleRenderer.makeSampleBuffer(from: pixelBuffer, at: now) else { return }
        if displayLayer.sampleBufferRenderer.status == .failed {
            displayLayer.sampleBufferRenderer.flush()
        }
        displayLayer.sampleBufferRenderer.enqueue(sampleBuffer)
    }

    /// PiP を再生状態に保つため、同じフレームを一定間隔で再投入する。
    private func startHeartbeat() {
        guard heartbeat == nil else { return }
        heartbeat = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let buffer = self.lastPixelBuffer else { return }
                self.enqueue(buffer)
            }
        }
    }

    private func stopHeartbeat() {
        heartbeat?.invalidate()
        heartbeat = nil
    }
}

// MARK: - 再生制御（ライブ表示のため常に再生中として応答する）

extension PiPController: AVPictureInPictureSampleBufferPlaybackDelegate {
    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool) {}

    nonisolated func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
        CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }

    nonisolated func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool {
        false
    }

    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}

    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, skipByInterval skipInterval: CMTime, completion completionHandler: @escaping @Sendable () -> Void) {
        completionHandler()
    }
}

// MARK: - 状態通知

extension PiPController: AVPictureInPictureControllerDelegate {
    nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor in
            isActive = true
            status = "PiP 表示中"
            startHeartbeat()
            onLog?("PiP を開始しました")
        }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor in
            isActive = false
            status = "停止"
            onLog?("PiP が終了しました")
        }
    }

    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        Task { @MainActor in
            status = "開始に失敗"
            onLog?("PiP の開始に失敗: \(error.localizedDescription)")
        }
    }
}

// MARK: - SwiftUI への埋め込み

/// PiP の起点になるレイヤーを画面に載せる。レイヤーが表示階層にないと PiP を開始できない。
struct PiPLayerView: UIViewRepresentable {
    let controller: PiPController

    func makeUIView(context: Context) -> LayerHostView {
        let view = LayerHostView()
        view.host(controller.displayLayer)
        return view
    }

    func updateUIView(_ uiView: LayerHostView, context: Context) {}

    final class LayerHostView: UIView {
        private weak var hosted: CALayer?

        func host(_ layer: CALayer) {
            hosted = layer
            self.layer.addSublayer(layer)
            backgroundColor = .black
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            hosted?.frame = bounds
        }
    }
}
