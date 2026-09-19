import Foundation
import PocketSensorCore
import XCTest

final class FoxgloveAdvertisementTests: XCTestCase {
    func testStage1ChannelsFollowContractOrder() {
        let channels = FoxgloveAdvertisement.channels(deviceName: "phone", stages: [1])
        let specs = FoxgloveAdvertisement.channelSpecs(stages: [1])
        XCTAssertEqual(channels.count, specs.count)
        XCTAssertEqual(channels.map(\.id), Array(1 ... UInt32(channels.count)))
        XCTAssertEqual(channels[0].topic, "/phone/odom")
        XCTAssertEqual(channels[0].schemaName, "nav_msgs/msg/Odometry")
        XCTAssertEqual(channels[0].encoding, "cdr")
        XCTAssertEqual(channels[0].schemaEncoding, "ros2msg")
        XCTAssertEqual(channels[0].schema, ContractSchemas.text(for: "nav_msgs/msg/Odometry"))
        XCTAssertFalse(channels.contains { $0.topic.contains("gnss/vel") })
        XCTAssertEqual(channels.last?.topic, "/diagnostics")
    }

    func testStage1ServicesUseRequestResponseSchemaNames() {
        let services = FoxgloveAdvertisement.services(deviceName: "phone", stages: [1])
        XCTAssertEqual(services.count, 2)
        XCTAssertEqual(services[0].id, 1)
        XCTAssertEqual(services[0].name, "/phone/clock_sync")
        XCTAssertEqual(services[0].type, "pocketsensor_msgs/srv/ClockSync")
        XCTAssertEqual(services[0].request.schemaName, "pocketsensor_msgs/srv/ClockSync_Request")
        XCTAssertEqual(services[0].response.schemaName, "pocketsensor_msgs/srv/ClockSync_Response")
        XCTAssertEqual(services[0].request.encoding, "cdr")
        XCTAssertEqual(services[0].request.schemaEncoding, "ros2msg")
        XCTAssertEqual(services[1].name, "/phone/reset_origin")
        XCTAssertEqual(services[1].type, "std_srvs/srv/Trigger")
        XCTAssertEqual(services[1].request.schemaName, "std_srvs/srv/Trigger_Request")
        XCTAssertEqual(services[1].response.schemaName, "std_srvs/srv/Trigger_Response")
    }
}
