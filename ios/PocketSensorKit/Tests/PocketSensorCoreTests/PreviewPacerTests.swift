import Foundation
import PocketSensorCore
import XCTest

final class PreviewPacerTests: XCTestCase {
    func testSixtyFpsInputForOneSecondAcceptsThirty() {
        var pacer = PreviewPacer(maxRateHz: 30)
        var accepted = 0
        for i in 0 ..< 60 {
            if pacer.shouldRender(timestamp: Double(i) / 60.0, busy: false) {
                accepted += 1
            }
        }
        XCTAssertEqual(accepted, 30)
    }

    func testBusyFramesAreRejectedAndDoNotMoveLastAccepted() {
        var pacer = PreviewPacer(maxRateHz: 30)
        XCTAssertTrue(pacer.shouldRender(timestamp: 0, busy: false))
        // 2/60 は間隔を満たすので、busy でなければ通る
        XCTAssertFalse(pacer.shouldRender(timestamp: 2.0 / 60.0, busy: true))
        // last accepted は 0 のままなので、同じ時刻をもう一度尋ねると通る
        XCTAssertTrue(pacer.shouldRender(timestamp: 2.0 / 60.0, busy: false))
    }

    func testBusyDoesNotAcceptEvenTheFirstFrame() {
        var pacer = PreviewPacer(maxRateHz: 30)
        XCTAssertFalse(pacer.shouldRender(timestamp: 1.0, busy: true))
        XCTAssertTrue(pacer.shouldRender(timestamp: 1.0, busy: false))
    }

    func testBackwardsTimestampIsAcceptedAndResets() {
        var pacer = PreviewPacer(maxRateHz: 30)
        XCTAssertTrue(pacer.shouldRender(timestamp: 10.0, busy: false))
        XCTAssertTrue(pacer.shouldRender(timestamp: 0.5, busy: false))
        XCTAssertFalse(pacer.shouldRender(timestamp: 0.5 + 1.0 / 60.0, busy: false))
        XCTAssertTrue(pacer.shouldRender(timestamp: 0.5 + 2.0 / 60.0, busy: false))
    }

    func testSixtyFpsJitterStillTakesEverySecondFrame() {
        var pacer = PreviewPacer(maxRateHz: 30)
        var accepted = 0
        for i in 0 ..< 60 {
            let jitter = (i % 2 == 0 ? 0.0005 : -0.0005)
            if pacer.shouldRender(timestamp: Double(i) / 60.0 + jitter, busy: false) {
                accepted += 1
            }
        }
        XCTAssertEqual(accepted, 30)
    }
}
