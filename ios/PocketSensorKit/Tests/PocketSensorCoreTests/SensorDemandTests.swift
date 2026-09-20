import PocketSensorCore
import XCTest

final class SensorDemandTests: XCTestCase {
    func testMotionAndBatteryAreSubscribedOrMonitor() {
        XCTAssertTrue(SensorDemand.motion(subscribed: false, monitorOn: true))
        XCTAssertTrue(SensorDemand.motion(subscribed: true, monitorOn: false))
        XCTAssertTrue(SensorDemand.motion(subscribed: true, monitorOn: true))
        XCTAssertFalse(SensorDemand.motion(subscribed: false, monitorOn: false))

        XCTAssertTrue(SensorDemand.battery(subscribed: false, monitorOn: true))
        XCTAssertFalse(SensorDemand.battery(subscribed: false, monitorOn: false))
        XCTAssertTrue(SensorDemand.battery(subscribed: true, monitorOn: false))
    }

    func testGnssIgnoresMonitor() {
        XCTAssertFalse(SensorDemand.gnss(subscribed: false, monitorOn: true))
        XCTAssertFalse(SensorDemand.gnss(subscribed: false, monitorOn: false))
        XCTAssertTrue(SensorDemand.gnss(subscribed: true, monitorOn: false))
        XCTAssertTrue(SensorDemand.gnss(subscribed: true, monitorOn: true))
    }
}
