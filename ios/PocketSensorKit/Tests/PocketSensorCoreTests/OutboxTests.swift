import Foundation
import PocketSensorCore
import XCTest

final class OutboxTests: XCTestCase {
    private func item(_ channel: UInt32, _ t: UInt64, _ byte: UInt8) -> OutboundItem {
        OutboundItem(channelId: channel, timestampNs: t, payload: Data([byte]))
    }

    func testKeepFIFOAndCapDropsOldest() {
        var box = Outbox()
        box.offerKeep(item(1, 1, 1))
        box.offerKeep(item(1, 2, 2))
        XCTAssertEqual(box.next()?.payload, Data([1]))
        box.completed()
        XCTAssertEqual(box.next()?.payload, Data([2]))
        box.completed()
        XCTAssertTrue(box.isIdle)

        var capped = Outbox()
        for i in 0 ..< Outbox.keepCap + 3 {
            capped.offerKeep(item(1, UInt64(i), 0))
        }
        XCTAssertEqual(capped.drops[1], 3)
        XCTAssertEqual(capped.next()?.timestampNs, 3)
    }

    func testQueueAgeBoundAndOldestAcrossChannels() {
        var box = Outbox()
        box.offerQueue(item(1, 0, 1), maxAgeNs: 1_000)
        box.offerQueue(item(1, 500, 2), maxAgeNs: 1_000)
        box.offerQueue(item(1, 1500, 3), maxAgeNs: 1_000)
        XCTAssertEqual(box.drops[1], 1)
        box.offerQueue(item(2, 100, 9), maxAgeNs: 5_000)
        XCTAssertEqual(box.next()?.channelId, 2)
        box.completed()
        XCTAssertEqual(box.next()?.payload, Data([2]))
        box.completed()
        XCTAssertEqual(box.next()?.payload, Data([3]))
    }

    func testLatestReplacementCountsDrops() {
        var box = Outbox()
        box.offerLatest(item(3, 1, 1))
        box.offerLatest(item(3, 2, 2))
        XCTAssertEqual(box.drops[3], 1)
        XCTAssertEqual(box.next()?.payload, Data([2]))
        XCTAssertNil(box.next())
        box.completed()
        XCTAssertTrue(box.isIdle)
    }

    func testWaitingBatchIsReplacedAndStartedBatchFinishes() {
        var box = Outbox()
        box.offerBatch(group: "arframe", items: [item(1, 10, 1), item(2, 10, 2)])
        box.offerBatch(group: "arframe", items: [item(1, 20, 3), item(2, 20, 4)])
        XCTAssertEqual(box.drops[1], 1)
        XCTAssertEqual(box.drops[2], 1)
        XCTAssertEqual(box.next()?.payload, Data([3]))
        box.offerBatch(group: "arframe", items: [item(1, 30, 5), item(2, 30, 6)])
        box.completed()
        XCTAssertEqual(box.next()?.payload, Data([4]))
        box.completed()
        XCTAssertEqual(box.next()?.payload, Data([5]))
        box.completed()
        XCTAssertEqual(box.next()?.payload, Data([6]))
        box.completed()
        XCTAssertTrue(box.isIdle)
    }

    func testPriorityKeepThenQueueThenLatestThenWaitingBatch() {
        var box = Outbox()
        box.offerLatest(item(4, 1, 40))
        box.offerBatch(group: "arframe", items: [item(3, 1, 30)])
        box.offerQueue(item(2, 1, 20), maxAgeNs: 10_000)
        box.offerKeep(item(1, 1, 10))
        XCTAssertEqual(box.next()?.payload, Data([10]))
        box.completed()
        XCTAssertEqual(box.next()?.payload, Data([20]))
        box.completed()
        XCTAssertEqual(box.next()?.payload, Data([40]))
        box.completed()
        XCTAssertEqual(box.next()?.payload, Data([30]))
    }

    func testInFlightBlocksNext() {
        var box = Outbox()
        box.offerKeep(item(1, 1, 1))
        box.offerKeep(item(1, 2, 2))
        XCTAssertNotNil(box.next())
        XCTAssertNil(box.next())
        XCTAssertFalse(box.isIdle)
        box.completed()
        XCTAssertEqual(box.next()?.payload, Data([2]))
    }

    func testOfferBatchDoesNotDropAnotherGroupsWaitingBatch() {
        var box = Outbox()
        box.offerBatch(group: "a", items: [item(1, 10, 1), item(1, 11, 2)])
        box.offerBatch(group: "b", items: [item(2, 20, 3)])
        XCTAssertNil(box.drops[1])
        XCTAssertNil(box.drops[2])
        XCTAssertEqual(box.next()?.payload, Data([1]))
        box.completed()
        XCTAssertEqual(box.next()?.payload, Data([2]))
        box.completed()
        XCTAssertEqual(box.next()?.payload, Data([3]))
    }

    func testPromoteWaitingPicksGroupWithOldestFirstTimestamp() {
        var box = Outbox()
        box.offerBatch(group: "late", items: [item(1, 100, 1), item(1, 101, 2)])
        box.offerBatch(group: "early", items: [item(2, 50, 3), item(2, 51, 4)])
        XCTAssertEqual(box.next()?.payload, Data([3]))
        box.completed()
        XCTAssertEqual(box.next()?.payload, Data([4]))
        box.completed()
        XCTAssertEqual(box.next()?.payload, Data([1]))
        box.completed()
        XCTAssertEqual(box.next()?.payload, Data([2]))
    }

    func testOutOfOrderQueueSampleDoesNotFlush() {
        var box = Outbox()
        box.offerQueue(item(1, 1000, 1), maxAgeNs: 100)
        box.offerQueue(item(1, 1050, 2), maxAgeNs: 100)
        box.offerQueue(item(1, 10, 3), maxAgeNs: 100)
        XCTAssertNil(box.drops[1])
        XCTAssertEqual(box.next()?.payload, Data([1]))
        box.completed()
        XCTAssertEqual(box.next()?.payload, Data([2]))
        box.completed()
        XCTAssertEqual(box.next()?.payload, Data([3]))
    }
}
