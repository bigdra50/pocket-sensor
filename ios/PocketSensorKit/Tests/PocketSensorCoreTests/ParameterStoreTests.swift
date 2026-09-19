import Foundation
import PocketSensorCore
import XCTest

final class ParameterStoreTests: XCTestCase {
    func testDefaultsInSpecOrder() {
        let store = ParameterStore(specs: Contract.parameters)
        let all = store.get(names: [])
        XCTAssertEqual(all.map(\.name), Contract.parameters.map(\.name))
        XCTAssertEqual(store.number("pose.rate"), 30)
        XCTAssertEqual(store.string("device.name"), "pocketsensor")
        XCTAssertEqual(store.string("imu.reference_frame"), "arbitrary")
    }

    func testEmptyNamesMeansAllAndFilter() {
        let store = ParameterStore(specs: Contract.parameters)
        XCTAssertEqual(store.get(names: ["device.name"]).map(\.name), ["device.name"])
        XCTAssertEqual(store.get(names: ["missing"]).count, 0)
    }

    func testSetClampsIgnoresAndReportsChanges() {
        var store = ParameterStore(specs: Contract.parameters)
        let changed = store.set([
            ParameterValue(name: "pose.rate", value: .number(100)),
            ParameterValue(name: "pose.rate", value: .string("nope")),
            ParameterValue(name: "missing", value: .number(1)),
            ParameterValue(name: "device.name", value: .string("other")),
            ParameterValue(name: "imu.reference_frame", value: .string("up")),
            ParameterValue(name: "imu.reference_frame", value: .string("true_north")),
            ParameterValue(name: "color.jpeg_quality", value: .number(0.05)),
        ])
        XCTAssertEqual(
            changed.map(\.name),
            ["pose.rate", "imu.reference_frame", "color.jpeg_quality"]
        )
        XCTAssertEqual(store.number("pose.rate"), 60)
        XCTAssertEqual(store.string("device.name"), "pocketsensor")
        XCTAssertEqual(store.string("imu.reference_frame"), "true_north")
        XCTAssertEqual(store.number("color.jpeg_quality"), 0.1, accuracy: 1e-12)

        let again = store.set([ParameterValue(name: "pose.rate", value: .number(60))])
        XCTAssertTrue(again.isEmpty)

        let internalChange = store.setInternal(name: "device.name", value: .string("phone"))
        XCTAssertEqual(internalChange?.value, .string("phone"))
        XCTAssertEqual(store.string("device.name"), "phone")
    }
}
