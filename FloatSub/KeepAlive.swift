import AVFoundation

/// バックグラウンドでの実行維持用に、無音を再生し続ける。
/// Phase 3 以降は PiP の再生が実行維持を担うが、Phase 1 ではこの無音再生で代替する。
/// mixWithOthers により YouTube など他アプリの再生を中断させない。
final class KeepAlive {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private(set) var isRunning = false
    private var interruptionObserver: NSObjectProtocol?

    /// recording が true のときは、マイク入力のために録音も可能なカテゴリで開始する。
    func start(recording: Bool = false) throws {
        guard !isRunning else { return }
        let session = AVAudioSession.sharedInstance()
        if recording {
            // 他アプリの再生を止めず、出力はスピーカーに残す
            try session.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .defaultToSpeaker])
        } else {
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        }
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

        // 電話などの割り込みが終わったら、無音再生を再開して実行維持を回復する
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            guard let self,
                  let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
            try? AVAudioSession.sharedInstance().setActive(true)
            if !self.engine.isRunning { try? self.engine.start() }
            self.player.play()
        }
    }

    func stop() {
        guard isRunning else { return }
        if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
        interruptionObserver = nil
        player.stop()
        engine.stop()
        engine.detach(player)
        isRunning = false
    }
}
