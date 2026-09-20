import PocketSensorCore
import XCTest

final class SensorDemandTests: XCTestCase {
    private let off = DisplaySettings(pose: false, imu: false, environment: false, gnss: false)

    func testChannelSetsComeFromContract() {
        XCTAssertEqual(
            SensorDemand.arkitKeys,
            Set(Contract.channels.filter { $0.group == "arframe" }.map(\.key))
        )
        XCTAssertEqual(
            SensorDemand.depthKeys,
            Set(Contract.channels.map(\.key).filter { $0.hasPrefix("depth_") })
        )
        XCTAssertEqual(SensorDemand.motionKeys, Set(["imu_raw", "imu", "mag"]))
        XCTAssertEqual(SensorDemand.altimeterKeys, Set(["pressure"]))
        XCTAssertEqual(SensorDemand.batteryKeys, Set(["battery"]))
        XCTAssertEqual(SensorDemand.gnssKeys, Set(["gnss_fix", "gnss_time_reference"]))
        XCTAssertTrue(SensorDemand.arkitKeys.isSuperset(of: SensorDemand.depthKeys))
        XCTAssertFalse(SensorDemand.arkitKeys.contains("tf_static"))
        XCTAssertFalse(SensorDemand.arkitKeys.contains("imu"))
    }

    func testDefaultDisplayRunsPoseImuEnvironmentWithoutSubscriptions() {
        let needs = SensorDemand.needs(subscribedKeys: [], display: DisplaySettings(), previewVisible: false)
        XCTAssertTrue(needs.arkit)
        XCTAssertFalse(needs.depth)
        XCTAssertTrue(needs.motion)
        XCTAssertTrue(needs.altimeter)
        XCTAssertTrue(needs.battery)
        XCTAssertFalse(needs.gnss)
    }

    func testNobodyNeedsAnythingWhenDisplayAndPreviewAreOff() {
        let needs = SensorDemand.needs(subscribedKeys: [], display: off, previewVisible: false)
        XCTAssertEqual(needs, .none)
    }

    func testPreviewWantsArkitAndDepth() {
        let needs = SensorDemand.needs(subscribedKeys: [], display: off, previewVisible: true)
        XCTAssertTrue(needs.arkit)
        XCTAssertTrue(needs.depth)
        XCTAssertFalse(needs.motion)
        XCTAssertFalse(needs.altimeter)
        XCTAssertFalse(needs.battery)
        XCTAssertFalse(needs.gnss)
    }

    func testSubscriptionsSelectSensorGroups() {
        XCTAssertTrue(SensorDemand.needs(subscribedKeys: ["odom"], display: off, previewVisible: false).arkit)
        XCTAssertTrue(SensorDemand.needs(subscribedKeys: ["tf"], display: off, previewVisible: false).arkit)
        XCTAssertTrue(SensorDemand.needs(subscribedKeys: ["tracking"], display: off, previewVisible: false).arkit)
        XCTAssertTrue(SensorDemand.needs(subscribedKeys: ["color_image"], display: off, previewVisible: false).arkit)
        XCTAssertTrue(SensorDemand.needs(subscribedKeys: ["color_camera_info"], display: off, previewVisible: false).arkit)

        let depth = SensorDemand.needs(subscribedKeys: ["depth_image"], display: off, previewVisible: false)
        XCTAssertTrue(depth.depth)
        XCTAssertTrue(depth.arkit)

        let compressed = SensorDemand.needs(
            subscribedKeys: ["depth_image_compressed", "depth_confidence_compressed"],
            display: off,
            previewVisible: false
        )
        XCTAssertTrue(compressed.depth)
        XCTAssertTrue(compressed.arkit)

        XCTAssertTrue(SensorDemand.needs(subscribedKeys: ["imu"], display: off, previewVisible: false).motion)
        XCTAssertTrue(SensorDemand.needs(subscribedKeys: ["imu_raw"], display: off, previewVisible: false).motion)
        XCTAssertTrue(SensorDemand.needs(subscribedKeys: ["mag"], display: off, previewVisible: false).motion)
        XCTAssertTrue(SensorDemand.needs(subscribedKeys: ["pressure"], display: off, previewVisible: false).altimeter)
        XCTAssertTrue(SensorDemand.needs(subscribedKeys: ["battery"], display: off, previewVisible: false).battery)
        XCTAssertTrue(SensorDemand.needs(subscribedKeys: ["gnss_fix"], display: off, previewVisible: false).gnss)
        XCTAssertTrue(SensorDemand.needs(subscribedKeys: ["gnss_time_reference"], display: off, previewVisible: false).gnss)
    }

