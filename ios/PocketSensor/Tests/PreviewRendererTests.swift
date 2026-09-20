import ARKit
import CoreVideo
import simd
import UIKit
import XCTest
@testable import PocketSensor

final class PreviewRendererTests: XCTestCase {
    func testSubmitDeliversRgbAndDepthFromTheSameSample() throws {
        let renderer = PreviewRenderer()
        let color = try XCTUnwrap(make420fSolid(width: 64, height: 48, y: 76, cb: 85, cr: 255))
        let depth = try XCTUnwrap(makeDepthFloat32(width: 16, height: 12, fill: 1.0))
        let sample = makeSample(timestamp: 1.0, color: color, depth: depth)
        let exp = expectation(description: "pair")
        renderer.submit(sample) { pair in
            XCTAssertNotNil(pair.rgb)
            XCTAssertNotNil(pair.depth)
            XCTAssertEqual(Int(pair.rgb?.size.width.rounded() ?? 0), 64)
            XCTAssertEqual(Int(pair.rgb?.size.height.rounded() ?? 0), 48)
            XCTAssertEqual(Int(pair.depth?.size.width.rounded() ?? 0), 16)
            XCTAssertEqual(Int(pair.depth?.size.height.rounded() ?? 0), 12)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2.0)
    }

    func testSubmitDeliversRgbWhenDepthIsMissing() throws {
        let renderer = PreviewRenderer()
        let color = try XCTUnwrap(make420fSolid(width: 32, height: 24, y: 76, cb: 85, cr: 255))
        let sample = makeSample(timestamp: 1.0, color: color, depth: nil)
        let exp = expectation(description: "pair")
        renderer.submit(sample) { pair in
            XCTAssertNotNil(pair.rgb)
            XCTAssertNil(pair.depth)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2.0)
    }

    func testCloseTimestampsSkipWhileTheFirstPairIsInFlightOrTooSoon() throws {
        let renderer = PreviewRenderer()
        let color = try XCTUnwrap(make420fSolid(width: 32, height: 24, y: 76, cb: 85, cr: 255))
        let first = makeSample(timestamp: 0, color: color, depth: nil)
        let tooSoon = makeSample(timestamp: 1.0 / 60.0, color: color, depth: nil)
        let exp = expectation(description: "first")
        exp.expectedFulfillmentCount = 1
        renderer.submit(first) { _ in exp.fulfill() }
        renderer.submit(tooSoon) { _ in
            XCTFail("1/60 s later must not produce a second pair")
        }
        wait(for: [exp], timeout: 2.0)
    }
}

private func makeSample(timestamp: TimeInterval, color: CVPixelBuffer, depth: CVPixelBuffer?) -> ARFrameSample {
    ARFrameSample(
        index: 1,
        timestamp: timestamp,
        arrivalMediaTime: timestamp,
        cameraTransform: matrix_identity_float4x4,
        intrinsics: matrix_identity_float3x3,
        imageResolution: CGSize(
            width: CVPixelBufferGetWidth(color),
            height: CVPixelBufferGetHeight(color)
        ),
        trackingState: .normal,
        capturedImage: color,
        depthMap: depth,
        confidenceMap: nil,
        imageAnchors: []
    )
}

private func make420fSolid(width: Int, height: Int, y: UInt8, cb: UInt8, cr: UInt8) -> CVPixelBuffer? {
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
            rowPtr[col] = y
        }
    }
    for row in 0 ..< (height / 2) {
        let rowPtr = uvBase.advanced(by: row * uvBytes).assumingMemoryBound(to: UInt8.self)
        for col in 0 ..< (width / 2) {
            rowPtr[col * 2] = cb
            rowPtr[col * 2 + 1] = cr
        }
    }
    return buffer
}

private func makeDepthFloat32(width: Int, height: Int, fill: Float) -> CVPixelBuffer? {
    var buffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(
        kCFAllocatorDefault,
        width,
        height,
        kCVPixelFormatType_DepthFloat32,
        nil,
        &buffer
    )
    guard status == kCVReturnSuccess, let buffer else { return nil }
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
    guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
    for row in 0 ..< height {
        let rowPtr = base.advanced(by: row * bytesPerRow).assumingMemoryBound(to: Float.self)
        for col in 0 ..< width {
            rowPtr[col] = fill
        }
    }
    return buffer
}
