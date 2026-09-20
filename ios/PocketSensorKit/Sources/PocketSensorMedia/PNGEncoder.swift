import CoreGraphics
import Foundation
import ImageIO

/// 深度と confidence を PNG にする。画素値はそのまま。16 bit のソースは LE、PNG の中は BE。
public enum PNGEncoder {
    /// None / Sub / Up。ImageIO が無視してもエンコードは正しい。
    static let pngFilterNoneSubUp = 0x08 | 0x10 | 0x20

    public static func gray16(width: Int, height: Int, pixels: Data) -> Data? {
        encodeGray(width: width, height: height, pixels: pixels, bitsPerComponent: 16)
    }

    public static func gray16(width: Int, height: Int, pixels: UnsafeBufferPointer<UInt16>) -> Data? {
        gray16(width: width, height: height, pixels: Data(buffer: pixels))
    }

    public static func gray8(width: Int, height: Int, pixels: Data) -> Data? {
        encodeGray(width: width, height: height, pixels: pixels, bitsPerComponent: 8)
    }

    public static func gray8(width: Int, height: Int, pixels: UnsafeBufferPointer<UInt8>) -> Data? {
        gray8(width: width, height: height, pixels: Data(buffer: pixels))
    }

    private static func encodeGray(width: Int, height: Int, pixels: Data, bitsPerComponent: Int) -> Data? {
        guard width > 0, height > 0 else { return nil }
        let bytesPerPixel = bitsPerComponent / 8
        let bytesPerRow = width * bytesPerPixel
        let needed = height * bytesPerRow
        guard pixels.count >= needed else { return nil }
        let packed = Data(pixels.prefix(needed))
        guard let provider = CGDataProvider(data: packed as CFData) else { return nil }
        let colorSpace = CGColorSpaceCreateDeviceGray()
        var bitmapRaw = CGImageAlphaInfo.none.rawValue
        if bitsPerComponent == 16 {
            // ソースバッファは LE。バイト順の旗を付けて、手では入れ替えない。
            bitmapRaw |= CGBitmapInfo.byteOrder16Little.rawValue
        }
        let bitmapInfo = CGBitmapInfo(rawValue: bitmapRaw)
        guard let image = CGImage(
            width: width,
            height: height,
            bitsPerComponent: bitsPerComponent,
            bitsPerPixel: bitsPerComponent,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else { return nil }
        let destData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(destData, "public.png" as CFString, 1, nil) else {
            return nil
        }
        let png: [CFString: Any] = [
            kCGImagePropertyPNGInterlaceType: 0,
            kCGImagePropertyPNGCompressionFilter: pngFilterNoneSubUp,
        ]
        let options: [CFString: Any] = [kCGImagePropertyPNGDictionary: png]
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return destData as Data
    }
}
