import simd
import XCTest

@testable import PocketSensor

final class SampleBoxTests: XCTestCase {
    func testUpdateIsVisibleOnCopyAndDoesNotAlias() {
        let box = SampleBox()
        box.update { latest in
            latest.tracking = "normal"
            latest.accelG = SIMD3(0.1, 0.2, 0.3)
            latest.depthCenterM = 1.5
        }
        let first = box.copy()
        XCTAssertEqual(first.tracking, "normal")
        XCTAssertEqual(first.accelG, SIMD3(0.1, 0.2, 0.3))
        XCTAssertEqual(first.depthCenterM, 1.5)

        box.update { $0.tracking = "limited:initializing" }
        XCTAssertEqual(first.tracking, "normal")
        XCTAssertEqual(box.copy().tracking, "limited:initializing")
    }
}
