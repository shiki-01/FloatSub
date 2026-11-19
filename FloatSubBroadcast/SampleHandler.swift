import ReplayKit
import AVFoundation

/// Broadcast Upload Extension。メモリ上限 50MB のため、処理は最小限に留める。
/// 他アプリの音声（.audioApp）のみを mono Float32 に変換し、本体アプリへ socket 経由で送る。
final class SampleHandler: RPBroadcastSampleHandler {
    private let queue = DispatchQueue(label: "floatsub.broadcast.send")
    private var fd: Int32 = -1
    private var lastConnectAttempt = Date.distantPast
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?
    private var monoFormat: AVAudioFormat?
    /// 本体が詰まっているときにメモリが膨らまないよう、未処理数を制限する
    private let pending = NSLock()
    private var pendingCount = 0

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {}

    override func broadcastFinished() {
        queue.sync { closeSocket() }
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        guard sampleBufferType == .audioApp else { return }
        pending.lock()
        if pendingCount >= 32 { pending.unlock(); return }
        pendingCount += 1
        pending.unlock()
        queue.async { [self] in
            handle(sampleBuffer)
            pending.lock(); pendingCount -= 1; pending.unlock()
        }
    }

    // MARK: - 変換

    private func handle(_ sampleBuffer: CMSampleBuffer) {
        guard let desc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(desc) else { return }
        var asbd = asbdPtr.pointee
        guard let srcFormat = AVAudioFormat(streamDescription: &asbd) else { return }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frames > 0 else { return }

        if converter == nil || sourceFormat != srcFormat {
            guard let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: srcFormat.sampleRate,
                                           channels: 1, interleaved: false),
                  let conv = AVAudioConverter(from: srcFormat, to: mono) else { return }
            sourceFormat = srcFormat
            monoFormat = mono
            converter = conv
        }
        guard let converter, let monoFormat,
              let input = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: frames),
              let output = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: frames) else { return }
        input.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frames), into: input.mutableAudioBufferList)
        guard status == noErr else { return }

        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, outStatus in
            if consumed { outStatus.pointee = .noDataNow; return nil }
            consumed = true
            outStatus.pointee = .haveData
            return input
        }
        guard error == nil, output.frameLength > 0, let channel = output.floatChannelData?[0] else { return }

        let header = AudioFrameHeader.encode(sampleRate: UInt32(monoFormat.sampleRate), frames: output.frameLength)
        send(header, bytes: UnsafeRawBufferPointer(start: channel, count: Int(output.frameLength) * 4))
    }

    // MARK: - socket 送信

    private func connectIfNeeded() -> Bool {
        if fd >= 0 { return true }
        // 本体が未起動のときに毎バッファ connect しないよう間隔を空ける
        guard Date().timeIntervalSince(lastConnectAttempt) > 0.5 else { return false }
        lastConnectAttempt = Date()
        guard let path = FloatSubShared.socketPath, var addr = makeSockAddrUn(path: path) else { return false }
        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        guard s >= 0 else { return false }
        var one: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 0, tv_usec: 200_000)
        setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else { close(s); return false }
        fd = s
        return true
    }

    private func send(_ header: Data, bytes: UnsafeRawBufferPointer) {
        guard connectIfNeeded() else { return }
        let ok = header.withUnsafeBytes { writeAll($0) } && writeAll(bytes)
        if !ok { closeSocket() }
    }

    private func writeAll(_ buf: UnsafeRawBufferPointer) -> Bool {
        var offset = 0
        while offset < buf.count {
            let n = write(fd, buf.baseAddress! + offset, buf.count - offset)
            if n <= 0 { return false }
            offset += n
        }
        return true
    }

    private func closeSocket() {
        if fd >= 0 { close(fd); fd = -1 }
    }
}
