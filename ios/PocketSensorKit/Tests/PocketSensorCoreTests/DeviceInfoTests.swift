import Foundation
import PocketSensorCore
import XCTest

final class DeviceInfoTests: XCTestCase {
    func testGoldenJSONString() {
        let names = FrameNames(deviceName: "phone")
        let info = DeviceInfo(
            sessionId: "sess-1",
            name: "phone",
            model: "iPhone17,1",
            osVersion: "18.0",
            appVersion: "1.0.0",
            streams: [
                "odom": DeviceStream(topic: "/phone/odom", schema: "nav_msgs/msg/Odometry", rate: 30),
                "color_image": DeviceStream(
                    topic: "/phone/color/image/compressed",
                    schema: "sensor_msgs/msg/CompressedImage",
                    width: 960,
                    height: 720,
                    encoding: "jpeg",
                    rate: 15
                ),
            ],
            clock: DeviceClock(anchorNs: 100, anchoredAtWallNs: 200, selfCheck: .ok),
            frames: DeviceFrames.standard(names: names)
        )
        let json = info.jsonString()
        XCTAssertFalse(json.contains("\\/"))
        XCTAssertTrue(json.hasPrefix("{\"app_version\":\"1.0.0\""))
        XCTAssertEqual(json, Self.golden)
    }

    private static let golden =
        "{\"app_version\":\"1.0.0\",\"clock\":{\"anchor_ns\":100,\"anchored_at_wall_ns\":200,\"kind\":\"mach_absolute_time\",\"self_check\":\"ok\"},\"frames\":{\"color_optical\":\"phone_color_optical_frame\",\"imu_link\":\"phone_imu_link\",\"link\":\"phone_link\",\"odom\":\"phone_odom\",\"static_transforms\":[{\"calibrated\":true,\"child\":\"phone_color_optical_frame\",\"parent\":\"phone_link\",\"rotation_xyzw\":[-0.5,0.5,-0.5,0.5],\"translation\":[0,0,0]},{\"calibrated\":false,\"child\":\"phone_imu_link\",\"parent\":\"phone_link\",\"rotation_xyzw\":[0,-0.70710678118654746,0,0.70710678118654757],\"translation\":[0,0,0]}]},\"mode\":\"arkit\",\"model\":\"iPhone17,1\",\"name\":\"phone\",\"os_version\":\"18.0\",\"schema_version\":1,\"session_id\":\"sess-1\",\"streams\":{\"color_image\":{\"encoding\":\"jpeg\",\"height\":720,\"rate\":15,\"schema\":\"sensor_msgs/msg/CompressedImage\",\"topic\":\"/phone/color/image/compressed\",\"width\":960},\"odom\":{\"rate\":30,\"schema\":\"nav_msgs/msg/Odometry\",\"topic\":\"/phone/odom\"}}}"
}
