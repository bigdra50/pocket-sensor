import Foundation
import PocketSensorCore
import XCTest

final class WireClockTests: XCTestCase {
    func testAnchorIsWallMinusMono() {
        let clock = ClockAnchor(wallNs: 1_000_000_000, monoNs: 250_000_000)
        XCTAssertEqual(clock.anchorNs, 750_000_000)
        XCTAssertEqual(clock.wireTime(monoNs: 250_000_000), 1_000_000_000)
        XCTAssertEqual(clock.wireTime(monoNs: 250_000_001), 1_000_000_001)
    }

    func testSensorSecondsRoundsToNearestNsThenAddsAnchor() {
        let clock = ClockAnchor(wallNs: 5_000, monoNs: 0)
        XCTAssertEqual(clock.wireTime(sensorSeconds: 1.0), 1_000_005_000)
        XCTAssertEqual(clock.wireTime(sensorSeconds: 0.0000000004), 5_000)
        XCTAssertEqual(clock.wireTime(sensorSeconds: 0.0000000005), 5_001)
    }

    func testIdenticalInputYieldsIdenticalOutput() {
        let clock = ClockAnchor(wallNs: 42, monoNs: 7)
        XCTAssertEqual(clock.wireTime(monoNs: 100), clock.wireTime(monoNs: 100))
        XCTAssertEqual(clock.wireTime(sensorSeconds: 1.25), clock.wireTime(sensorSeconds: 1.25))
    }

    func testNegativeWireTimeClampsToZero() {
        let clock = ClockAnchor(wallNs: 10, monoNs: 100)
        XCTAssertEqual(clock.anchorNs, -90)
        XCTAssertEqual(clock.wireTime(monoNs: 50), 0)
        XCTAssertEqual(clock.wireTime(sensorSeconds: -1), 0)
    }

    func testOverflowClampsToUInt64Max() {
        let clock = ClockAnchor(wallNs: Int64.max, monoNs: 0)
        XCTAssertEqual(clock.wireTime(monoNs: 1), UInt64.max)
    }

    func testLocationTimestampConvertedOnMonoClock() {
        let clock = ClockAnchor(wallNs: 2_000, monoNs: 1_000)
        let sensor = clock.sensorSeconds(
            wallTimestampNs: 1_500,
            nowWallNs: 2_000,
            nowMonoNs: 1_000
        )
        XCTAssertEqual(sensor, 0.0000005, accuracy: 1e-15)
    }

    func testSelfCheckBoundsAreInclusive() {
        XCTAssertEqual(ClockSelfCheck.evaluate(sampleTimestampS: 1.0, arrivalMonoS: 1.0), .ok(delta: 0))
        XCTAssertEqual(ClockSelfCheck.evaluate(sampleTimestampS: 1.0, arrivalMonoS: 1.5), .ok(delta: 0.5))
        if case .suspicious(let delta) = ClockSelfCheck.evaluate(sampleTimestampS: 1.0, arrivalMonoS: 1.6) {
            XCTAssertEqual(delta, 0.6, accuracy: 1e-12)
        } else {
            XCTFail("expected suspicious when delay exceeds 0.5 s")
        }
        if case .suspicious(let delta) = ClockSelfCheck.evaluate(sampleTimestampS: 1.0, arrivalMonoS: 0.5) {
            XCTAssertEqual(delta, -0.5, accuracy: 1e-12)
        } else {
            XCTFail("expected suspicious when arrival precedes sample")
        }
    }
}
