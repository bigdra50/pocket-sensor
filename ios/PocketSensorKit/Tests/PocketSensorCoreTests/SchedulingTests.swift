import Foundation
import PocketSensorCore
import XCTest

final class SchedulingTests: XCTestCase {
    func testThermalDivisors() {
        XCTAssertEqual(ThermalLevel.nominal.rateDivisor, 1)
        XCTAssertEqual(ThermalLevel.fair.rateDivisor, 1)
        XCTAssertEqual(ThermalLevel.serious.rateDivisor, 2)
        XCTAssertEqual(ThermalLevel.critical.rateDivisor, 6)
    }

    func testFrameDecimatorKeepsSlowerAsSubset() {
        let pose = FrameDecimator.divisor(rateLimitHz: 30, thermal: .nominal)
        let color = FrameDecimator.divisor(rateLimitHz: 15, thermal: .nominal)
        XCTAssertEqual(pose, 2)
        XCTAssertEqual(color, 4)
        var poseSent: [UInt64] = []
        var colorSent: [UInt64] = []
        for i in UInt64(0) ..< 12 {
            if FrameDecimator.shouldSend(frameIndex: i, divisor: pose) { poseSent.append(i) }
            if FrameDecimator.shouldSend(frameIndex: i, divisor: color) { colorSent.append(i) }
        }
        XCTAssertEqual(poseSent, [0, 2, 4, 6, 8, 10])
        XCTAssertEqual(colorSent, [0, 4, 8])
        XCTAssertTrue(Set(colorSent).isSubset(of: Set(poseSent)))
    }

    func testThermalScalesDivisor() {
        XCTAssertEqual(FrameDecimator.divisor(rateLimitHz: 30, thermal: .serious), 4)
        XCTAssertEqual(FrameDecimator.divisor(rateLimitHz: 30, thermal: .critical), 12)
    }

    func testRateMeterTwoSecondWindow() {
        var meter = RateMeter()
        for i in 0 ..< 60 {
            meter.record(at: Double(i) / 30.0)
        }
        XCTAssertEqual(meter.hz(now: 2.0), 30, accuracy: 1e-9)
        XCTAssertEqual(meter.hz(now: 10.0), 0, accuracy: 1e-9)
    }

    func testAnchorGateSendsOnlyWhileTracked() {
        var gate = AnchorGate(intervalS: 0.5)
        XCTAssertFalse(gate.shouldSend(name: "a", isTracked: false, atS: 10))
        XCTAssertTrue(gate.shouldSend(name: "a", isTracked: true, atS: 10))
        XCTAssertFalse(gate.shouldSend(name: "a", isTracked: true, atS: 10.4))
        XCTAssertTrue(gate.shouldSend(name: "a", isTracked: true, atS: 10.5))
        XCTAssertFalse(gate.shouldSend(name: "a", isTracked: false, atS: 11.0))
        XCTAssertTrue(gate.shouldSend(name: "b", isTracked: true, atS: 10.1))
        gate.reset()
        XCTAssertTrue(gate.shouldSend(name: "a", isTracked: true, atS: 10.2))
    }
}
