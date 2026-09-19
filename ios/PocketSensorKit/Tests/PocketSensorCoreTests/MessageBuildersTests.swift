import Foundation
import PocketSensorCore
import simd
import XCTest

final class MessageBuildersTests: XCTestCase {
    private let names = FrameNames(deviceName: "phone")
    private let stampNs: UInt64 = 1_000_000_002

    func testFrameNamesReplaceDevicePlaceholder() {
        XCTAssertEqual(names.odom, "phone_odom")
        XCTAssertEqual(names.link, "phone_link")
        XCTAssertEqual(names.colorOptical, "phone_color_optical_frame")
        XCTAssertEqual(names.imuLink, "phone_imu_link")
        XCTAssertEqual(names.anchorFrame(imageName: "gate"), "phone_anchor_gate")
        XCTAssertEqual(names.resolve("/<name>/odom"), "/phone/odom")
        let spec = Contract.channels.first { $0.key == "odom" }!
        XCTAssertEqual(names.topic(spec), "/phone/odom")
    }

    func testOdometryAndTfSharePoseAndCovarianceConventions() {
        var transform = matrix4x4(rowMajor: [
            1, 0, 0, 0,
            0, 1, 0, 0,
            0, 0, 1, 0,
            0, 0, 0, 1,
        ])
        transform.columns.3 = SIMD4(0, 1, 0, 1)
        let pose = PoseInput(
            cameraTransform: transform,
            state: .normal,
            reason: .none,
            originEpoch: 3
        )
        let odom = MessageBuilders.odometry(stampNs: stampNs, names: names, pose: pose)
        XCTAssertEqual(odom.header.frameId, "phone_odom")
        XCTAssertEqual(odom.childFrameId, "phone_link")
        XCTAssertEqual(odom.header.stamp.sec, 1)
        XCTAssertEqual(odom.header.stamp.nanosec, 2)
        XCTAssertEqual(odom.pose.covariance, Array(repeating: 0.0, count: 36))
        XCTAssertEqual(odom.twist.twist.linear.x, 0)
        XCTAssertEqual(odom.twist.covariance[0], -1)
        XCTAssertEqual(odom.twist.covariance[1], 0)

        let expected = Frames.arkitPoseToREP103(transform)
        XCTAssertEqual(odom.pose.pose.position.x, expected.position.x, accuracy: 1e-12)
        XCTAssertEqual(odom.pose.pose.orientation.w, expected.orientation.vector.w, accuracy: 1e-12)

        let tf = MessageBuilders.tf(stampNs: stampNs, names: names, pose: pose)
        XCTAssertEqual(tf.transforms.count, 1)
        XCTAssertEqual(tf.transforms[0].header.frameId, "phone_odom")
        XCTAssertEqual(tf.transforms[0].childFrameId, "phone_link")
        XCTAssertEqual(tf.transforms[0].transform.translation.x, odom.pose.pose.position.x, accuracy: 1e-12)

        let tracking = MessageBuilders.tracking(stampNs: stampNs, names: names, pose: pose)
        XCTAssertEqual(tracking.header.frameId, "phone_link")
        XCTAssertEqual(tracking.state, TrackingState.normal.rawValue)
        XCTAssertEqual(tracking.originEpoch, 3)
    }

    func testTfStaticUsesFixedRotations() {
        let msg = MessageBuilders.tfStatic(stampNs: stampNs, names: names)
        XCTAssertEqual(msg.transforms.count, 2)
        XCTAssertEqual(msg.transforms[0].header.frameId, "phone_link")
        XCTAssertEqual(msg.transforms[0].childFrameId, "phone_color_optical_frame")
        XCTAssertEqual(msg.transforms[0].transform.translation.x, 0)
        XCTAssertEqual(msg.transforms[0].transform.rotation.x, Frames.linkToColorOptical.vector.x, accuracy: 1e-12)
        XCTAssertEqual(msg.transforms[1].childFrameId, "phone_imu_link")
        XCTAssertEqual(msg.transforms[1].transform.rotation.y, Frames.linkToImu.vector.y, accuracy: 1e-12)
    }

