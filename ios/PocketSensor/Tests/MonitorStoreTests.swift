import Foundation
import XCTest

@testable import PocketSensor

final class MonitorStoreTests: XCTestCase {
    func testMissingKeyDefaultsOnAndPersistsOff() {
        let suite = "pocketsensor.tests.monitor.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let store = MonitorStore(defaults: defaults, key: "monitor.on")
        XCTAssertTrue(store.load())
        store.save(false)
        XCTAssertFalse(store.load())
        store.save(true)
        XCTAssertTrue(store.load())
        defaults.removePersistentDomain(forName: suite)
    }
}
