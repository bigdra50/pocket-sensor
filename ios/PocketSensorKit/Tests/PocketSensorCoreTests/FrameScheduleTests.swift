import Foundation
import PocketSensorCore
import XCTest

final class FrameScheduleTests: XCTestCase {
    /// fps 枚/秒で seconds 秒ぶんのフレームを流し、送ると決まった回数を数える。
    private func run(
        fps: Double,
        seconds: Double,
        pose: Double = 30,
        color: Double = 15,
        depth: Double = 15,
        thermal: ThermalLevel = .nominal,
        start: TimeInterval = 1234.5678
    ) -> (pose: [Int], color: [Int], depth: [Int]) {
        var schedule = FrameSchedule()
        var poseSent: [Int] = []
        var colorSent: [Int] = []
        var depthSent: [Int] = []
        let count = Int((fps * seconds).rounded())
        for i in 0 ..< count {
            let due = schedule.next(
                timestamp: start + Double(i) / fps,
                poseHz: pose,
                colorHz: color,
                depthHz: depth,
                thermal: thermal
            )
            if due.pose { poseSent.append(i) }
            if due.color { colorSent.append(i) }
            if due.depth { depthSent.append(i) }
        }
        return (poseSent, colorSent, depthSent)
    }

    func testSixtyFpsInputGivesTheConfiguredRates() {
        let sent = run(fps: 60, seconds: 2)
        XCTAssertEqual(sent.pose.count, 60)
        XCTAssertEqual(sent.color.count, 30)
        XCTAssertEqual(sent.depth.count, 30)
    }

    func testRatesDoNotDropWhenARKitDeliversFewerFrames() {
        // 熱で ARKit が毎秒 30 枚へ落ちても、姿勢 30 Hz、RGB と深度 15 Hz は保てる。
        // 枚数だけで間引くと、ここが 15 Hz と 7.5 Hz になる。
        let sent = run(fps: 30, seconds: 2)
        XCTAssertEqual(sent.pose.count, 60)
        XCTAssertEqual(sent.color.count, 30)
        XCTAssertEqual(sent.depth.count, 30)
    }

    func testInputSlowerThanTheLimitPassesEveryFrame() {
        let sent = run(fps: 20, seconds: 2)
        XCTAssertEqual(sent.pose.count, 40)
        XCTAssertEqual(sent.color.count, 20)
    }

    func testSlowerStreamsAreSubsetsAndColorPairsWithDepth() {
        let sent = run(fps: 60, seconds: 1)
        XCTAssertTrue(Set(sent.color).isSubset(of: Set(sent.pose)))
        XCTAssertEqual(sent.color, sent.depth)
    }

    func testSeriousHalvesOnceEvenWhenInputIsThirtyFps() {
        let sent = run(fps: 30, seconds: 2, thermal: .serious)
        XCTAssertEqual(sent.pose.count, 30)
        XCTAssertEqual(sent.color.count, 15)
    }

    func testCriticalIsOneSixth() {
        let sent = run(fps: 60, seconds: 6, thermal: .critical)
        XCTAssertEqual(sent.pose.count, 30)
    }

    func testStreamsStayAlignedAfterARateChange() {
        // RGB だけ一時的に 5 Hz へ下げて戻しても、RGB と深度は同じフレームへ戻る。
        var schedule = FrameSchedule()
        var pairs = 0
        var colorOnly = 0
        for i in 0 ..< 360 {
            let colorHz: Double = (120 ..< 240).contains(i) ? 5 : 15
            let due = schedule.next(
                timestamp: Double(i) / 60, poseHz: 30, colorHz: colorHz, depthHz: 15, thermal: .nominal
            )
            if i >= 240, due.color {
                if due.depth { pairs += 1 } else { colorOnly += 1 }
            }
        }
        XCTAssertEqual(colorOnly, 0)
        XCTAssertEqual(pairs, 30)
    }

    func testZeroRateIsNeverDue() {
        let sent = run(fps: 60, seconds: 1, color: 0)
        XCTAssertEqual(sent.color.count, 0)
        XCTAssertEqual(sent.pose.count, 30)
        XCTAssertEqual(sent.depth.count, 15)
    }

    func testTimestampGoingBackwardsIsAccepted() {
        var schedule = FrameSchedule()
        XCTAssertTrue(schedule.next(timestamp: 100, poseHz: 30, colorHz: 15, depthHz: 15, thermal: .nominal).pose)
        // ARKit を動かし直すと時刻が戻ることがある
        XCTAssertTrue(schedule.next(timestamp: 5, poseHz: 30, colorHz: 15, depthHz: 15, thermal: .nominal).pose)
    }

    func testJitterDoesNotSkipFrames() {
        var schedule = FrameSchedule()
        var sent = 0
        for i in 0 ..< 120 {
            let jitter = (i % 2 == 0) ? 0.0008 : -0.0008
            let due = schedule.next(
                timestamp: Double(i) / 60 + jitter, poseHz: 30, colorHz: 15, depthHz: 15, thermal: .nominal
            )
            if due.pose { sent += 1 }
        }
        XCTAssertEqual(sent, 60)
    }
}
