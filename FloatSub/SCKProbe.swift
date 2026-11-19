#if SCK_PROBE && canImport(ScreenCaptureKit)
import Foundation
import AVFoundation
import CoreMedia
import ScreenCaptureKit

/// iOS 27 の ScreenCaptureKit で、他アプリの音声がアプリ内プロセスで取得できるかの検証用プローブ。
/// iOS 27.1 SDK のヘッダーで確認した経路: SCContentSharingPicker で共有対象を選択
/// → observer が SCContentFilter を受け取る → SCStream（capturesAudio）→ .audio 出力。
/// SCK_PROBE ビルド条件のときのみコンパイルされる（通常ビルドには影響しない）。
final class SCKProbe: NSObject, SCStreamOutput, SCStreamDelegate, SCContentSharingPickerObserver, @unchecked Sendable {
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "floatsub.sckprobe")
    private let lock = NSLock()
    private var continuation: CheckedContinuation<SCContentFilter?, Never>?
    private var pickerNote = ""

    private var audioBuffers = 0
    private var maxPeak: Float = 0
    private var formatNote = ""

    /// ピッカーを表示し、共有対象選択後に `seconds` 秒間の音声取得を試行してレポートを返す。
    /// 選択直後に YouTube 等へ切り替えて音声を再生しておく。
    @MainActor
    func run(seconds: Double = 30) async -> String {
        var report: [String] = []
        let picker = SCContentSharingPicker.shared
        report.append("picker.isAvailable = \(picker.isAvailable)")
        picker.isActive = true
        picker.add(self)

        // ピッカー表示。選択 / キャンセル / 失敗のいずれかで continuation が再開される
        let filter: SCContentFilter? = await withCheckedContinuation { cont in
            lock.lock(); continuation = cont; lock.unlock()
            picker.present()
        }
        picker.remove(self)
        if !pickerNote.isEmpty { report.append(pickerNote) }
        guard let filter else {
            return (report + ["ピッカーから filter を取得できませんでした"]).joined(separator: "\n")
        }
        report.append("filter.style = \(filter.style.rawValue) / contentRect = \(filter.contentRect)")

        do {
            let config = SCStreamConfiguration()
            config.capturesAudio = true
            config.excludesCurrentProcessAudio = true
            config.sampleRate = 48_000
            config.channelCount = 1
            // 映像は使わないため最小サイズにする
            config.width = 2
            config.height = 2
            let stream = SCStream(filter: filter, configuration: config, delegate: self)
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
            self.stream = stream
            try await stream.startCapture()
            report.append("startCapture 成功。\(Int(seconds)) 秒間受信します（YouTube 等で音声を再生してください）")
            try await Task.sleep(for: .seconds(seconds))
            try await stream.stopCapture()
            lock.lock()
            let (count, peak, fmt) = (audioBuffers, maxPeak, formatNote)
            lock.unlock()
            report.append("音声バッファ受信数: \(count) / 最大ピーク: \(peak)")
            if !fmt.isEmpty { report.append("形式: \(fmt)") }
            report.append(count > 0 ? "判定: アプリ内で音声取得が可能（ピークが 0 なら無音のため要確認）" : "判定: 音声が取得できていません")
        } catch {
            report.append("失敗: \(error)")
        }
        return report.joined(separator: "\n")
    }

    private func finishPicker(_ filter: SCContentFilter?, note: String = "") {
        lock.lock()
        let cont = continuation
        continuation = nil
        if !note.isEmpty { pickerNote = note }
        lock.unlock()
        cont?.resume(returning: filter)
    }

    // MARK: SCContentSharingPickerObserver

    func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        finishPicker(filter, note: "ピッカーで共有対象を選択しました")
    }

    func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        finishPicker(nil, note: "ピッカーがキャンセルされました")
    }

    func contentSharingPickerStartDidFailWithError(_ error: Error) {
        finishPicker(nil, note: "ピッカーの開始に失敗: \(error)")
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid else { return }
        var peak: Float = 0
        var note = ""
        if let desc = sampleBuffer.formatDescription,
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee {
            note = "\(asbd.mSampleRate)Hz \(asbd.mChannelsPerFrame)ch bits=\(asbd.mBitsPerChannel) flags=\(asbd.mFormatFlags)"
            let isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
            try? sampleBuffer.withAudioBufferList { list, _ in
                for buf in list {
                    guard let data = buf.mData else { continue }
                    if isFloat {
                        let count = Int(buf.mDataByteSize) / MemoryLayout<Float>.size
                        let samples = data.bindMemory(to: Float.self, capacity: count)
                        for i in 0..<count { peak = max(peak, abs(samples[i])) }
                    } else {
                        let count = Int(buf.mDataByteSize) / MemoryLayout<Int16>.size
                        let samples = data.bindMemory(to: Int16.self, capacity: count)
                        for i in 0..<count { peak = max(peak, abs(Float(samples[i])) / 32768) }
                    }
                }
            }
        }
        lock.lock()
        audioBuffers += 1
        maxPeak = max(maxPeak, peak)
        if formatNote.isEmpty { formatNote = note }
        lock.unlock()
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        lock.lock(); pickerNote += "\nストリーム停止: \(error)"; lock.unlock()
    }
}
#endif