    func testUnrelatedKeysDoNotStartSensors() {
        let needs = SensorDemand.needs(
            subscribedKeys: ["tf_static", "device_info", "diagnostics"],
            display: off,
            previewVisible: false
        )
        XCTAssertEqual(needs, .none)
    }

    func testDisplayFlagsAreIndependentOfSubscriptions() {
        let pose = SensorDemand.needs(
            subscribedKeys: [],
            display: DisplaySettings(pose: true, imu: false, environment: false, gnss: false),
            previewVisible: false
        )
        XCTAssertTrue(pose.arkit)
        XCTAssertFalse(pose.depth)

        let gnss = SensorDemand.needs(
            subscribedKeys: [],
            display: DisplaySettings(pose: false, imu: false, environment: false, gnss: true),
            previewVisible: false
        )
        XCTAssertTrue(gnss.gnss)
        XCTAssertFalse(gnss.arkit)
    }

    func testDisplaySettingsDefaultAndAllOff() {
        let defaults = DisplaySettings()
        XCTAssertTrue(defaults.pose)
        XCTAssertTrue(defaults.imu)
        XCTAssertTrue(defaults.environment)
        XCTAssertFalse(defaults.gnss)
        XCTAssertEqual(DisplaySettings.allOff, off)
    }

    func testDisplaySettingsRoundTripsThroughJSON() throws {
        let settings = DisplaySettings(pose: false, imu: true, environment: false, gnss: true)
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(DisplaySettings.self, from: data)
        XCTAssertEqual(decoded, settings)
    }
}

final class SensorHoldTests: XCTestCase {
    func testNeedTurnsOnImmediately() {
        var hold = SensorHold(holdSeconds: 10)
        var needs = SensorNeeds.none
        needs.motion = true
        let effective = hold.update(needs: needs, now: 0)
        XCTAssertTrue(effective.motion)
        XCTAssertFalse(effective.arkit)
    }

    func testNeedTurnsOffOnlyAfterHoldSeconds() {
        var hold = SensorHold(holdSeconds: 10)
        var needs = SensorNeeds.none
        needs.arkit = true
        XCTAssertTrue(hold.update(needs: needs, now: 0).arkit)

        needs.arkit = false
        XCTAssertTrue(hold.update(needs: needs, now: 1).arkit)
        XCTAssertTrue(hold.update(needs: needs, now: 10.999).arkit)
        XCTAssertFalse(hold.update(needs: needs, now: 11).arkit)
        XCTAssertFalse(hold.update(needs: needs, now: 20).arkit)
    }

    func testBlipDuringHoldRearmsTheTimer() {
        var hold = SensorHold(holdSeconds: 10)
        var needs = SensorNeeds.none
        needs.depth = true
        XCTAssertTrue(hold.update(needs: needs, now: 0).depth)

        needs.depth = false
        XCTAssertTrue(hold.update(needs: needs, now: 1).depth)

        needs.depth = true
        XCTAssertTrue(hold.update(needs: needs, now: 5).depth)

        needs.depth = false
        XCTAssertTrue(hold.update(needs: needs, now: 6).depth)
        XCTAssertTrue(hold.update(needs: needs, now: 15.999).depth)
        XCTAssertFalse(hold.update(needs: needs, now: 16).depth)
    }

    func testFieldsAreIndependent() {
        var hold = SensorHold(holdSeconds: 10)
        var needs = SensorNeeds.none
        needs.motion = true
        needs.gnss = true
        _ = hold.update(needs: needs, now: 0)

        needs.motion = false
        XCTAssertTrue(hold.update(needs: needs, now: 1).motion)
        XCTAssertTrue(hold.update(needs: needs, now: 1).gnss)

        needs.gnss = false
        let mid = hold.update(needs: needs, now: 5)
        XCTAssertTrue(mid.motion)
        XCTAssertTrue(mid.gnss)

        let afterMotion = hold.update(needs: needs, now: 11)
        XCTAssertFalse(afterMotion.motion)
        XCTAssertTrue(afterMotion.gnss)

        XCTAssertFalse(hold.update(needs: needs, now: 15).gnss)
    }
}