    func testAnchorTFUsesSameSimilarityAsCamera() {
        var transform = matrix4x4(rowMajor: Array(repeating: 0.0, count: 16))
        transform.columns.0 = SIMD4(1, 0, 0, 0)
        transform.columns.1 = SIMD4(0, 1, 0, 0)
        transform.columns.2 = SIMD4(0, 0, 1, 0)
        transform.columns.3 = SIMD4(1, 0, 0, 1)
        let msg = MessageBuilders.anchorTF(
            stampNs: stampNs,
            names: names,
            imageName: "door",
            anchorTransform: transform
        )
        let expected = Frames.arkitPoseToREP103(transform)
        XCTAssertEqual(msg.transforms[0].childFrameId, "phone_anchor_door")
        XCTAssertEqual(msg.transforms[0].transform.translation.x, expected.position.x, accuracy: 1e-12)
    }

    func testTfWithAnchorsPutsThePoseFirstAndSharesTheStamp() {
        var anchor = matrix_identity_double4x4
        anchor.columns.3 = SIMD4(0, 1, -2, 1)
        let pose = PoseInput(cameraTransform: matrix_identity_double4x4, state: .normal, reason: .none, originEpoch: 0)

        let poseOnly = MessageBuilders.tfWithAnchors(stampNs: stampNs, names: names, pose: pose, anchors: [])
        XCTAssertEqual(poseOnly.transforms.map(\.childFrameId), ["phone_link"])

        let both = MessageBuilders.tfWithAnchors(
            stampNs: stampNs, names: names, pose: pose, anchors: [("door", anchor), ("dock", anchor)]
        )
        XCTAssertEqual(both.transforms.map(\.childFrameId), ["phone_link", "phone_anchor_door", "phone_anchor_dock"])
        for transform in both.transforms {
            XCTAssertEqual(transform.header.stamp, both.transforms[0].header.stamp)
            XCTAssertEqual(transform.header.frameId, "phone_odom")
        }
    }

    func testImuRawAndFusedConventions() {
        let raw = MessageBuilders.imuRaw(
            stampNs: stampNs,
            names: names,
            accelG: SIMD3(0, 0, -1),
            gyroRadS: SIMD3(0.5, -0.25, 0.125)
        )
        XCTAssertEqual(raw.header.frameId, "phone_imu_link")
        XCTAssertEqual(raw.orientation.w, 1)
        XCTAssertEqual(raw.orientationCovariance[0], -1)
        XCTAssertEqual(raw.linearAcceleration.z, Units.standardGravity, accuracy: 1e-12)

        let attitude = simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)
        let fusedArb = MessageBuilders.imuFused(
            stampNs: stampNs,
            names: names,
            attitudeDeviceToReference: attitude,
            reference: .arbitrary,
            userAccelG: SIMD3(0, 0, 0),
            gravityG: SIMD3(0, 0, -1),
            rotationRateRadS: SIMD3(0, 0, 0)
        )
        XCTAssertEqual(fusedArb.orientation.w, 1, accuracy: 1e-12)
        XCTAssertEqual(fusedArb.linearAcceleration.z, Units.standardGravity, accuracy: 1e-12)

