import Foundation
import simd

/// `/<name>/device_info` の JSON。購読の直後と変更時に 1 件送る。
public struct DeviceInfo: Equatable, Sendable {
    public var schemaVersion: Int
    public var sessionId: String
    public var name: String
    public var model: String
    public var osVersion: String
    public var appVersion: String
    public var mode: String
    public var streams: [String: DeviceStream]
    public var clock: DeviceClock
    public var frames: DeviceFrames

    public init(
        schemaVersion: Int = 1,
        sessionId: String,
        name: String,
        model: String,
        osVersion: String,
        appVersion: String,
        mode: String = "arkit",
        streams: [String: DeviceStream],
        clock: DeviceClock,
        frames: DeviceFrames
    ) {
        self.schemaVersion = schemaVersion
        self.sessionId = sessionId
        self.name = name
        self.model = model
        self.osVersion = osVersion
        self.appVersion = appVersion
        self.mode = mode
        self.streams = streams
        self.clock = clock
        self.frames = frames
    }

    public func jsonString() -> String {
        var streamObjects: [String: Any] = [:]
        for key in streams.keys.sorted() {
            streamObjects[key] = streams[key]!.jsonObject()
        }
        let object: [String: Any] = [
            "schema_version": schemaVersion,
            "session_id": sessionId,
            "name": name,
            "model": model,
            "os_version": osVersion,
            "app_version": appVersion,
            "mode": mode,
            "streams": streamObjects,
            "clock": clock.jsonObject(),
            "frames": frames.jsonObject(),
        ]
        return SortedJSON.text(object)
    }
}

public struct DeviceStream: Equatable, Sendable {
    public var topic: String
    public var schema: String
    public var width: Int?
    public var height: Int?
    public var encoding: String?
    public var rate: Double?

    public init(
        topic: String,
        schema: String,
        width: Int? = nil,
        height: Int? = nil,
        encoding: String? = nil,
        rate: Double? = nil
    ) {
        self.topic = topic
        self.schema = schema
        self.width = width
        self.height = height
        self.encoding = encoding
        self.rate = rate
    }

    func jsonObject() -> [String: Any] {
        var object: [String: Any] = [
            "topic": topic,
            "schema": schema,
        ]
        if let width { object["width"] = width }
        if let height { object["height"] = height }
        if let encoding { object["encoding"] = encoding }
        if let rate { object["rate"] = rate }
        return object
    }
}

public struct DeviceClock: Equatable, Sendable {
    public var kind: String
    public var anchorNs: Int64
    public var anchoredAtWallNs: Int64
    public var selfCheck: ClockCheckStatus

    public init(
        kind: String = "mach_absolute_time",
        anchorNs: Int64,
        anchoredAtWallNs: Int64,
        selfCheck: ClockCheckStatus
    ) {
        self.kind = kind
        self.anchorNs = anchorNs
        self.anchoredAtWallNs = anchoredAtWallNs
        self.selfCheck = selfCheck
    }

    func jsonObject() -> [String: Any] {
        [
            "kind": kind,
            "anchor_ns": anchorNs,
            "anchored_at_wall_ns": anchoredAtWallNs,
            "self_check": selfCheck.rawValue,
        ]
    }
}

public struct DeviceFrames: Equatable, Sendable {
    public var odom: String
    public var link: String
    public var colorOptical: String
    public var imuLink: String
    public var staticTransforms: [DeviceStaticTransform]

    public init(
        names: FrameNames,
        staticTransforms: [DeviceStaticTransform]
    ) {
        odom = names.odom
        link = names.link
        colorOptical = names.colorOptical
        imuLink = names.imuLink
        self.staticTransforms = staticTransforms
    }

    public init(
        odom: String,
        link: String,
        colorOptical: String,
        imuLink: String,
        staticTransforms: [DeviceStaticTransform]
    ) {
        self.odom = odom
        self.link = link
        self.colorOptical = colorOptical
        self.imuLink = imuLink
        self.staticTransforms = staticTransforms
    }

    /// 光学は回転が既知で並進 0。IMU の並進は未較正。
    public static func standard(names: FrameNames) -> DeviceFrames {
        DeviceFrames(
            names: names,
            staticTransforms: [
                DeviceStaticTransform(
                    parent: names.link,
                    child: names.colorOptical,
                    translation: [0, 0, 0],
                    rotationXyzw: xyzw(Frames.linkToColorOptical),
                    calibrated: true
                ),
                DeviceStaticTransform(
                    parent: names.link,
                    child: names.imuLink,
                    translation: [0, 0, 0],
                    rotationXyzw: xyzw(Frames.linkToImu),
                    calibrated: false
                ),
            ]
        )
    }

    func jsonObject() -> [String: Any] {
        [
            "odom": odom,
            "link": link,
            "color_optical": colorOptical,
            "imu_link": imuLink,
            "static_transforms": staticTransforms.map { $0.jsonObject() },
        ]
    }
}

public struct DeviceStaticTransform: Equatable, Sendable {
    public var parent: String
    public var child: String
    public var translation: [Double]
    public var rotationXyzw: [Double]
    public var calibrated: Bool

    public init(
        parent: String,
        child: String,
        translation: [Double],
        rotationXyzw: [Double],
        calibrated: Bool
    ) {
        self.parent = parent
        self.child = child
        self.translation = translation
        self.rotationXyzw = rotationXyzw
        self.calibrated = calibrated
    }

    func jsonObject() -> [String: Any] {
        [
            "parent": parent,
            "child": child,
            "translation": translation,
            "rotation_xyzw": rotationXyzw,
            "calibrated": calibrated,
        ]
    }
}

private func xyzw(_ q: simd_quatd) -> [Double] {
    [q.vector.x, q.vector.y, q.vector.z, q.vector.w]
}
