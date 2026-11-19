#if canImport(ScreenCaptureKit)
import Foundation
import AVFoundation
import CoreMedia
import ScreenCaptureKit

/// iOS 27 の ScreenCaptureKit による音声取り込み。アプリ内プロセスだけで完結し、
/// ReplayKit の拡張（メモリ上限 50MB、App Group 経由の受け渡し）を必要としない。
/// 実機検証（iOS 27）で、他アプリの音声が 48kHz mono Float32 で届くことを確認済み。
/// 経路: SCContentSharingPicker で共有対象を選択 → SCContentFilter → SCStream（capturesAudio）→ .audio 出力。
/// iOS 27 SDK 専用のため、ScreenCaptureKit を import できない SDK ではコンパイルされない。
final class SCKAudioSource: NSObject, SCStreamOutput, SCStreamDelegate, SCContentSharingPickerObserver, @unchecked Sendable {
    /// 受信した音声（SCK のキューから呼ばれる）
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    /// 状態通知（ストリーム停止など）
    var onEvent: ((String) -> Void)?

    enum SourceError: LocalizedError {
        case pickerUnavailable
        case cancelled
        case pickerFailed(String)
        var errorDescription: String? {
            switch self {
            case .pickerUnavailable: "共有ピッカーを利用できません"
            case .cancelled: "共有対象の選択がキャンセルされました"
            case .pickerFailed(let message): "共有ピッカーの開始に失敗しました: \(message)"
            }
        }
    }

    private var stream: SCStream?
    private let queue = DispatchQueue(label: "floatsub.sck.audio")
    private let lock = NSLock()
    private var continuation: CheckedContinuation<SCContentFilter, Error>?

    /// ピッカーを表示し、共有対象の選択後に音声の取り込みを開始する。
    @MainActor
    func start() async throws {
        let picker = SCContentSharingPicker.shared
        guard picker.isAvailable else { throw SourceError.pickerUnavailable }
        picker.isActive = true
        picker.add(self)

        let filter: SCContentFilter
        do {
            filter = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<SCContentFilter, Error>) in
                lock.lock(); continuation = cont; lock.unlock()
                picker.present()
            }
        } catch {
            picker.remove(self)
            throw error
        }

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true // 自アプリの無音再生を除外する
        config.sampleRate = 48_000
        config.channelCount = 1
        // 映像は使わないため最小サイズにする
        config.width = 2
        config.height = 2
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    @MainActor
    func stop() async {
        let picker = SCContentSharingPicker.shared
        picker.remove(self)
        picker.isActive = false
        // 開始前（ピッカー表示中）に停止された場合は待機を解除する
        resumePicker(with: .failure(SourceError.cancelled))
        guard let stream else { return }
        self.stream = nil
        // 既に停止していると -3808 になるため、失敗は無視する
        try? await stream.stopCapture()
    }

    private func resumePicker(with result: Result<SCContentFilter, Error>) {
        lock.lock()
        let cont = continuation
        continuation = nil
        lock.unlock()
        cont?.resume(with: result)
    }

    // MARK: SCContentSharingPickerObserver

    func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        lock.lock()
        let waiting = continuation != nil
        lock.unlock()
        if waiting {
            resumePicker(with: .success(filter))
        } else if let current = self.stream {
            // 取り込み中に共有対象を選び直したとき
            current.updateContentFilter(filter) { [weak self] error in
                if let error { self?.onEvent?("共有対象の更新に失敗: \(error.localizedDescription)") }
            }
        }
    }

    func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        resumePicker(with: .failure(SourceError.cancelled))
    }

    func contentSharingPickerStartDidFailWithError(_ error: Error) {
        resumePicker(with: .failure(SourceError.pickerFailed(error.localizedDescription)))
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid,
              let description = sampleBuffer.formatDescription,
              var asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
              let format = AVAudioFormat(streamDescription: &asbd) else { return }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
        buffer.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList)
        guard status == noErr else { return }
        onBuffer?(buffer)
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onEvent?("ScreenCaptureKit のストリームが停止しました: \(error.localizedDescription)")
    }
}
#endif
