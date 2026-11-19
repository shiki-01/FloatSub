import Foundation

/// 本体アプリと Broadcast Upload Extension で共有する定義。
/// 拡張 → 本体の音声受け渡しは、App Group コンテナ内の Unix domain socket で行う。
enum FloatSubShared {
    /// Info.plist の AppGroupID（ビルド設定 APP_GROUP_ID 由来）
    static var appGroupID: String {
        Bundle.main.object(forInfoDictionaryKey: "AppGroupID") as? String ?? ""
    }

    static var socketPath: String? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)?
            .appendingPathComponent("audio.sock").path
    }
}

/// フレームのワイヤ形式。ヘッダ 12 byte（little endian）+ Float32 mono PCM。
/// 拡張側で mono Float32 へ変換済みのため、本体側は受信後すぐ AVAudioPCMBuffer にできる。
enum AudioFrameHeader {
    static let magic: UInt32 = 0x4653_4155 // "FSAU"
    static let size = 12

    static func encode(sampleRate: UInt32, frames: UInt32) -> Data {
        var data = Data(capacity: size)
        for value in [magic, sampleRate, frames] {
            var v = value.littleEndian
            withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
        }
        return data
    }

    static func decode(_ data: Data) -> (sampleRate: UInt32, frames: UInt32)? {
        guard data.count == size else { return nil }
        func u32(_ offset: Int) -> UInt32 {
            data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }.littleEndian
        }
        guard u32(0) == magic else { return nil }
        return (u32(4), u32(8))
    }
}

/// sockaddr_un を組み立てるヘルパ。パス長の上限（104 byte）を超える場合は nil。
func makeSockAddrUn(path: String) -> sockaddr_un? {
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8CString)
    let capacity = MemoryLayout.size(ofValue: addr.sun_path)
    guard bytes.count <= capacity else { return nil }
    withUnsafeMutableBytes(of: &addr.sun_path) { raw in
        raw.copyBytes(from: bytes.map { UInt8(bitPattern: $0) })
    }
    return addr
}
