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

    private var streamSettings: DeviceStreamSettings {
        DeviceStreamSettings(
            rates: ["pose.rate": 30, "color.rate": 15, "depth.rate": 10, "imu.rate": 100],
            colorWidth: 960,
            colorHeight: 720,
            depthWidth: 256,
            depthHeight: 192
        )
    }

    func testStreamsCoverEveryAdvertisedChannel() {
        let streams = DeviceStream.all(names: FrameNames(deviceName: "phone"), settings: streamSettings)
        let advertised = Contract.channels.filter { $0.stage == 1 }.map(\.key)
        XCTAssertEqual(Set(streams.keys), Set(advertised))
        for channel in Contract.channels where channel.stage == 1 {
            XCTAssertEqual(streams[channel.key]?.schema, channel.schema)
        }
        XCTAssertEqual(streams["odom"]?.topic, "/phone/odom")
        XCTAssertEqual(streams["tf"]?.topic, "/tf")
    }

    func testStreamsTakeRatesFromParametersThenFromTheContract() {
        let streams = DeviceStream.all(names: FrameNames(deviceName: "phone"), settings: streamSettings)
        XCTAssertEqual(streams["odom"]?.rate, 30)
        XCTAssertEqual(streams["depth_confidence"]?.rate, 10)
        XCTAssertEqual(streams["imu_raw"]?.rate, 100)
        // parameter を持たないチャンネルは、契約の固定のレートを使う。どちらも無ければ載せない。
        XCTAssertEqual(streams["mag"]?.rate, 50)
        XCTAssertEqual(streams["battery"]?.rate, 1)
        XCTAssertNil(streams["pressure"]?.rate)
        XCTAssertNil(streams["gnss_fix"]?.rate)
    }

    func testStreamsDescribeImagesWithSizeAndEncoding() {
        let streams = DeviceStream.all(names: FrameNames(deviceName: "phone"), settings: streamSettings)
        let expected: [String: (Int, Int, String)] = [
            "color_image": (960, 720, "jpeg"),
            "depth_image": (256, 192, "16UC1"),
            "depth_confidence": (256, 192, "mono8"),
            "depth_image_compressed": (256, 192, MessageBuilders.compressedDepthFormat),
            "depth_confidence_compressed": (256, 192, MessageBuilders.compressedConfidenceFormat),
        ]
        for (key, want) in expected {
            XCTAssertEqual(streams[key]?.width, want.0, key)
            XCTAssertEqual(streams[key]?.height, want.1, key)
            XCTAssertEqual(streams[key]?.encoding, want.2, key)
        }
        XCTAssertNil(streams["odom"]?.width)
        XCTAssertNil(streams["imu"]?.encoding)
    }
}
