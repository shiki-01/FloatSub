import Foundation
import AVFoundation

/// マイクからの音声取り込み。AVAudioEngine の入力ノードにタップを付け、PCM バッファを取り込み側の Thread から渡す。
/// 対面会話や講義など、共有を開始せずに使う入力元。ScreenCaptureKit や ReplayKit と同じく、
/// onBuffer へ AVAudioPCMBuffer を渡すだけにして、後段（文字起こし・翻訳・表示）を共用する。
final class MicrophoneAudioSource {
    /// 受信した音声（オーディオ Thread から呼ばれる）
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    /// 状態通知
    var onEvent: ((String) -> Void)?
    /// 入力が続行できなくなったとき
    var onStopped: ((Error) -> Void)?

    enum SourceError: LocalizedError {
        case noInput
        var errorDescription: String? { "マイクの入力形式を取得できません（入力デバイスが使えない状態です）" }
    }

    private let engine = AVAudioEngine()
    private var isRunning = false
    private var observers: [NSObjectProtocol] = []

    /// 録音権限の状態。要求前は .undetermined。
    static var permission: AVAudioApplication.recordPermission {
        AVAudioApplication.shared.recordPermission
    }

    /// 録音権限を要求する。すでに決まっていれば、ダイアログなしで結果を返す。
    static func requestPermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    func start() throws {
        guard !isRunning else { return }
        try installTapAndStart()
        isRunning = true

        let center = NotificationCenter.default
        // イヤホンの抜き差しなどで入力形式が変わったときは、タップを張り直す
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            self?.restart(reason: "入力デバイスの構成が変わりました")
        })
        // 電話などの割り込みが終わったら再開する
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
            self?.restart(reason: "割り込みが終わりました")
        })
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    private func installTapAndStart() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw SourceError.noInput }
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.onBuffer?(buffer)
        }
        engine.prepare()
        try engine.start()
    }

    private func restart(reason: String) {
        guard isRunning else { return }
        onEvent?("\(reason)。マイクの取り込みを再開します")
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            try installTapAndStart()
        } catch {
            isRunning = false
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            observers.removeAll()
            onStopped?(error)
        }
    }
}
