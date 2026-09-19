import CoreVideo
import Foundation
import PocketSensorCore

public struct PackedImage: Equatable, Sendable {
    public var data: Data
    public var width: Int
    public var height: Int

    public init(data: Data, width: Int, height: Int) {
        self.data = data
        self.width = width
        self.height = height
    }
}

/// CVPixelBuffer の行詰めを外し、Core の単位変換へ渡す。
public enum DepthPacker {
    public static func depth16(from pixelBuffer: CVPixelBuffer) -> PackedImage? {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 0, height > 0 else { return nil }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let packed = Units.depthMetersToMillimeters(
            base: UnsafeRawPointer(base),
            width: width,
            height: height,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer)
        )
        return PackedImage(data: packed, width: width, height: height)
    }

    public static func confidence8(from pixelBuffer: CVPixelBuffer) -> PackedImage? {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 0, height > 0 else { return nil }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let packed = Units.packRows(
            base: UnsafeRawPointer(base),
            width: width,
            height: height,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            bytesPerPixel: 1
        )
        return PackedImage(data: packed, width: width, height: height)
    }
}
