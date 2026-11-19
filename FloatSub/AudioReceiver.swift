import Foundation
import AVFoundation

/// 拡張から送られる音声を受信する Unix domain socket サーバ。
/// 本体アプリがバックグラウンドでも動作するよう、専用 Thread でブロッキング read を行う。
final class AudioReceiver {
    /// 受信した mono Float32 バッファ（受信 Thread から呼ばれる）
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    /// 接続状態などの通知（受信 Thread から呼ばれる）
    var onEvent: ((String) -> Void)?

    private var listenFD: Int32 = -1
    private var running = false

    func start() throws {
        guard let path = FloatSubShared.socketPath else {
            throw ReceiverError.noAppGroup(FloatSubShared.appGroupID)
        }
        guard var addr = makeSockAddrUn(path: path) else { throw ReceiverError.pathTooLong(path.utf8.count) }
        unlink(path)
        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        guard s >= 0 else { throw ReceiverError.syscall("socket", errno) }
        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else { close(s); throw ReceiverError.syscall("bind", errno) }
        guard listen(s, 1) == 0 else { close(s); throw ReceiverError.syscall("listen", errno) }
        listenFD = s
        running = true
        Thread.detachNewThread { [weak self] in self?.acceptLoop() }
    }

    func stop() {
        running = false
        if listenFD >= 0 { close(listenFD); listenFD = -1 }
        if let path = FloatSubShared.socketPath { unlink(path) }
    }

    private func acceptLoop() {
        while running {
            let client = accept(listenFD, nil, nil)
            if client < 0 { if running { Thread.sleep(forTimeInterval: 0.2) }; continue }
            onEvent?("拡張が接続しました")
            readLoop(client)
            close(client)
            onEvent?("拡張が切断されました")
        }
    }

    private func readLoop(_ client: Int32) {
        var headerData = Data(count: AudioFrameHeader.size)
        while running {
            guard readExactly(client, into: &headerData),
                  let header = AudioFrameHeader.decode(headerData),
                  header.frames > 0, header.frames < 1_000_000,
                  let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(header.sampleRate),
                                             channels: 1, interleaved: false),
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: header.frames)
            else { return }
            let byteCount = Int(header.frames) * 4
            guard let dst = buffer.floatChannelData?[0] else { return }
            var received = 0
            while received < byteCount {
                let n = read(client, UnsafeMutableRawPointer(dst) + received, byteCount - received)
                if n <= 0 { return }
                received += n
            }
            buffer.frameLength = header.frames
            onBuffer?(buffer)
        }
    }

    private func readExactly(_ fd: Int32, into data: inout Data) -> Bool {
        let count = data.count
        return data.withUnsafeMutableBytes { raw -> Bool in
            var received = 0
            while received < count {
                let n = read(fd, raw.baseAddress! + received, count - received)
                if n <= 0 { return false }
                received += n
            }
            return true
        }
    }

    enum ReceiverError: LocalizedError {
        case noAppGroup(String)
        case pathTooLong(Int)
        case syscall(String, Int32)
        var errorDescription: String? {
            switch self {
            case .noAppGroup(let id): "App Group コンテナを取得できません (\(id))"
            case .pathTooLong(let n): "socket パスが長すぎます (\(n) byte)"
            case .syscall(let name, let code): "\(name) が失敗しました (errno \(code))"
            }
        }
    }
}
