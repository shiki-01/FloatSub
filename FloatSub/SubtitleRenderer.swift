import UIKit
import CoreMedia
import CoreVideo

/// 字幕の表示設定。
struct SubtitleStyle: Equatable {
    /// 原文（英語など）を日本語訳の上に小さく表示するか
    var showOriginal = true
    /// 文字サイズの倍率（0.8〜1.4）
    var fontScale: CGFloat = 1.0
}

/// 字幕テキストを映像フレーム（CVPixelBuffer）として描画する。
/// PiP の小窓に表示するため、背景は不透明な暗色にし、日本語訳を大きく、原文を小さく描く。
enum SubtitleRenderer {
    /// フレームの画素サイズ。PiP 小窓の縦横比（16:5 程度）に合わせる
    static let size = CGSize(width: 960, height: 300)

    static func makePixelBuffer(original: String, translation: String, isProvisional: Bool = false,
                                       style: SubtitleStyle = SubtitleStyle()) -> CVPixelBuffer? {
        let attributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any],
        ]
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, Int(size.width), Int(size.height),
            kCVPixelFormatType_32BGRA, attributes as CFDictionary, &buffer)
        guard status == kCVReturnSuccess, let buffer else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer),
              let context = CGContext(
                data: base, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }

        // UIKit の文字描画は左上原点のため、座標系を反転する
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        UIGraphicsPushContext(context)
        defer { UIGraphicsPopContext() }

        UIColor(red: 0.05, green: 0.06, blue: 0.09, alpha: 1).setFill()
        context.fill(CGRect(origin: .zero, size: size))

        let margin: CGFloat = 36
        let width = size.width - margin * 2
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping

        // 原文（小さく、灰色）。上部に最大 2 行
        var translationTop: CGFloat = 20
        if style.showOriginal {
            let originalHeight = min(120, 76 * style.fontScale)
            let originalAttributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 28 * style.fontScale, weight: .regular),
                .foregroundColor: UIColor(white: 0.62, alpha: 1),
                .paragraphStyle: paragraph,
            ]
            let originalRect = CGRect(x: margin, y: 20, width: width, height: originalHeight)
            (original as NSString).draw(with: originalRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                        attributes: originalAttributes, context: nil)
            translationTop = 20 + originalHeight + 8
        }

        // 日本語訳（大きく、白）。収まるまで文字サイズを下げる
        let translationRect = CGRect(x: margin, y: translationTop, width: width, height: size.height - translationTop - 20)
        var fontSize: CGFloat = 52 * style.fontScale
        // 暫定訳は透明度を下げて、確定訳と見分けられるようにする
        let translationColor = UIColor.white.withAlphaComponent(isProvisional ? 0.5 : 1)
        var translationAttributes: [NSAttributedString.Key: Any] = [:]
        while fontSize >= 24 {
            translationAttributes = [
                .font: UIFont.systemFont(ofSize: fontSize, weight: .bold),
                .foregroundColor: translationColor,
                .paragraphStyle: paragraph,
            ]
            let needed = (translation as NSString).boundingRect(
                with: CGSize(width: width, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin], attributes: translationAttributes, context: nil)
            if needed.height <= translationRect.height { break }
            fontSize -= 4
        }
        (translation as NSString).draw(with: translationRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                       attributes: translationAttributes, context: nil)
        return buffer
    }

    /// 即時表示用の CMSampleBuffer を作る。presentationTime は呼び出し側のタイムベース時刻。
    static func makeSampleBuffer(from pixelBuffer: CVPixelBuffer, at time: CMTime) -> CMSampleBuffer? {
        var formatDescription: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescriptionOut: &formatDescription) == noErr,
              let formatDescription else { return nil }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescription: formatDescription,
            sampleTiming: &timing, sampleBufferOut: &sampleBuffer) == noErr,
              let sampleBuffer else { return nil }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true)
            as? [NSMutableDictionary] {
            attachments.first?[kCMSampleAttachmentKey_DisplayImmediately] = true
        }
        return sampleBuffer
    }
}
