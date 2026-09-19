import Foundation
import PocketSensorCore
import XCTest

final class SubscriptionTableTests: XCTestCase {
    func testSubscribeAndLookup() {
        var table = SubscriptionTable()
        let known: Set<UInt32> = [1, 2]
        XCTAssertTrue(table.subscribe(subscriptionId: 10, channelId: 1, knownChannels: known).isSuccess)
        if case .failure(let error) = table.subscribe(subscriptionId: 10, channelId: 2, knownChannels: known) {
            XCTAssertEqual(error, .duplicateSubscriptionId(10))
        } else {
            XCTFail("expected duplicate subscription id")
        }
        if case .failure(let error) = table.subscribe(subscriptionId: 11, channelId: 9, knownChannels: known) {
            XCTAssertEqual(error, .unknownChannel(9))
        } else {
            XCTFail("expected unknown channel")
        }
        XCTAssertTrue(table.subscribe(subscriptionId: 12, channelId: 1, knownChannels: known).isSuccess)
        XCTAssertEqual(table.subscriptionId(forChannel: 1), [10, 12])
        XCTAssertEqual(table.channels, [1])
        XCTAssertEqual(SubscribeError.unknownChannel(9).statusMessage, "unknown channel 9")

        table.unsubscribe(subscriptionId: 10)
        XCTAssertEqual(table.subscriptionId(forChannel: 1), [12])
        table.unsubscribe(subscriptionId: 12)
        XCTAssertTrue(table.channels.isEmpty)
        table.unsubscribe(subscriptionId: 99)
    }

    func testSubscriberCountsTransitions() {
        var counts = SubscriberCounts()
        XCTAssertEqual(counts.add(1), .started(1))
        XCTAssertNil(counts.add(1))
        XCTAssertEqual(counts.count(for: 1), 2)
        XCTAssertNil(counts.remove(1))
        XCTAssertEqual(counts.remove(1), .stopped(1))
        XCTAssertEqual(counts.count(for: 1), 0)
        XCTAssertNil(counts.remove(1))
    }
}

private extension Result {
    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}
