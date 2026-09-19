import Foundation
import PocketSensorCore
import simd
import XCTest

final class UnitsTests: XCTestCase {
    func testEveryUnitsVector() throws {
        let payload = try VectorFiles.json("units.json")

        for item in try XCTUnwrap(payload["accel_g_to_mps2"] as? [[String: Any]]) {
            let input = jsonDoubles(try XCTUnwrap(item["input"]))
            let output = jsonDoubles(try XCTUnwrap(item["output"]))
            let got = Units.accelGToMps2(SIMD3(input[0], input[1], input[2]))
            XCTAssertEqual(got.x, output[0], accuracy: 1e-12)
            XCTAssertEqual(got.y, output[1], accuracy: 1e-12)
            XCTAssertEqual(got.z, output[2], accuracy: 1e-12)
        }

        for item in try XCTUnwrap(payload["mag_ut_to_tesla"] as? [[String: Any]]) {
            let input = jsonDoubles(try XCTUnwrap(item["input"]))
            let output = jsonDoubles(try XCTUnwrap(item["output"]))
            let got = Units.magMicroTeslaToTesla(SIMD3(input[0], input[1], input[2]))
            XCTAssertEqual(got.x, output[0], accuracy: 1e-12)
            XCTAssertEqual(got.y, output[1], accuracy: 1e-12)
            XCTAssertEqual(got.z, output[2], accuracy: 1e-12)
        }

        for item in try XCTUnwrap(payload["pressure_kpa_to_pa"] as? [[String: Any]]) {
            let got = Units.pressureKPaToPa(jsonDouble(try XCTUnwrap(item["input"])))
            XCTAssertEqual(got, jsonDouble(try XCTUnwrap(item["output"])), accuracy: 1e-12)
        }

        for item in try XCTUnwrap(payload["course_deg_to_enu_yaw"] as? [[String: Any]]) {
            let got = Units.courseDegToENUYaw(jsonDouble(try XCTUnwrap(item["input"])))
            XCTAssertEqual(got, jsonDouble(try XCTUnwrap(item["output"])), accuracy: 1e-12)
        }

        for item in try XCTUnwrap(payload["accuracy_to_variance"] as? [[String: Any]]) {
            let got = Units.accuracyToVariance(jsonDouble(try XCTUnwrap(item["input"])))
            XCTAssertEqual(got, jsonDouble(try XCTUnwrap(item["output"])), accuracy: 1e-12)
        }

        for item in try XCTUnwrap(payload["navsat_covariance"] as? [[String: Any]]) {
            let output = try XCTUnwrap(item["output"] as? [String: Any])
            let got = Units.navSatCovariance(
                horizontalAccuracy: jsonDouble(try XCTUnwrap(item["horizontal_accuracy_m"])),
                verticalAccuracy: jsonDouble(try XCTUnwrap(item["vertical_accuracy_m"]))
            )
            XCTAssertEqualDoubles(got.covariance, jsonDoubles(try XCTUnwrap(output["cov9"])), accuracy: 1e-12)
            XCTAssertEqual(Int(got.type), jsonInt(try XCTUnwrap(output["cov_type"])))
            XCTAssertEqual(Int(got.status), jsonInt(try XCTUnwrap(output["status"])))
        }

        for item in try XCTUnwrap(payload["depth_m_to_mm_u16"] as? [[String: Any]]) {
            let raw = try XCTUnwrap(item["input"] as? [Any]).map(restoreJSONFloat)
            let expected = try XCTUnwrap(item["output"] as? [Any]).map(jsonInt)
            let data = Units.depthMetersToMillimeters(raw)
            XCTAssertEqual(data.count, expected.count * 2)
            let got: [UInt16] = data.withUnsafeBytes { Array($0.bindMemory(to: UInt16.self)) }
            XCTAssertEqual(got.map(Int.init), expected)
        }
    }

    func testDepthRowPaddingIsStripped() {
        var padded = [Float](repeating: 0, count: 4)
        padded[0] = 1.0
        padded[1] = 2.0
        padded[2] = 99
        padded[3] = 99
        let data = padded.withUnsafeBufferPointer { buf in
            Units.depthMetersToMillimeters(
                base: UnsafeRawPointer(buf.baseAddress!),
                width: 2,
                height: 1,
                bytesPerRow: 16
            )
        }
        let got: [UInt16] = data.withUnsafeBytes { Array($0.bindMemory(to: UInt16.self)) }
        XCTAssertEqual(got, [1000, 2000])
    }

    func testPackRowsStripsPadding() {
        let row = [UInt8]([1, 2, 3, 9, 4, 5, 6, 9])
        let packed = row.withUnsafeBufferPointer { buf in
            Units.packRows(
                base: UnsafeRawPointer(buf.baseAddress!),
                width: 3,
                height: 2,
                bytesPerRow: 4,
                bytesPerPixel: 1
            )
        }
        XCTAssertEqual(Array(packed), [1, 2, 3, 4, 5, 6])
    }
}
