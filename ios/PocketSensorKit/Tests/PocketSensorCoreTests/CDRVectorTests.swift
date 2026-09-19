import Foundation
import PocketSensorCore
import XCTest

final class CDRVectorTests: XCTestCase {
    private static let handBuiltNames = [
        "imu_basic",
        "camera_info_plumb_bob",
        "image_depth_16uc1",
        "diagnostics_two_statuses",
        "tf_two_transforms",
        "odometry_covariance",
        "tracking_status_normal",
        "clock_sync_response",
        "battery_nan",
        "navsatfix_no_fix",
    ]

    func testEveryVectorRoundTrips() throws {
        let cases = try Self.loadCases()
        XCTAssertFalse(cases.isEmpty)
        for item in cases {
            let cdr = try XCTUnwrap(Data(hexString: item.cdrHex), item.name)
            let again = try ContractCodec.reencode(schemaName: item.schema, cdr: cdr)
            XCTAssertEqual(again, cdr, item.name)
        }
    }

    func testHandBuiltCasesMatchVectors() throws {
        let byName = Dictionary(uniqueKeysWithValues: try Self.loadCases().map { ($0.name, $0) })
        let built = Self.handBuiltEncodings()
        XCTAssertEqual(Set(built.keys), Set(Self.handBuiltNames))
        for name in Self.handBuiltNames {
            let item = try XCTUnwrap(byName[name], name)
            XCTAssertEqual(built[name]?.hexString, item.cdrHex, name)
        }
    }

    private static func loadCases() throws -> [CDRVectorCase] {
        let data = try Data(contentsOf: cdrJSONURL())
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let rawCases = try XCTUnwrap(root["cases"] as? [[String: Any]])
        return try rawCases.map { row in
            CDRVectorCase(
                name: try XCTUnwrap(row["name"] as? String),
                schema: try XCTUnwrap(row["schema"] as? String),
                cdrHex: try XCTUnwrap(row["cdr_hex"] as? String)
            )
        }
    }

    /// テストファイルから親へ辿り、契約のベクトルを見つける。
    /// ファイルは `ios/PocketSensorKit/Tests/PocketSensorCoreTests/` にあり、リポジトリ根は 5 段上。
    private static func cdrJSONURL() -> URL {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0 ..< 16 {
            let candidate = dir
                .appendingPathComponent("contract")
                .appendingPathComponent("vectors")
                .appendingPathComponent("cdr.json")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            dir.deleteLastPathComponent()
        }
        return dir
            .appendingPathComponent("contract")
            .appendingPathComponent("vectors")
            .appendingPathComponent("cdr.json")
    }

    private static func encoded<T: CDREncodable>(_ value: T) -> Data {
        var encoder = CDREncoder()
        encoder.encode(value)
        return encoder.data
    }

    private static func header(sec: Int32, nanosec: UInt32, frameId: String) -> StdMsgs.Header {
        StdMsgs.Header(
            stamp: BuiltinInterfaces.Time(sec: sec, nanosec: nanosec),
            frameId: frameId
        )
    }

    private static var identityQuaternion: GeometryMsgs.Quaternion {
        GeometryMsgs.Quaternion(x: 0, y: 0, z: 0, w: 1)
    }

    private static func handBuiltEncodings() -> [String: Data] {
        [
            "imu_basic": encoded(imuBasic()),
            "camera_info_plumb_bob": encoded(cameraInfoPlumbBob()),
            "image_depth_16uc1": encoded(imageDepth16UC1()),
            "diagnostics_two_statuses": encoded(diagnosticsTwoStatuses()),
            "tf_two_transforms": encoded(tfTwoTransforms()),
            "odometry_covariance": encoded(odometryCovariance()),
            "tracking_status_normal": encoded(trackingStatusNormal()),
            "clock_sync_response": encoded(clockSyncResponse()),
            "battery_nan": encoded(batteryNan()),
            "navsatfix_no_fix": encoded(navsatfixNoFix()),
        ]
    }

    private static func imuBasic() -> SensorMsgs.Imu {
        var orientationCovariance = Array(repeating: 0.0, count: 9)
        orientationCovariance[0] = -1.0
        return SensorMsgs.Imu(
            header: header(sec: 1, nanosec: 2, frameId: "imu_link"),
            orientation: identityQuaternion,
            orientationCovariance: orientationCovariance,
            angularVelocity: GeometryMsgs.Vector3(x: 0.5, y: -0.25, z: 0.125),
            linearAcceleration: GeometryMsgs.Vector3(x: 0.0, y: 0.0, z: 9.5)
        )
    }

    private static func cameraInfoPlumbBob() -> SensorMsgs.CameraInfo {
        let fx = 1500.5
        let fy = 1500.5
        let cx = 959.5
        let cy = 719.5
        return SensorMsgs.CameraInfo(
            header: header(sec: 10, nanosec: 20, frameId: "color_optical_frame"),
            height: 1440,
            width: 1920,
            distortionModel: "plumb_bob",
            d: [0.0, 0.0, 0.0, 0.0, 0.0],
            k: [fx, 0.0, cx, 0.0, fy, cy, 0.0, 0.0, 1.0],
            r: [1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0],
            p: [fx, 0.0, cx, 0.0, 0.0, fy, cy, 0.0, 0.0, 0.0, 1.0, 0.0],
            binningX: 0,
            binningY: 0,
            roi: SensorMsgs.RegionOfInterest()
        )
    }

