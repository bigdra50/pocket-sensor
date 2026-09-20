import PocketSensorCore
import XCTest

final class RestartBackoffTests: XCTestCase {
    func testDelaysGrowAndStayAtTheCap() {
        var backoff = RestartBackoff()
        let delays = (0 ..< 6).map { _ in backoff.nextDelay() }
        XCTAssertEqual(delays, [0.5, 1.0, 2.0, 4.0, 5.0, 5.0])
    }

    func testResetStartsOver() {
        var backoff = RestartBackoff()
        _ = backoff.nextDelay()
        _ = backoff.nextDelay()
        backoff.reset()
        XCTAssertEqual(backoff.nextDelay(), 0.5)
    }
}
