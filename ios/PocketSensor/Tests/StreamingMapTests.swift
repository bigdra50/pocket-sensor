import ARKit
import CoreLocation
import CoreMotion
import PocketSensorCore
import simd
import UIKit
import XCTest

@testable import PocketSensor

final class StreamingMapTests: XCTestCase {
    func testTrackingMapsARKitStates() {
        XCTAssertEqual(StreamingMap.tracking(.normal).state, .normal)
        XCTAssertEqual(StreamingMap.tracking(.normal).reason, .none)
        XCTAssertEqual(StreamingMap.tracking(.notAvailable).state, .notAvailable)
        let limited = StreamingMap.tracking(.limited(.insufficientFeatures))
        XCTAssertEqual(limited.state, .limited)
        XCTAssertEqual(limited.reason, .insufficientFeatures)
        XCTAssertEqual(StreamingMap.tracking(.limited(.initializing)).reason, .initializing)
        XCTAssertEqual(StreamingMap.tracking(.limited(.excessiveMotion)).reason, .excessiveMotion)
        XCTAssertEqual(StreamingMap.tracking(.limited(.relocalizing)).reason, .relocalizing)
    }

    func testThermalAndBatteryAndImuReference() {
        XCTAssertEqual(StreamingMap.thermal(.nominal), .nominal)
        XCTAssertEqual(StreamingMap.thermal(.fair), .fair)
        XCTAssertEqual(StreamingMap.thermal(.serious), .serious)
        XCTAssertEqual(StreamingMap.thermal(.critical), .critical)
        XCTAssertEqual(StreamingMap.battery(.unknown), .unknown)
        XCTAssertEqual(StreamingMap.battery(.unplugged), .discharging)
        XCTAssertEqual(StreamingMap.battery(.charging), .charging)
        XCTAssertEqual(StreamingMap.battery(.full), .full)
        XCTAssertEqual(StreamingMap.imuReference("true_north"), .trueNorth)
        XCTAssertEqual(StreamingMap.imuReference("arbitrary"), .arbitrary)
        XCTAssertEqual(StreamingMap.imuReference("nope"), .arbitrary)
        XCTAssertEqual(StreamingMap.cmAttitudeFrame(.arbitrary), .xArbitraryCorrectedZVertical)
        XCTAssertEqual(StreamingMap.cmAttitudeFrame(.trueNorth), .xTrueNorthZVertical)
    }

    func testLocationAuthorizationMapsEveryStatus() {
        XCTAssertEqual(StreamingMap.locationAuthorization(.notDetermined), .notDetermined)
        XCTAssertEqual(StreamingMap.locationAuthorization(.denied), .denied)
        XCTAssertEqual(StreamingMap.locationAuthorization(.restricted), .restricted)
        XCTAssertEqual(StreamingMap.locationAuthorization(.authorizedWhenInUse), .authorized)
        XCTAssertEqual(StreamingMap.locationAuthorization(.authorizedAlways), .authorized)
    }

    func testAttitudeIsPassedThroughWithoutInverse() {
        // CMAttitude.quaternion は device→reference。逆は取らない。
        let q = StreamingMap.attitudeDeviceToReference(x: 0.1, y: 0.2, z: 0.3, w: 0.9)
        XCTAssertEqual(q.imag.x, 0.1, accuracy: 1e-12)
        XCTAssertEqual(q.imag.y, 0.2, accuracy: 1e-12)
        XCTAssertEqual(q.imag.z, 0.3, accuracy: 1e-12)
        XCTAssertEqual(q.real, 0.9, accuracy: 1e-12)
    }

    func testMagIntervalIsInclusiveOfThePeriod() {
        XCTAssertTrue(StreamingMap.shouldSend(lastSent: nil, now: 1.0, maxHz: 50))
        XCTAssertFalse(StreamingMap.shouldSend(lastSent: 1.0, now: 1.019, maxHz: 50))
        XCTAssertTrue(StreamingMap.shouldSend(lastSent: 1.0, now: 1.02, maxHz: 50))
        XCTAssertFalse(StreamingMap.shouldSend(lastSent: 0, now: 0, maxHz: 0))
    }

    func testLinkRowsKeepEn0AndWiredDropLoopbackAndAwdl() {
        let rows = StreamingMap.linkRows(from: [
            ("lo0", "127.0.0.1"),
            ("en0", "192.168.1.10"),
            ("en2", "169.254.2.1"),
            ("awdl0", "169.254.3.1"),
            ("ncm0", "172.20.10.2"),
            ("utun0", "10.8.0.2"),
        ])
        XCTAssertEqual(rows.map(\.name), ["en0", "en2", "ncm0"])
        XCTAssertEqual(rows.map(\.address), ["192.168.1.10", "169.254.2.1", "172.20.10.2"])
    }

    func testDeviceNameStoreRejectsInvalidAndPersistsValid() {
        let suite = "pocketsensor.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let store = DeviceNameStore(defaults: defaults, key: "device.name")
        XCTAssertEqual(store.load(), DeviceName.defaultValue)
        XCTAssertFalse(store.save("Bad Name"))
        XCTAssertEqual(store.load(), DeviceName.defaultValue)
        XCTAssertTrue(store.save("phone_1"))
        XCTAssertEqual(store.load(), "phone_1")
        defaults.removePersistentDomain(forName: suite)
    }
}
