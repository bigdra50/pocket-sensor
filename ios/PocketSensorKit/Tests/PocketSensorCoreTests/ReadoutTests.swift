import Foundation
import PocketSensorCore
import simd
import XCTest

final class ReadoutTests: XCTestCase {
    func testCellIsFixedWidthRightAlignedAndIncludesSign() {
        XCTAssertEqual(Readout.cellWidth, 7)
        XCTAssertEqual(Readout.cell(0.12, fractionDigits: 2), "  +0.12")
        XCTAssertEqual(Readout.cell(-1.03, fractionDigits: 2), "  -1.03")
        XCTAssertEqual(Readout.cell(-123.45, fractionDigits: 2), "-123.45")
        XCTAssertEqual(Readout.cell(1.2, fractionDigits: 1), "   +1.2")
        XCTAssertEqual(Readout.cell(-0.4, fractionDigits: 1), "   -0.4")
        XCTAssertEqual(Readout.cell(91.3, fractionDigits: 1), "  +91.3")
        XCTAssertEqual(Readout.cell(0.010, fractionDigits: 3), " +0.010")
        XCTAssertEqual(Readout.cell(0.12, fractionDigits: 2).count, 7)
        XCTAssertEqual(Readout.cell(-123.45, fractionDigits: 2).count, 7)
    }

    func testCellOverflowAndNonFiniteStayAtWidth() {
        XCTAssertEqual(Readout.overflow.count, Readout.cellWidth)
        XCTAssertEqual(Readout.cell(1000, fractionDigits: 2), Readout.overflow)
        XCTAssertEqual(Readout.cell(-1000, fractionDigits: 2), Readout.overflow)
        XCTAssertEqual(Readout.cell(.nan, fractionDigits: 2), Readout.overflow)
        XCTAssertEqual(Readout.cell(.infinity, fractionDigits: 3), Readout.overflow)
        XCTAssertEqual(Readout.cell(-.infinity, fractionDigits: 1), Readout.overflow)
    }

    func testMissingCellIsPaddedToWidth() {
        XCTAssertEqual(Readout.missing, "—")
        XCTAssertEqual(Readout.missingCell.count, 7)
        XCTAssertTrue(Readout.missingCell.hasSuffix(Readout.missing))
    }

    func testVectorAndRpyAndQuaternionCells() {
        XCTAssertEqual(
            Readout.vectorCells(SIMD3(0.12, -1.03, 0.45), fractionDigits: 2),
            ["  +0.12", "  -1.03", "  +0.45"]
        )
        XCTAssertEqual(Readout.vectorCells(nil, fractionDigits: 2), Array(repeating: Readout.missingCell, count: 3))
        XCTAssertEqual(
            Readout.rpyCells((roll: 1.2, pitch: -0.4, yaw: 91.3)),
            ["   +1.2", "   -0.4", "  +91.3"]
        )
        XCTAssertEqual(Readout.rpyCells(nil), Array(repeating: Readout.missingCell, count: 3))
        let q = simd_quatd(ix: 0.010, iy: 0.002, iz: 0.715, r: 0.699)
        XCTAssertEqual(
            Readout.quaternionCells(q),
            [" +0.010", " +0.002", " +0.715", " +0.699"]
        )
        XCTAssertEqual(Readout.quaternionCells(nil).count, 4)
        XCTAssertEqual(Readout.quaternionCells(nil), Array(repeating: Readout.missingCell, count: 4))
    }

    func testEnvironmentAndGnssAndBatteryLines() {
        XCTAssertEqual(
            Readout.pressureAltitudeLine(pa: 101_325, relativeAltitudeM: 1.25),
            "1013.25 hPa   alt +1.25 m"
        )
        XCTAssertEqual(
            Readout.pressureAltitudeLine(pa: nil, relativeAltitudeM: nil),
            "\(Readout.missing)   alt \(Readout.missing)"
        )
        XCTAssertEqual(Readout.gnssLatLon(latitude: 35.12345, longitude: 139.12345), "+35.12345  +139.12345")
        XCTAssertNil(Readout.gnssLatLon(latitude: nil, longitude: 139.0))
        XCTAssertEqual(
            Readout.gnssAccuracyLine(horizontalM: 5.9, altitudeM: 12.3),
            "±5.9 m   alt +12.3 m"
        )
        XCTAssertEqual(Readout.gnssAccuracyLine(horizontalM: 5.9, altitudeM: nil), "±5.9 m")
        XCTAssertEqual(
            Readout.gnss(
                latitude: nil,
                longitude: nil,
                horizontalAccuracyM: nil,
                authorization: .notDetermined
            ),
            "not_determined"
        )
        XCTAssertEqual(
            Readout.gnss(
                latitude: 35.0,
                longitude: 139.0,
                horizontalAccuracyM: -1,
                authorization: .denied
            ),
            "denied"
        )
        XCTAssertEqual(
            Readout.batteryThermal(level: 0.87, state: "charging", thermal: "nominal"),
            "87% charging   nominal"
        )
        XCTAssertEqual(
            Readout.batteryThermal(level: -1, state: "unknown", thermal: "fair"),
            "\(Readout.missing)   fair"
        )
        XCTAssertEqual(Readout.clock(.ok), "ok")
    }

    func testStreamRateOmitsDropWhenZero() {
        XCTAssertEqual(Readout.rateHz(27.5), "27.5 Hz")
        XCTAssertEqual(Readout.streamRate(label: "pose", hz: 30), "pose 30.0 Hz")
        XCTAssertNil(Readout.streamDrop(0))
        XCTAssertEqual(Readout.streamDrop(12), "drop 12")
        XCTAssertEqual(Readout.streamPanelRows.count, 10)
        XCTAssertEqual(Readout.streamPanelRows.first { $0.label == "depth" }?.keys, Readout.depthChannelKeys)
    }

    func testCombinedDepthRateTakesMaxOfVariants() {
        let rates = [
            "depth_image": 0.0,
            "depth_image_compressed": 15.0,
            "depth_confidence": 4.0,
            "depth_confidence_compressed": 14.0,
        ]
        XCTAssertEqual(Readout.combinedRateHz(keys: Readout.depthChannelKeys, rates: rates), 15.0)
        XCTAssertEqual(Readout.combinedRateHz(keys: Readout.confidenceChannelKeys, rates: rates), 14.0)
        XCTAssertEqual(
            Readout.combinedRateHz(keys: Readout.depthChannelKeys, rates: ["depth_image": 12, "depth_image_compressed": 9]),
            12.0
        )
        XCTAssertEqual(Readout.combinedRateHz(keys: Readout.depthChannelKeys, rates: [:]), 0)
    }

    func testCombinedDropsSumVariants() {
        let drops = [
            "depth_image": 2,
            "depth_image_compressed": 5,
        ]
        XCTAssertEqual(Readout.combinedDrops(keys: Readout.depthChannelKeys, drops: drops), 7)
        XCTAssertEqual(Readout.combinedDrops(keys: Readout.confidenceChannelKeys, drops: [:]), 0)
    }
}
