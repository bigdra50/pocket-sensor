import Foundation
import PocketSensorCore
import simd
import XCTest

final class SensorSnapshotTests: XCTestCase {
    func testMakeUsesREP103PoseMatchingOdometry() throws {
        var transform = simd_double4x4(1)
        transform.columns.3 = SIMD4(0, 1, 0, 1)
        let pose = PoseInput(
            cameraTransform: transform,
            state: .normal,
            reason: .none,
            originEpoch: 2
        )
        let odom = MessageBuilders.odometry(stampNs: 1, names: FrameNames(deviceName: "phone"), pose: pose)
        let snapshot = SensorSnapshot.make(fixture(cameraTransform: transform))
        let position = try XCTUnwrap(snapshot.positionM)
        let orientation = try XCTUnwrap(snapshot.orientation)
        XCTAssertEqual(position.x, odom.pose.pose.position.x, accuracy: 1e-12)
        XCTAssertEqual(position.y, odom.pose.pose.position.y, accuracy: 1e-12)
        XCTAssertEqual(position.z, odom.pose.pose.position.z, accuracy: 1e-12)
        XCTAssertEqual(orientation.vector.x, odom.pose.pose.orientation.x, accuracy: 1e-12)
        XCTAssertEqual(orientation.vector.y, odom.pose.pose.orientation.y, accuracy: 1e-12)
        XCTAssertEqual(orientation.vector.z, odom.pose.pose.orientation.z, accuracy: 1e-12)
        XCTAssertEqual(orientation.vector.w, odom.pose.pose.orientation.w, accuracy: 1e-12)
        XCTAssertEqual(snapshot.originEpoch, 2)
        XCTAssertEqual(snapshot.tracking, "normal")
    }

    func testMakeUsesFusedImuConversionsMatchingWire() throws {
        let attitude = Frames.quaternion(roll: 0.1, pitch: -0.2, yaw: 0.3)
        let user = SIMD3(0.01, -0.02, 0.03)
        let gravity = SIMD3(0.0, 0.0, -1.0)
        let gyro = SIMD3(0.2, -0.1, 0.05)
        let mag = SIMD3(21.5, -5.25, 41.0)
        let msg = MessageBuilders.imuFused(
            stampNs: 1,
            names: FrameNames(deviceName: "phone"),
            attitudeDeviceToReference: attitude,
            reference: .trueNorth,
            userAccelG: user,
            gravityG: gravity,
            rotationRateRadS: gyro
        )
        let snapshot = SensorSnapshot.make(
            fixture(
                userAccelG: user,
                gravityG: gravity,
                rotationRateRadS: gyro,
                attitudeDeviceToReference: attitude,
                imuReference: .trueNorth,
                magneticFieldUT: mag,
                magCalibration: .high,
                pressureKPa: 101.325
            )
        )
        let force = try XCTUnwrap(snapshot.specificForceMps2)
        XCTAssertEqual(force.x, msg.linearAcceleration.x, accuracy: 1e-12)
        XCTAssertEqual(force.y, msg.linearAcceleration.y, accuracy: 1e-12)
        XCTAssertEqual(force.z, msg.linearAcceleration.z, accuracy: 1e-12)
        let omega = try XCTUnwrap(snapshot.angularVelocityRadS)
        XCTAssertEqual(omega.x, msg.angularVelocity.x, accuracy: 1e-12)
        XCTAssertEqual(omega.y, msg.angularVelocity.y, accuracy: 1e-12)
        XCTAssertEqual(omega.z, msg.angularVelocity.z, accuracy: 1e-12)
        let imuQ = try XCTUnwrap(snapshot.imuOrientation)
        XCTAssertEqual(imuQ.vector.x, msg.orientation.x, accuracy: 1e-12)
        XCTAssertEqual(imuQ.vector.y, msg.orientation.y, accuracy: 1e-12)
        XCTAssertEqual(imuQ.vector.z, msg.orientation.z, accuracy: 1e-12)
        XCTAssertEqual(imuQ.vector.w, msg.orientation.w, accuracy: 1e-12)
        XCTAssertEqual(snapshot.magneticFieldUT, mag)
        XCTAssertEqual(snapshot.magCalibration, .high)
        XCTAssertEqual(try XCTUnwrap(snapshot.pressurePa), 101_325, accuracy: 1e-9)
        XCTAssertEqual(Units.pressureKPaToPa(101.325), snapshot.pressurePa ?? 0, accuracy: 1e-12)
    }

