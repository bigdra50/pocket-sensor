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
            magCalibration: .uncalibrated,
            locationAuthorization: .authorized
        )
        let array = Diagnostics.build(stampNs: 5_000_000_006, input: input)
        XCTAssertEqual(array.header.stamp.sec, 5)
        XCTAssertEqual(array.status.map(\.name), [
            "pocketsensor/tracking",
            "pocketsensor/thermal",
            "pocketsensor/streams",
            "pocketsensor/clock",
            "pocketsensor/mag",
            "pocketsensor/gnss",
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
            magCalibration: .high,
            locationAuthorization: .authorized
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
            magCalibration: .high,
            locationAuthorization: .authorized
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
            magCalibration: .low,
            locationAuthorization: .authorized
        )
        let array = Diagnostics.build(stampNs: 0, input: input)
        XCTAssertEqual(array.status[0].level, DiagnosticMsgs.DiagnosticStatus.error)
        XCTAssertEqual(array.status[1].level, DiagnosticMsgs.DiagnosticStatus.error)
        XCTAssertEqual(array.status[3].level, DiagnosticMsgs.DiagnosticStatus.ok)
        XCTAssertEqual(array.status[4].level, DiagnosticMsgs.DiagnosticStatus.warn)
    }

    func testGnssStatusTellsWhyNoFixArrives() {
        func gnss(_ authorization: LocationAuthorization) -> DiagnosticMsgs.DiagnosticStatus? {
            let input = DiagnosticsInput(
                deviceName: "phone",
                trackingState: .normal,
                trackingReason: .none,
                thermal: .nominal,
                clients: 1,
                ratesHz: [:],
                drops: [:],
                clock: .ok,
                magCalibration: .high,
                locationAuthorization: authorization
            )
            return Diagnostics.build(stampNs: 0, input: input).status.first { $0.name == "pocketsensor/gnss" }
        }
        XCTAssertEqual(gnss(.authorized)?.level, DiagnosticMsgs.DiagnosticStatus.ok)
        XCTAssertEqual(gnss(.notDetermined)?.level, DiagnosticMsgs.DiagnosticStatus.warn)
        XCTAssertEqual(gnss(.unknown)?.level, DiagnosticMsgs.DiagnosticStatus.warn)
        XCTAssertEqual(gnss(.denied)?.level, DiagnosticMsgs.DiagnosticStatus.error)
        XCTAssertEqual(gnss(.restricted)?.level, DiagnosticMsgs.DiagnosticStatus.error)
        XCTAssertEqual(gnss(.notDetermined)?.message, "not_determined")
        XCTAssertEqual(gnss(.denied)?.values.first { $0.key == "authorization" }?.value, "denied")
    }
}
