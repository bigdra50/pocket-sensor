import UIKit
import XCTest
@testable import PocketSensor

final class DepthPreviewTests: XCTestCase {
    func testDisplayOrientationTurnsSensorImageUprightForEachInterfaceOrientation() {
        // 深度マップは画面の向きによらず、カメラ群を上にした横持ち（landscapeRight）の並びで届く
        XCTAssertEqual(DepthPreview.displayOrientation(for: .landscapeRight), .up)
        XCTAssertEqual(DepthPreview.displayOrientation(for: .landscapeLeft), .down)
        XCTAssertEqual(DepthPreview.displayOrientation(for: .portrait), .right)
        XCTAssertEqual(DepthPreview.displayOrientation(for: .portraitUpsideDown), .left)
    }

    func testDisplayOrientationKeepsSensorOrientationWhenUnknown() {
        XCTAssertEqual(DepthPreview.displayOrientation(for: .unknown), .up)
    }

    func testFrameSizeKeepsSensorAspectAndTurnsTallWhenSideways() {
        // 深度マップは 256×192（4:3）。長辺を指定し、横倒しで表示するときだけ縦長にする
        XCTAssertEqual(DepthPreview.frameSize(long: 200, for: .up), CGSize(width: 200, height: 150))
        XCTAssertEqual(DepthPreview.frameSize(long: 200, for: .down), CGSize(width: 200, height: 150))
        XCTAssertEqual(DepthPreview.frameSize(long: 160, for: .right), CGSize(width: 120, height: 160))
        XCTAssertEqual(DepthPreview.frameSize(long: 160, for: .left), CGSize(width: 120, height: 160))
    }

    func testLandscapeTilesAt140Fit288Points() {
        let size = DepthPreview.frameSize(long: 140, for: .up)
        XCTAssertEqual(size, CGSize(width: 140, height: 105))
        XCTAssertEqual(size.width * 2 + 8, 288)
    }

    func testPortraitTilesAt168Are126By168AndFit260Points() {
        let size = DepthPreview.frameSize(long: 168, for: .right)
        XCTAssertEqual(size, CGSize(width: 126, height: 168))
        XCTAssertEqual(size.width * 2 + 8, 260)
    }

    func testFittedLongKeepsPreferredWhenWidthIsAmple() {
        XCTAssertEqual(
            DepthPreview.fittedLong(preferred: 140, availableWidth: 352, spacing: 8, for: .up),
            140
        )
        XCTAssertEqual(
            DepthPreview.fittedLong(preferred: 168, availableWidth: 354, spacing: 8, for: .right),
            168
        )
    }

    func testFittedLongShrinksRatherThanOverflowing() {
        XCTAssertEqual(
            DepthPreview.fittedLong(preferred: 140, availableWidth: 200, spacing: 8, for: .up),
            96
        )
        XCTAssertEqual(
            DepthPreview.fittedLong(preferred: 168, availableWidth: 200, spacing: 8, for: .right),
            128
        )
    }

    func testReorientedImageSwapsWidthAndHeightOnlyWhenTurnedSideways() {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let sensor = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 3), format: format).image { _ in }

        let sideways = DepthPreview.reoriented(sensor, to: .right)
        let upsideDown = DepthPreview.reoriented(sensor, to: .down)

        XCTAssertEqual(sideways.imageOrientation, .right)
        XCTAssertEqual(sideways.size, CGSize(width: 3, height: 4))
        XCTAssertEqual(upsideDown.imageOrientation, .down)
        XCTAssertEqual(upsideDown.size, CGSize(width: 4, height: 3))
    }

    func testHeatNearIsRedFarIsBlue() {
        let near = DepthPreview.heat(0)
        let far = DepthPreview.heat(1)
        XCTAssertEqual(near.0, 255)
        XCTAssertEqual(near.1, 0)
        XCTAssertEqual(near.2, 0)
        XCTAssertEqual(far.0, 0)
        XCTAssertEqual(far.1, 0)
        XCTAssertEqual(far.2, 255)
    }

    func testRgbaMarksInvalidAsBlack() {
        let depth: [Float] = [0, .nan, 1.0, 0.25]
        let pixels = DepthPreview.rgba(depth: depth, width: 2, height: 2, nearM: 0.25, farM: 4.0)
        // (0,0) 無効 → 黒で不透明
        XCTAssertEqual(Array(pixels[0..<4]), [0, 0, 0, 255])
        // (1,0) NaN → 黒
        XCTAssertEqual(Array(pixels[4..<8]), [0, 0, 0, 255])
        // (0,1) 中間深度 → どれか色チャンネルが立つ
        XCTAssertEqual(pixels[11], 255)
        XCTAssertTrue(pixels[8] > 0 || pixels[9] > 0 || pixels[10] > 0)
        // (1,1) 近端 → 赤
        XCTAssertEqual(Array(pixels[12..<16]), [255, 0, 0, 255])
    }

    func testDemoGradientIsLidarSizedAndNotEmpty() {
        let image = DepthPreview.demoGradient()
        XCTAssertEqual(Int(image.size.width.rounded()), 256)
        XCTAssertEqual(Int(image.size.height.rounded()), 192)
        XCTAssertNotNil(image.cgImage)
    }

    func testDemoColorBarsIsLidarAspectAndAsymmetric() throws {
        let image = DepthPreview.demoColorBars()
        XCTAssertEqual(Int(image.size.width.rounded()), 256)
        XCTAssertEqual(Int(image.size.height.rounded()), 192)
        let cgImage = try XCTUnwrap(image.cgImage)
        let topLeft = try rgbAt(cgImage, x: 2, y: 2)
        XCTAssertEqual(topLeft.r, 255)
        XCTAssertEqual(topLeft.g, 255)
        XCTAssertEqual(topLeft.b, 255)
        let topRight = try rgbAt(cgImage, x: 250, y: 2)
        XCTAssertFalse(topRight.r == 255 && topRight.g == 255 && topRight.b == 255)
        let bottomLeft = try rgbAt(cgImage, x: 2, y: 180)
        XCTAssertFalse(bottomLeft.r == 255 && bottomLeft.g == 255 && bottomLeft.b == 255)
    }
}

/// `CGImage.cropping` の原点は左上。
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