    private static func imageDepth16UC1() -> SensorMsgs.Image {
        // 4x2 の 16UC1。画素 1..8 をリトルエンディアンで並べる
        let pixels = Data([
            0x01, 0x00, 0x02, 0x00, 0x03, 0x00, 0x04, 0x00,
            0x05, 0x00, 0x06, 0x00, 0x07, 0x00, 0x08, 0x00,
        ])
        return SensorMsgs.Image(
            header: header(sec: 3, nanosec: 4, frameId: "color_optical_frame"),
            height: 2,
            width: 4,
            encoding: "16UC1",
            isBigendian: 0,
            step: 8,
            data: pixels
        )
    }

    private static func diagnosticsTwoStatuses() -> DiagnosticMsgs.DiagnosticArray {
        DiagnosticMsgs.DiagnosticArray(
            header: header(sec: 5, nanosec: 6, frameId: ""),
            status: [
                DiagnosticMsgs.DiagnosticStatus(
                    level: 0,
                    name: "cpu",
                    message: "ok",
                    hardwareId: "a",
                    values: []
                ),
                DiagnosticMsgs.DiagnosticStatus(
                    level: 1,
                    name: "imu",
                    message: "warm",
                    hardwareId: "b",
                    values: [
                        DiagnosticMsgs.KeyValue(key: "thermal", value: "nominal"),
                        DiagnosticMsgs.KeyValue(key: "battery", value: "0.75"),
                        DiagnosticMsgs.KeyValue(key: "tracking", value: "normal"),
                    ]
                ),
            ]
        )
    }

    private static func stampedTF(child: String, x: Double, y: Double, z: Double) -> GeometryMsgs.TransformStamped {
        GeometryMsgs.TransformStamped(
            header: header(sec: 7, nanosec: 8, frameId: "odom"),
            childFrameId: child,
            transform: GeometryMsgs.Transform(
                translation: GeometryMsgs.Vector3(x: x, y: y, z: z),
                rotation: identityQuaternion
            )
        )
    }

    private static func tfTwoTransforms() -> Tf2Msgs.TFMessage {
        Tf2Msgs.TFMessage(
            transforms: [
                stampedTF(child: "link", x: 0.5, y: -0.25, z: 0.125),
                stampedTF(child: "imu_link", x: 0.0, y: 0.0, z: 0.0),
            ]
        )
    }

    private static func odometryCovariance() -> NavMsgs.Odometry {
        var poseCov = Array(repeating: 0.0, count: 36)
        poseCov[0] = 0.25
        poseCov[7] = 0.5
        poseCov[14] = 0.75
        poseCov[21] = 1.25
        return NavMsgs.Odometry(
            header: header(sec: 9, nanosec: 10, frameId: "odom"),
            childFrameId: "link",
            pose: GeometryMsgs.PoseWithCovariance(
                pose: GeometryMsgs.Pose(
                    position: GeometryMsgs.Point(x: 1.5, y: -2.5, z: 0.5),
                    orientation: identityQuaternion
                ),
                covariance: poseCov
            ),
            twist: GeometryMsgs.TwistWithCovariance(
                twist: GeometryMsgs.Twist(
                    linear: GeometryMsgs.Vector3(x: 0.25, y: 0.0, z: 0.0),
                    angular: GeometryMsgs.Vector3(x: 0.0, y: 0.0, z: 0.125)
                )
            )
        )
    }

    private static func trackingStatusNormal() -> PocketsensorMsgs.TrackingStatus {
        PocketsensorMsgs.TrackingStatus(
            header: header(sec: 11, nanosec: 12, frameId: "link"),
            state: PocketsensorMsgs.TrackingStatus.stateNormal,
            reason: PocketsensorMsgs.TrackingStatus.reasonNone,
            originEpoch: 3
        )
    }

    private static func clockSyncResponse() -> PocketsensorMsgs.ClockSync.Response {
        let base = UInt64(1) << 63
        return PocketsensorMsgs.ClockSync.Response(
            t1: base + 1,
            t2: base + 100,
            t3: base + 200
        )
    }

    private static func batteryNan() -> SensorMsgs.BatteryState {
        SensorMsgs.BatteryState(
            header: header(sec: 13, nanosec: 14, frameId: ""),
            voltage: 3.5,
            temperature: Float.nan,
            current: Float.nan,
            charge: Float.nan,
            capacity: Float.nan,
            designCapacity: Float.nan,
            percentage: 0.75,
            powerSupplyStatus: 2,
            powerSupplyHealth: 1,
            powerSupplyTechnology: 2,
            present: true
        )
    }

    private static func navsatfixNoFix() -> SensorMsgs.NavSatFix {
        SensorMsgs.NavSatFix(
            header: header(sec: 15, nanosec: 16, frameId: "link"),
            status: SensorMsgs.NavSatStatus(status: SensorMsgs.NavSatStatus.statusNoFix, service: 0),
            latitude: 0.0,
            longitude: 0.0,
            altitude: Double.nan,
            positionCovariance: Array(repeating: 0.0, count: 9),
            positionCovarianceType: SensorMsgs.NavSatFix.covarianceTypeUnknown
        )
    }
}

private struct CDRVectorCase {
    let name: String
    let schema: String
    let cdrHex: String
}

private extension Data {
    init?(hexString: String) {
        let chars = Array(hexString)
        guard chars.count.isMultiple(of: 2) else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(chars.count / 2)
        var index = 0
        while index < chars.count {
            let pair = String(chars[index]) + String(chars[index + 1])
            guard let byte = UInt8(pair, radix: 16) else { return nil }
            bytes.append(byte)
            index += 2
        }
        self = Data(bytes)
    }

    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
