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
}
