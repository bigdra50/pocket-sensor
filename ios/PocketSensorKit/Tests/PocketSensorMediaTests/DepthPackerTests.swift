import CoreVideo
import Darwin
import PocketSensorCore
import PocketSensorMedia
import XCTest

final class DepthPackerTests: XCTestCase {
    func testDepthPaddingNaNZeroAndOverRangeBecomeZero() throws {
        let width = 4
        let height = 2
        let buffer = try XCTUnwrap(makeDepthBuffer(width: width, height: height, extraRowBytes: 16))
        XCTAssertGreaterThan(CVPixelBufferGetBytesPerRow(buffer), width * 4)

        CVPixelBufferLockBaseAddress(buffer, [])
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer))
        func write(_ row: Int, _ col: Int, _ value: Float) {
            base.advanced(by: row * bytesPerRow + col * 4).storeBytes(of: value, as: Float.self)
        }
        write(0, 0, 1.5)
        write(0, 1, .nan)
        write(0, 2, 0)
        write(0, 3, 70)
        write(1, 0, -0.1)
        write(1, 1, 65.535)
        write(1, 2, 2.0)
        write(1, 3, 0.001)
        CVPixelBufferUnlockBaseAddress(buffer, [])

        let packed = try XCTUnwrap(DepthPacker.depth16(from: buffer))
        XCTAssertEqual(packed.width, width)
        XCTAssertEqual(packed.height, height)
        let samples: [UInt16] = packed.data.withUnsafeBytes { Array($0.bindMemory(to: UInt16.self)) }
        XCTAssertEqual(samples, [1500, 0, 0, 0, 0, 0, 2000, 1])
    }

    func testConfidencePacksOneComponent8WithRowPadding() throws {
        let width = 3
        let height = 2
        var buffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferBytesPerRowAlignmentKey: 64]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_OneComponent8,
            attrs as CFDictionary,
            &buffer
        )
        XCTAssertEqual(status, kCVReturnSuccess)
        let pixelBuffer = try XCTUnwrap(buffer)
        XCTAssertGreaterThan(CVPixelBufferGetBytesPerRow(pixelBuffer), width)

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixelBuffer))
        memset(base, 9, bytesPerRow * height)
        let row0 = base.assumingMemoryBound(to: UInt8.self)
        row0[0] = 0
        row0[1] = 1
        row0[2] = 2
        let row1 = base.advanced(by: bytesPerRow).assumingMemoryBound(to: UInt8.self)
        row1[0] = 2
        row1[1] = 1
        row1[2] = 0
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

        let packed = try XCTUnwrap(DepthPacker.confidence8(from: pixelBuffer))
        XCTAssertEqual(packed.width, width)
        XCTAssertEqual(packed.height, height)
        XCTAssertEqual(Array(packed.data), [0, 1, 2, 2, 1, 0])
    }
}

private func makeDepthBuffer(width: Int, height: Int, extraRowBytes: Int) -> CVPixelBuffer? {
    let attrs: [CFString: Any] = [kCVPixelBufferBytesPerRowAlignmentKey: 64]
    var buffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(
        kCFAllocatorDefault,
        width,
        height,
        kCVPixelFormatType_DepthFloat32,
        attrs as CFDictionary,
        &buffer
    )
    guard status == kCVReturnSuccess else { return nil }
    return buffer
}
