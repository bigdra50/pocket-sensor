import CoreImage
import CoreVideo
import Foundation

/// 1 つの CIContext を使い回して、プレビュー用の縮小 CGImage を作る。
///
/// 向きは変えず、拡大もしない。配信する JPEG と同じ `targetSize` を使う。
public final class PreviewScaler {
    private let context: CIContext

    public init() {
        context = CIContext(options: [.cacheIntermediates: false])
    }

    public func cgImage(from pixelBuffer: CVPixelBuffer, targetWidth: Int) -> CGImage? {
        let sourceWidth = CVPixelBufferGetWidth(pixelBuffer)
        let sourceHeight = CVPixelBufferGetHeight(pixelBuffer)
        guard let size = JPEGEncoder.targetSize(
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
            targetWidth: targetWidth
        ) else {
            return nil
        }
        let width = size.width
        let height = size.height

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
        return context.createCGImage(scaled, from: rect)
    }
}
