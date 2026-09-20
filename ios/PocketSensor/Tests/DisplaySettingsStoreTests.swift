import Foundation
import XCTest

@testable import PocketSensor
import PocketSensorCore

final class DisplaySettingsStoreTests: XCTestCase {
    func testMissingKeyUsesDefaultsAndPersistsJSON() throws {
        let suite = "pocketsensor.tests.display.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let store = DisplaySettingsStore(defaults: defaults, key: "display.settings")
        XCTAssertEqual(store.load(), DisplaySettings())
        let settings = DisplaySettings(pose: false, imu: false, environment: true, gnss: true)
        store.save(settings)
        XCTAssertEqual(store.load(), settings)
        defaults.removePersistentDomain(forName: suite)
    }
}
