import SwiftUI
import AVFoundation
import AVKit
import Observation

/// 音声・動画ファイルの音声トラックを、PCM バッファとして順に読み出す。
enum FileAudioReader {
    enum ReadError: LocalizedError {
        case noAudioTrack
        var errorDescription: String? { "このファイルには音声がありません" }
    }

    static func duration(of url: URL) async -> Double {
        let seconds = (try? await AVURLAsset(url: url).load(.duration).seconds) ?? 0
        return seconds.isFinite ? seconds : 0
    }

    /// 音声トラックを 16kHz・モノラル・Float32 に変換しながら読み、バッファごとに handler を呼ぶ。
    static func read(url: URL, handler: (AVAudioPCMBuffer) async throws -> Void) async throws {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw ReadError.noAudioTrack }
        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVNumberOfChannelsKey: 1,
            AVSampleRateKey: 16_000,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? ReadError.noAudioTrack }
        defer { if reader.status == .reading { reader.cancelReading() } }

        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let buffer = pcmBuffer(from: sample) else { continue }
            try await handler(buffer)
        }
        if reader.status == .failed { throw reader.error ?? ReadError.noAudioTrack }
    }

    private static func pcmBuffer(from sample: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard sample.isValid, let description = sample.formatDescription,
              var asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
              let format = AVAudioFormat(streamDescription: &asbd) else { return nil }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sample))
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sample, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList)
        return status == noErr ? buffer : nil
    }
}

/// 再生の状態。再生位置を 0.1 秒ごとに更新し、字幕の選択に使う。
@MainActor
@Observable
final class PlaybackModel {
    let player: AVPlayer
    var time = 0.0
    @ObservationIgnored private var observer: Any?

    init(url: URL) {
        player = AVPlayer(url: url)
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main) { [weak self] t in
            MainActor.assumeIsolated { self?.time = t.seconds }
        }
    }

    func stop() {
        player.pause()
        if let observer { player.removeTimeObserver(observer) }
        observer = nil
    }
}

/// 取り込んだファイルを再生しながら、文字起こしと訳を字幕として重ねて表示する。
/// 結果はあらかじめ全部そろっているため、再生位置に合わせて選ぶだけで、音声・映像と字幕が完全に同期する。
struct FilePlaybackView: View {
    let url: URL
    let segments: [TranscriptSegment]
    let style: SubtitleStyle
    @State private var model: PlaybackModel
    @Environment(\.dismiss) private var dismiss

    init(url: URL, segments: [TranscriptSegment], style: SubtitleStyle) {
        self.url = url
        self.segments = segments.filter { $0.kind == .speech }
        self.style = style
        _model = State(initialValue: PlaybackModel(url: url))
    }

    /// 再生位置にかかる字幕。区間の間は、直前の字幕を終了から 1 秒だけ残す。
    private var current: TranscriptSegment? {
        let t = model.time
        return segments.last { $0.audioStart <= t && t < max($0.audioEnd, $0.audioStart + 1) }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                VideoPlayer(player: model.player)
                VStack(alignment: .leading, spacing: 6) {
                    if style.showOriginal, let current { Text(current.text).font(.callout).foregroundStyle(.secondary) }
                    Text(current?.translation ?? (current == nil ? "" : "（翻訳待ち）"))
                        .font(.system(size: 22 * style.fontScale, weight: .bold))
                        .foregroundStyle(Color(uiColor: style.textColor.uiColor))
                }
                .frame(maxWidth: .infinity, minHeight: 110, alignment: .leading)
                .padding()
                .background(Color(red: 0.05, green: 0.06, blue: 0.09).opacity(style.backgroundOpacity))
            }
            .navigationTitle("再生")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("閉じる") { model.stop(); dismiss() } } }
            .onAppear { model.player.play() }
            .onDisappear { model.stop() }
        }
    }
}
