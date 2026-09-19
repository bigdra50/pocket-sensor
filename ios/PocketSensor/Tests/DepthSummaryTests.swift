import XCTest
@testable import PocketSensor

/// 深度画像の中央パッチの中央値（純粋）。
final class DepthSummaryTests: XCTestCase {
    func testCenterMedianIgnoresInvalidZeros() {
        // 8×4 の深度。中央 1/4 のパッチ（2×1）は列 3..4、行 1..2 のうち行 1 → 値 2.0 と 0（無効）
        let width = 8, height = 4
        var depth = [Float](repeating: 1.0, count: width * height)
        depth[1 * width + 3] = 2.0
        depth[1 * width + 4] = 0.0
        XCTAssertEqual(DepthSummary.centerMedian(depth: depth, width: width, height: height, fraction: 0.25), 2.0)
    }

    func testCenterMedianIsNilWhenPatchHasNoValidPixel() {
        let depth = [Float](repeating: 0.0, count: 256 * 192)
        XCTAssertNil(DepthSummary.centerMedian(depth: depth, width: 256, height: 192, fraction: 0.125))
    }

    func testCenterPatchOfLiDARResolutionIs32By24() {
        var depth = [Float](repeating: 5.0, count: 256 * 192)
        // 中央 32×24（行 84..107、列 112..143）だけ 1.5 にすると中央値は 1.5
        for row in 84..<108 {
            for col in 112..<144 {
                depth[row * 256 + col] = 1.5
            }
        }
        XCTAssertEqual(DepthSummary.centerMedian(depth: depth, width: 256, height: 192, fraction: 0.125), 1.5)
    }

    func testConfidenceFilterDropsLowConfidencePixels() {
        let width = 4, height = 4
        let depth: [Float] = Array(repeating: 3.0, count: 16)
        var confidence = [UInt8](repeating: 2, count: 16)
        // 中央 2×2 のうち 3 画素を低信頼にすると、残り 1 画素の 3.0 が中央値
        confidence[1 * width + 1] = 0
        confidence[1 * width + 2] = 1
        confidence[2 * width + 1] = 0
        XCTAssertEqual(
            DepthSummary.centerMedian(depth: depth, confidence: confidence, width: width, height: height, fraction: 0.5),
            3.0
        )
        confidence[2 * width + 2] = 1
        XCTAssertNil(
            DepthSummary.centerMedian(depth: depth, confidence: confidence, width: width, height: height, fraction: 0.5)
        )
    }
}
