import Foundation
import PocketSensorCore
import simd
import XCTest

final class FramesTests: XCTestCase {
    func testEveryFramesVector() throws {
        let payload = try VectorFiles.json("frames.json")
        let cases = try XCTUnwrap(payload["cases"] as? [[String: Any]])
        for item in cases {
            let name = try XCTUnwrap(item["name"] as? String)
            let transform = matrix4x4(rowMajor: jsonDoubles(try XCTUnwrap(item["transform"])))
            let expectedP = jsonDoubles(try XCTUnwrap(item["position"]))
            let expectedQ = jsonDoubles(try XCTUnwrap(item["quaternion_xyzw"]))
            let (position, quat) = Frames.arkitPoseToREP103(transform)
            XCTAssertEqual(position.x, expectedP[0], accuracy: 1e-9, name)
            XCTAssertEqual(position.y, expectedP[1], accuracy: 1e-9, name)
            XCTAssertEqual(position.z, expectedP[2], accuracy: 1e-9, name)
            XCTAssertEqual(quat.vector.x, expectedQ[0], accuracy: 1e-9, name)
            XCTAssertEqual(quat.vector.y, expectedQ[1], accuracy: 1e-9, name)
            XCTAssertEqual(quat.vector.z, expectedQ[2], accuracy: 1e-9, name)
            XCTAssertEqual(quat.vector.w, expectedQ[3], accuracy: 1e-9, name)
            if name == "w_zero_180_z" {
                XCTAssertEqual(quat.vector.w, 0, accuracy: 1e-12)
                let first = [quat.vector.x, quat.vector.y, quat.vector.z].first { $0 != 0 }
                XCTAssertGreaterThan(try XCTUnwrap(first), 0)
            }
        }

        let staticTransforms = try XCTUnwrap(payload["static_transforms"] as? [String: Any])
        let color = try XCTUnwrap(staticTransforms["link_to_color_optical"] as? [String: Any])
        let imu = try XCTUnwrap(staticTransforms["link_to_imu"] as? [String: Any])
        let colorQ = jsonDoubles(try XCTUnwrap(color["quaternion_xyzw"]))
        let imuQ = jsonDoubles(try XCTUnwrap(imu["quaternion_xyzw"]))
        XCTAssertEqual(Frames.linkToColorOptical.vector.x, colorQ[0], accuracy: 1e-9)
        XCTAssertEqual(Frames.linkToColorOptical.vector.y, colorQ[1], accuracy: 1e-9)
        XCTAssertEqual(Frames.linkToColorOptical.vector.z, colorQ[2], accuracy: 1e-9)
        XCTAssertEqual(Frames.linkToColorOptical.vector.w, colorQ[3], accuracy: 1e-9)
        XCTAssertEqual(Frames.linkToImu.vector.x, imuQ[0], accuracy: 1e-9)
        XCTAssertEqual(Frames.linkToImu.vector.y, imuQ[1], accuracy: 1e-9)
        XCTAssertEqual(Frames.linkToImu.vector.z, imuQ[2], accuracy: 1e-9)
        XCTAssertEqual(Frames.linkToImu.vector.w, imuQ[3], accuracy: 1e-9)
    }

    func testCanonicalFlipsNegativeW() {
        let q = Frames.canonical(simd_quatd(ix: 0, iy: 0, iz: 0, r: -1))
        XCTAssertEqual(q.vector.w, 1, accuracy: 1e-12)
    }
}
