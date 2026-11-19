import AVFoundation

/// バックグラウンドでの実行維持用に、無音を再生し続ける。
/// Phase 3 以降は PiP の再生が実行維持を担うが、Phase 1 ではこの無音再生で代替する。
/// mixWithOthers により YouTube など他アプリの再生を中断させない。
final class KeepAlive {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private(set) var isRunning = false

    func start() throws {
        guard !isRunning else { return }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try session.setActive(true)

        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100)!
        silence.frameLength = 44_100 // 1 秒の無音（確保済み領域は 0 初期化）
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        try engine.start()
        player.scheduleBuffer(silence, at: nil, options: .loops)
        player.play()
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        player.stop()
        engine.stop()
        engine.detach(player)
        isRunning = false
    }
}
