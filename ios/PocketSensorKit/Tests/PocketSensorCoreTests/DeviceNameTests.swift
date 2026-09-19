import PocketSensorCore
import XCTest

final class DeviceNameTests: XCTestCase {
    func testDefaultIsValidROSName() {
        XCTAssertEqual(DeviceName.defaultValue, "pocketsensor")
        XCTAssertTrue(DeviceName.isValid(DeviceName.defaultValue))
    }

    func testAcceptsLowercaseLetterThenLettersDigitsUnderscore() {
        XCTAssertTrue(DeviceName.isValid("a"))
        XCTAssertTrue(DeviceName.isValid("phone_1"))
        XCTAssertTrue(DeviceName.isValid("x9_cam"))
        XCTAssertTrue(DeviceName.isValid("abc_def_0"))
    }

    func testRejectsEmptyUppercaseLeadingDigitLeadingUnderscoreAndOtherChars() {
        XCTAssertFalse(DeviceName.isValid(""))
        XCTAssertFalse(DeviceName.isValid("Pocketsensor"))
        XCTAssertFalse(DeviceName.isValid("1phone"))
        XCTAssertFalse(DeviceName.isValid("_phone"))
        XCTAssertFalse(DeviceName.isValid("phone-1"))
        XCTAssertFalse(DeviceName.isValid("phone.name"))
        XCTAssertFalse(DeviceName.isValid("phone/name"))
        XCTAssertFalse(DeviceName.isValid("phone name"))
        XCTAssertFalse(DeviceName.isValid("電話"))
    }

    func testClockCheckReducingTreatsEmptyAsPendingAndAnySuspiciousAsSuspicious() {
        XCTAssertEqual(ClockCheckStatus.reducing([]), .pending)
        XCTAssertEqual(ClockCheckStatus.reducing([.ok(delta: 0.01)]), .ok)
        XCTAssertEqual(
            ClockCheckStatus.reducing([.ok(delta: 0.02), .suspicious(delta: 0.9)]),
            .suspicious
        )
        XCTAssertEqual(
            ClockCheckStatus.reducing([.ok(delta: 0), .ok(delta: 0.5)]),
            .ok
        )
    }

    func testMagCalibrationMapsCoreMotionAccuracyRawValues() {
        XCTAssertEqual(MagCalibration.fromAccuracyRaw(-1), .uncalibrated)
        XCTAssertEqual(MagCalibration.fromAccuracyRaw(0), .low)
        XCTAssertEqual(MagCalibration.fromAccuracyRaw(1), .medium)
        XCTAssertEqual(MagCalibration.fromAccuracyRaw(2), .high)
        XCTAssertEqual(MagCalibration.fromAccuracyRaw(99), .unknown)
    }
}