        let fusedNorth = MessageBuilders.imuFused(
            stampNs: stampNs,
            names: names,
            attitudeDeviceToReference: attitude,
            reference: .trueNorth,
            userAccelG: .zero,
            gravityG: SIMD3(0, 0, -1),
            rotationRateRadS: .zero
        )
        let expected = Frames.canonical(Frames.quaternion(roll: 0, pitch: 0, yaw: .pi / 2) * attitude)
        XCTAssertEqual(fusedNorth.orientation.z, expected.vector.z, accuracy: 1e-12)
        XCTAssertEqual(fusedNorth.orientation.w, expected.vector.w, accuracy: 1e-12)
    }

    func testNavSatNaNAltitudeAndBatteryUnknown() {
        let noFix = MessageBuilders.navSatFix(
            stampNs: stampNs,
            names: names,
            latitude: 35.0,
            longitude: 139.0,
            ellipsoidalAltitude: 10,
            horizontalAccuracy: -1,
            verticalAccuracy: 2
        )
        XCTAssertEqual(noFix.status.status, SensorMsgs.NavSatStatus.statusNoFix)
        XCTAssertEqual(noFix.status.service, 0)
        XCTAssertTrue(noFix.latitude.isNaN)
        XCTAssertTrue(noFix.longitude.isNaN)
        XCTAssertTrue(noFix.altitude.isNaN)

        let noAlt = MessageBuilders.navSatFix(
            stampNs: stampNs,
            names: names,
            latitude: 1,
            longitude: 2,
            ellipsoidalAltitude: 12,
            horizontalAccuracy: 3,
            verticalAccuracy: -0.5
        )
        XCTAssertEqual(noAlt.latitude, 1)
        XCTAssertEqual(noAlt.longitude, 2)
        XCTAssertTrue(noAlt.altitude.isNaN)
        XCTAssertEqual(noAlt.status.status, SensorMsgs.NavSatStatus.statusFix)

        let unknown = MessageBuilders.battery(stampNs: stampNs, level: -1, state: .unknown)
        XCTAssertTrue(unknown.percentage.isNaN)
        XCTAssertTrue(unknown.voltage.isNaN)
        XCTAssertEqual(unknown.powerSupplyTechnology, SensorMsgs.BatteryState.powerSupplyTechnologyLion)
        XCTAssertTrue(unknown.present)
        XCTAssertEqual(unknown.powerSupplyStatus, SensorMsgs.BatteryState.powerSupplyStatusUnknown)

        let discharging = MessageBuilders.battery(stampNs: stampNs, level: 0.5, state: .discharging)
        XCTAssertEqual(discharging.percentage, 0.5)
        XCTAssertEqual(discharging.powerSupplyStatus, SensorMsgs.BatteryState.powerSupplyStatusDischarging)
    }

    func testImagesAndCameraInfo() {
        let jpeg = Data([0xFF, 0xD8])
        let compressed = MessageBuilders.compressedImage(stampNs: stampNs, names: names, jpeg: jpeg)
        XCTAssertEqual(compressed.format, "jpeg")
        XCTAssertEqual(compressed.header.frameId, "phone_color_optical_frame")

        let depth = MessageBuilders.depthImage(
            stampNs: stampNs,
            names: names,
            width: 4,
            height: 2,
            data: Data(count: 16)
        )
        XCTAssertEqual(depth.encoding, "16UC1")
        XCTAssertEqual(depth.isBigendian, 0)
        XCTAssertEqual(depth.step, 8)

        let conf = MessageBuilders.confidenceImage(
            stampNs: stampNs,
            names: names,
            width: 4,
            height: 2,
            data: Data(count: 8)
        )
        XCTAssertEqual(conf.encoding, "mono8")
        XCTAssertEqual(conf.step, 4)

        let info = MessageBuilders.cameraInfo(
            stampNs: stampNs,
            names: names,
            intrinsics: Intrinsics(width: 1920, height: 1440, fx: 1500.5, fy: 1500.5, cx: 959.5, cy: 719.5)
        )
        XCTAssertEqual(info.distortionModel, "plumb_bob")
        XCTAssertEqual(info.d, [0, 0, 0, 0, 0])
        XCTAssertEqual(info.binningX, 0)
        XCTAssertEqual(info.roi.width, 0)
    }

    func testCompressedDepthAndConfidenceFormats() {
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        let depth = MessageBuilders.compressedDepth(stampNs: stampNs, names: names, png: png)
        XCTAssertEqual(depth.format, "16UC1; compressedDepth png")
        XCTAssertEqual(depth.header.frameId, "phone_color_optical_frame")
        XCTAssertEqual(depth.header.stamp.sec, 1)
        XCTAssertEqual(depth.header.stamp.nanosec, 2)
        XCTAssertEqual(Array(depth.data.prefix(12)), Array(repeating: UInt8(0), count: 12))
        XCTAssertEqual(Data(depth.data.dropFirst(12)), png)

        let conf = MessageBuilders.compressedConfidence(stampNs: stampNs, names: names, png: png)
        XCTAssertEqual(conf.format, "mono8; png compressed ")
        XCTAssertEqual(conf.format.last, " ")
        XCTAssertEqual(conf.header.frameId, "phone_color_optical_frame")
        XCTAssertEqual(conf.data, png)
    }

    func testTimeReferenceAndString() {
        let tr = MessageBuilders.timeReference(stampNs: stampNs, wallTimeNs: 9_000_000_007, source: "cllocation")
        XCTAssertEqual(tr.header.frameId, "")
        XCTAssertEqual(tr.timeRef.sec, 9)
        XCTAssertEqual(tr.timeRef.nanosec, 7)
        XCTAssertEqual(tr.source, "cllocation")
        XCTAssertEqual(MessageBuilders.string("hi").data, "hi")
    }

    func testRawImuPairerZeroOrderHold() {
        var pairer = RawImuPairer()
        XCTAssertNil(pairer.gyro(timestampS: 1.0, radS: SIMD3(1, 0, 0)))
        pairer.accel(timestampS: 1.0, g: SIMD3(0, 0, -1))
        let paired = pairer.gyro(timestampS: 1.02, radS: SIMD3(0.1, 0, 0))
        XCTAssertEqual(paired?.timestampS, 1.02)
        XCTAssertEqual(paired?.accelG.z, -1)
        XCTAssertNil(pairer.gyro(timestampS: 1.051, radS: SIMD3(0, 0, 0)))
    }

    func testBuildersMatchHandBuiltVectorBytes() throws {
        let cases = try loadCDRByName()
        let vectorNames = FrameNames(deviceName: "pocketsensor")

        var camera = MessageBuilders.cameraInfo(
            stampNs: 10_000_000_020,
            names: vectorNames,
            intrinsics: Intrinsics(width: 1920, height: 1440, fx: 1500.5, fy: 1500.5, cx: 959.5, cy: 719.5)
        )
        camera.header.frameId = "color_optical_frame"
        XCTAssertEqual(encodedCDR(camera), try XCTUnwrap(jsonHexData(try XCTUnwrap(cases["camera_info_plumb_bob"]))))

        let pixels = Data([
            0x01, 0x00, 0x02, 0x00, 0x03, 0x00, 0x04, 0x00,
            0x05, 0x00, 0x06, 0x00, 0x07, 0x00, 0x08, 0x00,
        ])
        var depth = MessageBuilders.depthImage(
            stampNs: 3_000_000_004,
            names: vectorNames,
            width: 4,
            height: 2,
            data: pixels
        )
        depth.header.frameId = "color_optical_frame"
        XCTAssertEqual(encodedCDR(depth), try XCTUnwrap(jsonHexData(try XCTUnwrap(cases["image_depth_16uc1"]))))

        var imu = MessageBuilders.imuRaw(
            stampNs: 1_000_000_002,
            names: vectorNames,
            accelG: SIMD3(0, 0, -9.5 / Units.standardGravity),
            gyroRadS: SIMD3(0.5, -0.25, 0.125)
        )
        imu.header.frameId = "imu_link"
        let imuBytes = try XCTUnwrap(jsonHexData(try XCTUnwrap(cases["imu_basic"])))
        var decoder = try CDRDecoder(data: imuBytes)
        let decoded = try SensorMsgs.Imu(from: &decoder)
        // 手で組んだベクトルは加速度の x, y を +0.0 で持ち、G 変換は 0.0 * -g で -0.0 になる。
        // Double の == は符号付き零を同一と見なすので、このケースはバイト列ではなく値で比べる。
        XCTAssertEqual(imu, decoded)
    }

    private func loadCDRByName() throws -> [String: String] {
        let root = try VectorFiles.json("cdr.json")
        let rows = try XCTUnwrap(root["cases"] as? [[String: Any]])
        var map: [String: String] = [:]
        for row in rows {
            map[try XCTUnwrap(row["name"] as? String)] = try XCTUnwrap(row["cdr_hex"] as? String)
        }
        return map
    }
}
