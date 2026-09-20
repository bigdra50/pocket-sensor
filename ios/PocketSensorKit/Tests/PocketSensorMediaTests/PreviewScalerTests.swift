import CoreGraphics
import CoreVideo
import PocketSensorMedia
import XCTest

final class PreviewScalerTests: XCTestCase {
    func testUniformFullRangeRedIsRedWithinTolerance() throws {
        let scaler = PreviewScaler()
        let source = try XCTUnwrap(make420fSolid(width: 64, height: 48, y: 76, cb: 85, cr: 255))
        let image = try XCTUnwrap(scaler.cgImage(from: source, targetWidth: 64))
        XCTAssertEqual(image.width, 64)
        XCTAssertEqual(image.height, 48)
        let pixels = rgbaPixels(image)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            assertRed(pixels[i], pixels[i + 1], pixels[i + 2], file: #filePath, line: #line)
        }
    }

    func testLeftRightAndTopBottomHalvesAreNotMirroredOrFlipped() throws {
        let scaler = PreviewScaler()

        let leftRight = try XCTUnwrap(
            make420fSplit(width: 64, height: 48, split: .leftRight, leftOrTop: (76, 85, 255), rightOrBottom: (29, 255, 107))
        )
        let lr = try XCTUnwrap(scaler.cgImage(from: leftRight, targetWidth: 64))
        let left = try rgbAt(lr, x: 16, y: 24)
        let right = try rgbAt(lr, x: 48, y: 24)
        assertRed(left.r, left.g, left.b)
        assertBlue(right.r, right.g, right.b)

        let topBottom = try XCTUnwrap(
            make420fSplit(width: 64, height: 48, split: .topBottom, leftOrTop: (76, 85, 255), rightOrBottom: (29, 255, 107))
        )
        let tb = try XCTUnwrap(scaler.cgImage(from: topBottom, targetWidth: 64))
        let top = try rgbAt(tb, x: 32, y: 12)
        let bottom = try rgbAt(tb, x: 32, y: 36)
        assertRed(top.r, top.g, top.b)
        assertBlue(bottom.r, bottom.g, bottom.b)
    }

    func testDoesNotUpscale() throws {
        let scaler = PreviewScaler()
        let source = try XCTUnwrap(make420fSolid(width: 64, height: 48, y: 76, cb: 85, cr: 255))
        let image = try XCTUnwrap(scaler.cgImage(from: source, targetWidth: 400))
        XCTAssertEqual(image.width, 64)
        XCTAssertEqual(image.height, 48)
    }

    func testTargetWidthSixteenYieldsSixteenByTwelve() throws {
        let scaler = PreviewScaler()
        let source = try XCTUnwrap(make420fSolid(width: 64, height: 48, y: 76, cb: 85, cr: 255))
        let image = try XCTUnwrap(scaler.cgImage(from: source, targetWidth: 16))
        XCTAssertEqual(image.width, 16)
        XCTAssertEqual(image.height, 12)
    }

    func testNilSizedOrZeroTargetReturnsNil() throws {
        let scaler = PreviewScaler()
        let source = try XCTUnwrap(make420fSolid(width: 64, height: 48, y: 76, cb: 85, cr: 255))
        XCTAssertNil(scaler.cgImage(from: source, targetWidth: 0))
        XCTAssertNil(scaler.cgImage(from: source, targetWidth: -1))
    }
}

private enum Split {
    case leftRight
    case topBottom
}

private func make420fSolid(width: Int, height: Int, y: UInt8, cb: UInt8, cr: UInt8) -> CVPixelBuffer? {
    make420f(width: width, height: height) { col, row in
        _ = col
        _ = row
        return (y, cb, cr)
    }
}

private func make420fSplit(
    width: Int,
    height: Int,
    split: Split,
    leftOrTop: (UInt8, UInt8, UInt8),
    rightOrBottom: (UInt8, UInt8, UInt8)
) -> CVPixelBuffer? {
    make420f(width: width, height: height) { col, row in
        let first: Bool
        switch split {
        case .leftRight: first = col < width / 2
        case .topBottom: first = row < height / 2
        }
        return first ? leftOrTop : rightOrBottom
    }
}

private func make420f(
    width: Int,
    height: Int,
    sample: (_ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8)
) -> CVPixelBuffer? {
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
    let uvBytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
    guard let yBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 0),
          let uvBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)
    else { return nil }

    for row in 0 ..< height {
        let rowPtr = yBase.advanced(by: row * yBytes).assumingMemoryBound(to: UInt8.self)
        for col in 0 ..< width {
            rowPtr[col] = sample(col, row).0
        }
    }
    for row in 0 ..< (height / 2) {
        let rowPtr = uvBase.advanced(by: row * uvBytes).assumingMemoryBound(to: UInt8.self)
        for col in 0 ..< (width / 2) {
            let luma = sample(col * 2, row * 2)
            rowPtr[col * 2] = luma.1
            rowPtr[col * 2 + 1] = luma.2
        }
    }
    return buffer
}

private func rgbaPixels(_ image: CGImage) -> [UInt8] {
    let width = image.width
    let height = image.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
    pixels.withUnsafeMutableBytes { raw in
        guard let ctx = CGContext(
            data: raw.baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else { return }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }
    return pixels
}

/// `CGImage.cropping` の原点は左上。1×1 なので読み出しの Y 反転で誤判定しない。
private func rgbAt(_ image: CGImage, x: Int, y: Int) throws -> (r: UInt8, g: UInt8, b: UInt8) {
    let cropped = try XCTUnwrap(image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)))
    var pixel = [UInt8](repeating: 0, count: 4)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    try pixel.withUnsafeMutableBytes { raw in
        let ctx = try XCTUnwrap(CGContext(
            data: raw.baseAddress,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: 1, height: 1))
    }
    return (pixel[0], pixel[1], pixel[2])
}

private func assertRed(_ r: UInt8, _ g: UInt8, _ b: UInt8, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertGreaterThanOrEqual(Int(r), 249, file: file, line: line)
    XCTAssertLessThanOrEqual(Int(g), 6, file: file, line: line)
    XCTAssertLessThanOrEqual(Int(b), 6, file: file, line: line)
}

private func assertBlue(_ r: UInt8, _ g: UInt8, _ b: UInt8, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertLessThanOrEqual(Int(r), 6, file: file, line: line)
    XCTAssertLessThanOrEqual(Int(g), 6, file: file, line: line)
    XCTAssertGreaterThanOrEqual(Int(b), 249, file: file, line: line)
}
