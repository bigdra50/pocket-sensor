import Foundation
import PocketSensorCore
import simd
import XCTest

final class IntrinsicsTests: XCTestCase {
    func testEveryIntrinsicsVector() throws {
        let payload = try VectorFiles.json("intrinsics.json")
        let src = try XCTUnwrap(payload["source"] as? [String: Any])
        let source = Intrinsics(
            width: jsonInt(try XCTUnwrap(src["width"])),
            height: jsonInt(try XCTUnwrap(src["height"])),
            fx: jsonDouble(try XCTUnwrap(src["fx"])),
            fy: jsonDouble(try XCTUnwrap(src["fy"])),
            cx: jsonDouble(try XCTUnwrap(src["cx"])),
            cy: jsonDouble(try XCTUnwrap(src["cy"]))
        )

        let scaled = source.scaled(toWidth: 256, height: 192)
        let expect = try XCTUnwrap(payload["scale_256x192"] as? [String: Any])
        XCTAssertEqual(scaled.width, jsonInt(try XCTUnwrap(expect["width"])))
        XCTAssertEqual(scaled.height, jsonInt(try XCTUnwrap(expect["height"])))
        XCTAssertEqual(scaled.fx, jsonDouble(try XCTUnwrap(expect["fx"])), accuracy: 1e-9)
        XCTAssertEqual(scaled.fy, jsonDouble(try XCTUnwrap(expect["fy"])), accuracy: 1e-9)
        XCTAssertEqual(scaled.cx, jsonDouble(try XCTUnwrap(expect["cx"])), accuracy: 1e-9)
        XCTAssertEqual(scaled.cy, jsonDouble(try XCTUnwrap(expect["cy"])), accuracy: 1e-9)

        let half = source.scaled(toWidth: 960, height: 720)
        let expectHalf = try XCTUnwrap(payload["scale_960x720"] as? [String: Any])
        XCTAssertEqual(half.fx, jsonDouble(try XCTUnwrap(expectHalf["fx"])), accuracy: 1e-9)
        XCTAssertEqual(half.cx, jsonDouble(try XCTUnwrap(expectHalf["cx"])), accuracy: 1e-9)

        let info = try XCTUnwrap(payload["camera_info_256x192"] as? [String: Any])
        XCTAssertEqualDoubles(scaled.k, jsonDoubles(try XCTUnwrap(info["k"])), accuracy: 1e-9)
        XCTAssertEqualDoubles(scaled.r, jsonDoubles(try XCTUnwrap(info["r"])), accuracy: 1e-9)
        XCTAssertEqualDoubles(scaled.p, jsonDoubles(try XCTUnwrap(info["p"])), accuracy: 1e-9)
        XCTAssertEqualDoubles(scaled.d, jsonDoubles(try XCTUnwrap(info["d"])), accuracy: 1e-9)
    }

    func testArkitMatrixIsColumnMajor() {
        let m = simd_double3x3(columns: (
            SIMD3(1500.5, 0, 0),
            SIMD3(0, 1510.25, 0),
            SIMD3(959.5, 719.5, 1)
        ))
        let intrinsics = Intrinsics(arkitMatrix: m, width: 1920, height: 1440)
        XCTAssertEqual(intrinsics.fx, 1500.5)
        XCTAssertEqual(intrinsics.fy, 1510.25)
        XCTAssertEqual(intrinsics.cx, 959.5)
        XCTAssertEqual(intrinsics.cy, 719.5)
    }
}
