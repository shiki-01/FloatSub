#if SCK_PROBE && canImport(ScreenCaptureKit)
import Foundation
import AVFoundation
import ScreenCaptureKit

/// ScreenCaptureKit で他アプリの音声がアプリ内プロセスで取得できるかの検証用プローブ。
/// 実機で YouTube を再生した状態で実行し、一定時間に受信した音声バッファ数を報告する。
/// SCK_PROBE ビルド条件のときのみコンパイルされる（通常ビルドには影響しない）。
final class SCKProbe: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "floatsub.sckprobe")
    private var audioBuffers = 0
    private var maxPeak: Float = 0

    func run(seconds: Double = 10) async -> String {
        var report: [String] = []
        do {
            let content = try await SCShareableContent.current
            report.append("SCShareableContent 取得: displays=\(content.displays.count) apps=\(content.applications.count) windows=\(content.windows.count)")
            guard let display = content.displays.first else {
                return (report + ["display が 0 件のため中断"]).joined(separator: "\n")
            }
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            config.capturesAudio = true
            config.excludesCurrentProcessAudio = true
            let stream = SCStream(filter: filter, configuration: config, delegate: self)
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
            self.stream = stream
            try await stream.startCapture()
            report.append("startCapture 成功。\(Int(seconds)) 秒間受信します")
            try await Task.sleep(for: .seconds(seconds))
            try await stream.stopCapture()
            report.append("音声バッファ受信数: \(audioBuffers) / 最大ピーク: \(maxPeak)")
            report.append(audioBuffers > 0 ? "判定: アプリ内で音声取得が可能" : "判定: 音声が取得できていません")
        } catch {
            report.append("失敗: \(error)")
        }
        return report.joined(separator: "\n")
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid else { return }
        audioBuffers += 1
        try? sampleBuffer.withAudioBufferList { list, _ in
            for buf in list {
                guard let data = buf.mData else { continue }
                let count = Int(buf.mDataByteSize) / MemoryLayout<Float>.size
                let samples = data.bindMemory(to: Float.self, capacity: count)
                for i in 0..<count { maxPeak = max(maxPeak, abs(samples[i])) }
            }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {}
}
#endif
