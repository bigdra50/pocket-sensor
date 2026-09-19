import CoreVideo
import ImageIO
import PocketSensorMedia
import XCTest

final class JPEGEncoderTests: XCTestCase {
    func testBGRAEncodesToRequestedEvenSizeAndDoesNotUpscale() throws {
        let encoder = JPEGEncoder()
        let source = try XCTUnwrap(makeBGRABuffer(width: 64, height: 48, fill: 0x80))
        let encoded = try XCTUnwrap(encoder.encode(pixelBuffer: source, targetWidth: 40, quality: 0.8))
        XCTAssertEqual(encoded.width, 40)
        XCTAssertEqual(encoded.height, 30)
        let size = try jpegPixelSize(encoded.data)
        XCTAssertEqual(size.width, 40)
        XCTAssertEqual(size.height, 30)

        let odd = try XCTUnwrap(encoder.encode(pixelBuffer: source, targetWidth: 41, quality: 0.8))
        XCTAssertEqual(odd.width, 40)

        let noUpscale = try XCTUnwrap(encoder.encode(pixelBuffer: source, targetWidth: 400, quality: 0.8))
        XCTAssertEqual(noUpscale.width, 64)
        XCTAssertEqual(noUpscale.height, 48)
    }

    func test420fEncodesWithoutRotation() throws {
        let encoder = JPEGEncoder()
        let source = try XCTUnwrap(make420fBuffer(width: 32, height: 16))
        let encoded = try XCTUnwrap(encoder.encode(pixelBuffer: source, targetWidth: 32, quality: 0.7))
        XCTAssertEqual(encoded.width, 32)
        XCTAssertEqual(encoded.height, 16)
        let size = try jpegPixelSize(encoded.data)
        XCTAssertEqual(size.width, 32)
        XCTAssertEqual(size.height, 16)
    }
}

private func jpegPixelSize(_ data: Data) throws -> (width: Int, height: Int) {
    let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
    let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
    let width = try XCTUnwrap(props[kCGImagePropertyPixelWidth] as? NSNumber).intValue
    let height = try XCTUnwrap(props[kCGImagePropertyPixelHeight] as? NSNumber).intValue
    return (width, height)
}

func makeBGRABuffer(width: Int, height: Int, fill: UInt8) -> CVPixelBuffer? {
    var buffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(
        kCFAllocatorDefault,
        width,
        height,
        kCVPixelFormatType_32BGRA,
        nil,
        &buffer
    )
    guard status == kCVReturnSuccess, let buffer else { return nil }
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
    guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
    for row in 0 ..< height {
        let rowPtr = base.advanced(by: row * bytesPerRow).assumingMemoryBound(to: UInt8.self)
        for col in 0 ..< width {
            let i = col * 4
            rowPtr[i] = UInt8(col * 255 / max(width - 1, 1))
            rowPtr[i + 1] = fill
            rowPtr[i + 2] = UInt8(row * 255 / max(height - 1, 1))
            rowPtr[i + 3] = 255
        }
    }
    return buffer
}

func make420fBuffer(width: Int, height: Int) -> CVPixelBuffer? {
    var buffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(
        kCFAllocatorDefault,
        width,
        height,
        kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        nil,
        &buffer
    )
    guard status == kCVReturnSuccess, let buffer else { return nil }
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    let yBytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
    if let yBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) {
        for row in 0 ..< height {
            let rowPtr = yBase.advanced(by: row * yBytes).assumingMemoryBound(to: UInt8.self)
            for col in 0 ..< width {
                rowPtr[col] = UInt8((row + col) % 256)
            }
        }
    }
    let uvBytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
    if let uvBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) {
        for row in 0 ..< (height / 2) {
            let rowPtr = uvBase.advanced(by: row * uvBytes).assumingMemoryBound(to: UInt8.self)
            for col in 0 ..< width {
                rowPtr[col] = 128
            }
        }
    }
    return buffer
}
