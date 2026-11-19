#if SCK_PROBE && canImport(ScreenCaptureKit)
import Foundation
import AVFoundation
import CoreMedia
import ScreenCaptureKit
import UIKit

/// iOS 27 の ScreenCaptureKit で、他アプリの音声がアプリ内プロセスで取得できるかの検証用プローブ。
/// 経路: SCContentSharingPicker で共有対象を選択 → observer が SCContentFilter を受け取る
/// → SCStream（capturesAudio）→ .audio 出力。
/// 途中でストリームが停止しても、受信数・停止理由・アプリの前面/背面遷移を時刻つきで報告する。
/// SCK_PROBE ビルド条件のときのみコンパイルされる（通常ビルドには影響しない）。
final class SCKProbe: NSObject, SCStreamOutput, SCStreamDelegate, SCContentSharingPickerObserver, @unchecked Sendable {
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "floatsub.sckprobe")
    private let lock = NSLock()
    private var continuation: CheckedContinuation<SCContentFilter?, Never>?

    private var startedAt = Date()
    private var events: [String] = []
    private var audioBuffers = 0
    private var maxPeak: Float = 0
    private var formatNote = ""
    private var firstBufferAt: TimeInterval?
    private var lastBufferAt: TimeInterval?
    private var streamStopped = false

    private func note(_ text: String) {
        let t = Date().timeIntervalSince(startedAt)
        lock.lock(); events.append(String(format: "+%.1fs %@", t, text)); lock.unlock()
    }

    /// ピッカーを表示し、共有対象選択後に `seconds` 秒間の音声取得を試行してレポートを返す。
    /// 選択直後に YouTube 等へ切り替えて音声を再生しておく。
    @MainActor
    func run(seconds: Double = 30) async -> String {
        startedAt = Date()
        let center = NotificationCenter.default
        let observers = [
            center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil) { [weak self] _ in
                self?.note("アプリがバックグラウンドへ")
            },
            center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: nil) { [weak self] _ in
                self?.note("アプリがフォアグラウンドへ")
            },
        ]
        defer { observers.forEach { center.removeObserver($0) } }

        let picker = SCContentSharingPicker.shared
        note("picker.isAvailable = \(picker.isAvailable)")
        picker.isActive = true
        picker.add(self)

        // ピッカー表示。選択 / キャンセル / 失敗のいずれかで continuation が再開される
        let filter: SCContentFilter? = await withCheckedContinuation { cont in
            lock.lock(); continuation = cont; lock.unlock()
            picker.present()
        }
        picker.remove(self)
        guard let filter else { return summary(extra: "ピッカーから filter を取得できませんでした") }
        note("filter.style = \(filter.style.rawValue) / contentRect = \(filter.contentRect)")

        var extra = ""
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
            note("startCapture 成功（YouTube 等で音声を再生してください）")

            // 1 秒ごとに状態を確認し、停止した場合は待たずに抜ける
            for _ in 0..<Int(seconds) {
                try? await Task.sleep(for: .seconds(1))
                lock.lock(); let stopped = streamStopped; lock.unlock()
                if stopped { break }
            }
            do {
                try await stream.stopCapture()
                note("stopCapture 成功")
            } catch {
                // 既に停止していた場合に -3808 になる。集計は続行する
                note("stopCapture 失敗: \(error.localizedDescription)")
            }
        } catch {
            extra = "失敗: \(error)"
        }
        return summary(extra: extra)
    }

    private func summary(extra: String) -> String {
        lock.lock()
        let (count, peak, fmt, first, last) = (audioBuffers, maxPeak, formatNote, firstBufferAt, lastBufferAt)
        let log = events
        lock.unlock()
        var lines = log
        if !extra.isEmpty { lines.append(extra) }
        lines.append("音声バッファ受信数: \(count) / 最大ピーク: \(peak)")
        if let first, let last {
            lines.append(String(format: "最初のバッファ +%.1fs / 最後のバッファ +%.1fs", first, last))
        }
        if !fmt.isEmpty { lines.append("形式: \(fmt)") }
        lines.append(count > 0 ? "判定: アプリ内で音声取得が可能（ピークが 0 なら無音のため要確認）" : "判定: 音声が取得できていません")
        return lines.joined(separator: "\n")
    }

    private func finishPicker(_ filter: SCContentFilter?, note text: String) {
        note(text)
        lock.lock()
        let cont = continuation
        continuation = nil
        lock.unlock()
        cont?.resume(returning: filter)
    }

    // MARK: SCContentSharingPickerObserver

    func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        finishPicker(filter, note: "ピッカーで共有対象を選択")
    }

    func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        finishPicker(nil, note: "ピッカーがキャンセルされた")
    }

    func contentSharingPickerStartDidFailWithError(_ error: Error) {
        finishPicker(nil, note: "ピッカーの開始に失敗: \(error)")
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid else { return }
        let t = Date().timeIntervalSince(startedAt)
        var peak: Float = 0
        var format = ""
        if let desc = sampleBuffer.formatDescription,
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee {
            format = "\(asbd.mSampleRate)Hz \(asbd.mChannelsPerFrame)ch bits=\(asbd.mBitsPerChannel) flags=\(asbd.mFormatFlags)"
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
        if formatNote.isEmpty { formatNote = format }
        if firstBufferAt == nil { firstBufferAt = t }
        lastBufferAt = t
        lock.unlock()
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        lock.lock(); streamStopped = true; lock.unlock()
        note("ストリームが停止: \(error)")
    }
}
#endif
