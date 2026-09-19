import Foundation
import PocketSensorCore
import XCTest

final class DiagnosticsTests: XCTestCase {
    func testStatusNamesAndLevels() {
        let input = DiagnosticsInput(
            deviceName: "phone",
            trackingState: .limited,
            trackingReason: .initializing,
            thermal: .serious,
            clients: 2,
            ratesHz: ["odom": 30, "imu": 100],
            drops: ["odom": 3],
            clock: .suspicious,
            magCalibration: .uncalibrated
        )
        let array = Diagnostics.build(stampNs: 5_000_000_006, input: input)
        XCTAssertEqual(array.header.stamp.sec, 5)
        XCTAssertEqual(array.status.map(\.name), [
            "pocketsensor/tracking",
            "pocketsensor/thermal",
            "pocketsensor/streams",
            "pocketsensor/clock",
            "pocketsensor/mag",
        ])
        XCTAssertEqual(array.status[0].level, DiagnosticMsgs.DiagnosticStatus.warn)
        XCTAssertEqual(array.status[1].level, DiagnosticMsgs.DiagnosticStatus.warn)
        XCTAssertEqual(array.status[2].level, DiagnosticMsgs.DiagnosticStatus.warn)
        XCTAssertEqual(array.status[3].level, DiagnosticMsgs.DiagnosticStatus.error)
        XCTAssertEqual(array.status[4].level, DiagnosticMsgs.DiagnosticStatus.error)
        XCTAssertTrue(array.status.allSatisfy { $0.hardwareId == "phone" })
        XCTAssertEqual(array.status[0].values.first { $0.key == "state" }?.value, "1")
    }

    func testEncodeSkipsAppearInStreamsValues() {
        let input = DiagnosticsInput(
            deviceName: "phone",
            trackingState: .normal,
            trackingReason: .none,
            thermal: .nominal,
            clients: 1,
            ratesHz: [:],
            drops: [:],
            encodeSkips: ["color": 4],
            clock: .ok,
            magCalibration: .high
        )
        let array = Diagnostics.build(stampNs: 0, input: input)
        let streams = array.status.first { $0.name == "pocketsensor/streams" }
        XCTAssertEqual(streams?.values.first { $0.key == "encode_skips.color" }?.value, "4")
    }

    func testOkLevels() {
        let input = DiagnosticsInput(
            deviceName: "phone",
            trackingState: .normal,
            trackingReason: .none,
            thermal: .nominal,
            clients: 0,
            ratesHz: [:],
            drops: [:],
            clock: .ok,
            magCalibration: .high
        )
        let array = Diagnostics.build(stampNs: 0, input: input)
        XCTAssertTrue(array.status.allSatisfy { $0.level == DiagnosticMsgs.DiagnosticStatus.ok })
    }

    func testTrackingUnavailableAndThermalCriticalAreErrors() {
        let input = DiagnosticsInput(
            deviceName: "x",
            trackingState: .notAvailable,
            trackingReason: .none,
            thermal: .critical,
            clients: 1,
            ratesHz: [:],
            drops: [:],
            clock: .pending,
            magCalibration: .low
        )
        let array = Diagnostics.build(stampNs: 0, input: input)
        XCTAssertEqual(array.status[0].level, DiagnosticMsgs.DiagnosticStatus.error)
        XCTAssertEqual(array.status[1].level, DiagnosticMsgs.DiagnosticStatus.error)
        XCTAssertEqual(array.status[3].level, DiagnosticMsgs.DiagnosticStatus.ok)
        XCTAssertEqual(array.status[4].level, DiagnosticMsgs.DiagnosticStatus.warn)
    }
}