    func testMakeFallsBackToRawAccelWhenDeviceMotionIsMissing() throws {
        let accelG = SIMD3(0.0, 0.0, -1.0)
        let gyro = SIMD3(0.5, -0.25, 0.125)
        let snapshot = SensorSnapshot.make(
            fixture(accelG: accelG, rotationRateRadS: gyro)
        )
        let force = try XCTUnwrap(snapshot.specificForceMps2)
        let expected = Units.accelGToMps2(accelG)
        XCTAssertEqual(force.x, expected.x, accuracy: 1e-12)
        XCTAssertEqual(force.z, expected.z, accuracy: 1e-12)
        XCTAssertEqual(snapshot.angularVelocityRadS, gyro)
        XCTAssertNil(snapshot.imuOrientation)
    }

    func testDemoValuesArePlausibleAndFormatWithoutMissingPlaceholders() {
        let demo = SensorSnapshot.demo
        XCTAssertEqual(demo.tracking, "normal")
        XCTAssertGreaterThan(demo.originEpoch, 0)
        XCTAssertNotEqual(Readout.vectorCells(demo.specificForceMps2, fractionDigits: 2), Array(repeating: Readout.missingCell, count: 3))
        XCTAssertNotEqual(Readout.pressureAltitudeLine(pa: demo.pressurePa, relativeAltitudeM: demo.relativeAltitudeM), Readout.missing)
        XCTAssertNotNil(Readout.gnssLatLon(latitude: demo.gnssLatitude, longitude: demo.gnssLongitude))
        XCTAssertNotEqual(Readout.batteryThermal(level: demo.batteryLevel, state: demo.batteryState, thermal: demo.thermal), Readout.missing)
        XCTAssertGreaterThan(Readout.combinedRateHz(keys: Readout.depthChannelKeys, rates: demo.ratesHz), 0)
        let pos = Readout.vectorCells(demo.positionM, fractionDigits: 2)
        XCTAssertEqual(pos.count, 3)
        pos.forEach { XCTAssertEqual($0.count, Readout.cellWidth) }
        let rpy = Readout.rpyCells(demo.poseRPYDeg)
        rpy.forEach { XCTAssertEqual($0.count, Readout.cellWidth) }
        XCTAssertEqual(Readout.streamDrop(Readout.combinedDrops(keys: ["color_image"], drops: demo.drops)), "drop 12")
    }

    private func fixture(
        tracking: String = "normal",
        originEpoch: UInt32 = 2,
        cameraTransform: simd_double4x4? = nil,
        accelG: SIMD3<Double>? = nil,
        userAccelG: SIMD3<Double>? = nil,
        gravityG: SIMD3<Double>? = nil,
        rotationRateRadS: SIMD3<Double>? = nil,
        attitudeDeviceToReference: simd_quatd? = nil,
        imuReference: ImuReferenceFrame = .arbitrary,
        magneticFieldUT: SIMD3<Double>? = nil,
        magCalibration: MagCalibration = .unknown,
        pressureKPa: Double? = nil,
        relativeAltitudeM: Double? = nil,
        gnssLatitude: Double? = nil,
        gnssLongitude: Double? = nil,
        gnssHorizontalAccuracyM: Double? = nil,
        gnssAltitudeM: Double? = nil,
        locationAuthorization: LocationAuthorization = .notDetermined,
        batteryLevel: Float = -1,
        batteryState: String = "unknown",
        thermal: String = "nominal",
        clock: ClockCheckStatus = .pending,
        ratesHz: [String: Double] = [:],
        drops: [String: Int] = [:],
        depthCenterM: Float? = nil
    ) -> SensorSnapshot.Input {
        SensorSnapshot.Input(
            tracking: tracking,
            originEpoch: originEpoch,
            cameraTransform: cameraTransform,
            accelG: accelG,
            userAccelG: userAccelG,
            gravityG: gravityG,
            rotationRateRadS: rotationRateRadS,
            attitudeDeviceToReference: attitudeDeviceToReference,
            imuReference: imuReference,
            magneticFieldUT: magneticFieldUT,
            magCalibration: magCalibration,
            pressureKPa: pressureKPa,
            relativeAltitudeM: relativeAltitudeM,
            gnssLatitude: gnssLatitude,
            gnssLongitude: gnssLongitude,
            gnssHorizontalAccuracyM: gnssHorizontalAccuracyM,
            gnssAltitudeM: gnssAltitudeM,
            locationAuthorization: locationAuthorization,
            batteryLevel: batteryLevel,
            batteryState: batteryState,
            thermal: thermal,
            clock: clock,
            ratesHz: ratesHz,
            drops: drops,
            depthCenterM: depthCenterM
        )
    }
}
