import CoreVideo
import Foundation

/// 深度画像の中央パッチの中央値（純粋）。
///
/// UI の depth center に使い、LiDAR が生きているかを画面で確かめる。
/// パッチの取り方（辺の 1/8、256×192 なら 32×24）と無効画素（0）の扱いは
/// 前身 PhoneSense と同じにする。
enum DepthSummary {
    static let centerFraction: Float = 0.125
    /// ARKit の confidence は 0 / 1 / 2 で 2 が最高
    static let highConfidence: UInt8 = 2

    static func centerMedian(
        depth: [Float], confidence: [UInt8]? = nil, width: Int, height: Int, fraction: Float
    ) -> Float? {
        precondition(depth.count == width * height, "深度配列の長さが合わない")
        let patchHeight = max(1, Int(Float(height) * fraction))
        let patchWidth = max(1, Int(Float(width) * fraction))
        let y0 = (height - patchHeight) / 2
        let x0 = (width - patchWidth) / 2
        var values: [Float] = []
        values.reserveCapacity(patchHeight * patchWidth)
        for y in y0..<(y0 + patchHeight) {
            for x in x0..<(x0 + patchWidth) {
                let index = y * width + x
                let value = depth[index]
                guard value > 0, value.isFinite else { continue }
                if let confidence, confidence[index] != highConfidence { continue }
                values.append(value)
            }
        }
        guard !values.isEmpty else { return nil }
        values.sort()
        let middle = values.count / 2
        // numpy.median と同じく、偶数個なら中央 2 つの平均
        return values.count % 2 == 1 ? values[middle] : (values[middle - 1] + values[middle]) / 2
    }

    /// ARKit の depthMap（Float32）と confidenceMap（UInt8）から中央値を出す。1 Hz でしか呼ばない前提で配列へコピーする。
    static func centerMedian(of depthMap: CVPixelBuffer, confidence confidenceMap: CVPixelBuffer?, fraction: Float) -> Float? {
        guard let depth = floats(from: depthMap) else { return nil }
        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        var confidence: [UInt8]?
        if let confidenceMap, CVPixelBufferGetWidth(confidenceMap) == width, CVPixelBufferGetHeight(confidenceMap) == height {
            confidence = bytes(from: confidenceMap)
        }
        return centerMedian(depth: depth, confidence: confidence, width: width, height: height, fraction: fraction)
    }

    /// `DepthPreview` からも使う。要約は 1 Hz。プレビューの色付けは別 queue で最大 30 Hz。
    static func floats(from buffer: CVPixelBuffer) -> [Float]? {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_DepthFloat32 else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        var result = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            let row = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: Float.self)
            for x in 0..<width {
                result[y * width + x] = row[x]
            }
        }
        return result
    }

    private static func bytes(from buffer: CVPixelBuffer) -> [UInt8]? {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_OneComponent8 else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        var result = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            let row = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
            for x in 0..<width {
                result[y * width + x] = row[x]
            }
        }
        return result
    }
}
