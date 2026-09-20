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

    func testRpyDegreesIdentityIsZero() {
        let q = simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)
        let rpy = Frames.rpyDegrees(from: q)
        XCTAssertEqual(rpy.roll, 0, accuracy: 1e-9)
        XCTAssertEqual(rpy.pitch, 0, accuracy: 1e-9)
        XCTAssertEqual(rpy.yaw, 0, accuracy: 1e-9)
    }

    func testRpyDegreesPlus90Yaw() {
        let q = Frames.quaternion(roll: 0, pitch: 0, yaw: .pi / 2)
        let rpy = Frames.rpyDegrees(from: q)
        XCTAssertEqual(rpy.roll, 0, accuracy: 1e-9)
        XCTAssertEqual(rpy.pitch, 0, accuracy: 1e-9)
        XCTAssertEqual(rpy.yaw, 90, accuracy: 1e-9)
    }

    func testRpyDegreesPlus90Roll() {
        let q = Frames.quaternion(roll: .pi / 2, pitch: 0, yaw: 0)
        let rpy = Frames.rpyDegrees(from: q)
        XCTAssertEqual(rpy.roll, 90, accuracy: 1e-9)
        XCTAssertEqual(rpy.pitch, 0, accuracy: 1e-9)
        XCTAssertEqual(rpy.yaw, 0, accuracy: 1e-9)
    }

    func testRpyDegreesMinus45Pitch() {
        let q = Frames.quaternion(roll: 0, pitch: -.pi / 4, yaw: 0)
        let rpy = Frames.rpyDegrees(from: q)
        XCTAssertEqual(rpy.roll, 0, accuracy: 1e-9)
        XCTAssertEqual(rpy.pitch, -45, accuracy: 1e-9)
        XCTAssertEqual(rpy.yaw, 0, accuracy: 1e-9)
    }

    func testRpyDegreesRoundtripOfComposedQuaternion() {
        let roll = 12.5 * .pi / 180
        let pitch = -45.0 * .pi / 180
        let yaw = 30.0 * .pi / 180
        let q = Frames.quaternion(roll: roll, pitch: pitch, yaw: yaw)
        let rpy = Frames.rpyDegrees(from: q)
        XCTAssertEqual(rpy.roll, 12.5, accuracy: 1e-9)
        XCTAssertEqual(rpy.pitch, -45.0, accuracy: 1e-9)
        XCTAssertEqual(rpy.yaw, 30.0, accuracy: 1e-9)
    }

    func testRpyDegreesGimbalLockDoesNotProduceNaNAndClampsPitch() {
        let plus = Frames.rpyDegrees(from: Frames.quaternion(roll: 0, pitch: .pi / 2, yaw: 0))
        XCTAssertFalse(plus.roll.isNaN)
        XCTAssertFalse(plus.pitch.isNaN)
        XCTAssertFalse(plus.yaw.isNaN)
        XCTAssertEqual(plus.pitch, 90, accuracy: 1e-6)
        XCTAssertLessThanOrEqual(plus.pitch, 90)
        XCTAssertGreaterThanOrEqual(plus.pitch, -90)

        let minus = Frames.rpyDegrees(from: Frames.quaternion(roll: 0, pitch: -.pi / 2, yaw: 0))
        XCTAssertFalse(minus.roll.isNaN)
        XCTAssertFalse(minus.yaw.isNaN)
        XCTAssertEqual(minus.pitch, -90, accuracy: 1e-6)

        let yaw180 = Frames.rpyDegrees(from: Frames.quaternion(roll: 0, pitch: 0, yaw: .pi))
        XCTAssertGreaterThan(yaw180.yaw, -180)
        XCTAssertLessThanOrEqual(yaw180.yaw, 180)
        XCTAssertEqual(yaw180.yaw, 180, accuracy: 1e-9)
    }
}
