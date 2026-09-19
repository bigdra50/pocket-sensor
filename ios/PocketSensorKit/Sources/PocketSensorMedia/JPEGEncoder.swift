import CoreImage
import CoreVideo
import Foundation
import ImageIO

public struct EncodedImage: Equatable, Sendable {
    public var data: Data
    public var width: Int
    public var height: Int

    public init(data: Data, width: Int, height: Int) {
        self.data = data
        self.width = width
        self.height = height
    }
}

/// 1 つの CIContext を使い回して JPEG にする。向きは変えず、拡大もしない。
public final class JPEGEncoder {
    private let context: CIContext

    public init() {
        context = CIContext(options: [.cacheIntermediates: false])
    }

    public func encode(pixelBuffer: CVPixelBuffer, targetWidth: Int, quality: Double) -> EncodedImage? {
        let sourceWidth = CVPixelBufferGetWidth(pixelBuffer)
        let sourceHeight = CVPixelBufferGetHeight(pixelBuffer)
        guard sourceWidth > 0, sourceHeight > 0, targetWidth > 0 else { return nil }
        var width = min(targetWidth, sourceWidth)
        if width % 2 != 0 {
            width -= 1
        }
        guard width > 0 else { return nil }
        let height = Int((Double(sourceHeight) * Double(width) / Double(sourceWidth)).rounded())
        guard height > 0 else { return nil }

        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let scaled: CIImage
        if width != sourceWidth || height != sourceHeight {
            let sx = CGFloat(width) / CGFloat(sourceWidth)
            let sy = CGFloat(height) / CGFloat(sourceHeight)
            scaled = image.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
        } else {
            scaled = image
        }

        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        guard let cgImage = context.createCGImage(scaled, from: rect) else { return nil }
        let destData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(destData, "public.jpeg" as CFString, 1, nil) else {
            return nil
        }
        let clampedQuality = min(max(quality, 0), 1)
        let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: clampedQuality]
        CGImageDestinationAddImage(destination, cgImage, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return EncodedImage(data: destData as Data, width: width, height: height)
    }
}
