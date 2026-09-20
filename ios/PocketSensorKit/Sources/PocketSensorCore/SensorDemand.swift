import Foundation

/// 画面の区画の表示。ON なら購読が無くてもそのセンサー群を動かす。
public struct DisplaySettings: Equatable, Sendable, Codable {
    public var pose: Bool
    public var imu: Bool
    public var environment: Bool
    public var gnss: Bool

    public init(pose: Bool = true, imu: Bool = true, environment: Bool = true, gnss: Bool = false) {
        self.pose = pose
        self.imu = imu
        self.environment = environment
        self.gnss = gnss
    }

    public static let allOff = DisplaySettings(pose: false, imu: false, environment: false, gnss: false)
}

/// センサー群ごとの要否。`depth` が true なら `arkit` も true になる。
public struct SensorNeeds: Equatable, Sendable {
    public var arkit: Bool
    public var depth: Bool
    public var motion: Bool
    public var altimeter: Bool
    public var battery: Bool
    public var gnss: Bool

    public init(
        arkit: Bool = false,
        depth: Bool = false,
        motion: Bool = false,
        altimeter: Bool = false,
        battery: Bool = false,
        gnss: Bool = false
    ) {
        self.arkit = arkit
        self.depth = depth
        self.motion = motion
        self.altimeter = altimeter
        self.battery = battery
        self.gnss = gnss
    }

    public static let none = SensorNeeds()
    public static let allOn = SensorNeeds(
        arkit: true,
        depth: true,
        motion: true,
        altimeter: true,
        battery: true,
        gnss: true
    )

    /// diagnostics の `pocketsensor/sensors` の message。動いている群を順に並べる。
    public var runningMessage: String {
        let named: [(String, Bool)] = [
            ("arkit", arkit),
            ("depth", depth),
            ("motion", motion),
            ("altimeter", altimeter),
            ("battery", battery),
            ("gnss", gnss),
        ]
        return named.filter(\.1).map(\.0).joined(separator: ",")
    }
}

/// 購読と画面表示から、センサー群の要否を決める。
public enum SensorDemand {
    public static let arkitKeys: Set<String> = Set(
        Contract.channels.filter { $0.group == "arframe" }.map(\.key)
    )
    public static let depthKeys: Set<String> = Set(
        Contract.channels.map(\.key).filter { $0.hasPrefix("depth_") }
    )
    public static let motionKeys: Set<String> = contractKeys(["imu_raw", "imu", "mag"])
    public static let altimeterKeys: Set<String> = contractKeys(["pressure"])
    public static let batteryKeys: Set<String> = contractKeys(["battery"])
    public static let gnssKeys: Set<String> = contractKeys(["gnss_fix", "gnss_time_reference"])

    public static func needs(
        subscribedKeys: Set<String>,
        display: DisplaySettings,
        previewVisible: Bool
    ) -> SensorNeeds {
        let depth = subscribedKeys.contains(where: { depthKeys.contains($0) }) || previewVisible
        let arkit =
            subscribedKeys.contains(where: { arkitKeys.contains($0) })
            || display.pose
            || previewVisible
            || depth
        return SensorNeeds(
            arkit: arkit,
            depth: depth,
            motion: subscribedKeys.contains(where: { motionKeys.contains($0) }) || display.imu,
            altimeter: subscribedKeys.contains(where: { altimeterKeys.contains($0) }) || display.environment,
            battery: subscribedKeys.contains(where: { batteryKeys.contains($0) }) || display.environment,
            gnss: subscribedKeys.contains(where: { gnssKeys.contains($0) }) || display.gnss
        )
    }

    private static func contractKeys(_ names: Set<String>) -> Set<String> {
        names.intersection(Set(Contract.channels.map(\.key)))
    }
}

/// 再接続やパネル切替でセンサーが止まってすぐ再開するのを避けるための猶予。
public struct SensorHold: Equatable, Sendable {
    public var holdSeconds: Double
    private var arkit = Field()
    private var depth = Field()
    private var motion = Field()
    private var altimeter = Field()
    private var battery = Field()
    private var gnss = Field()

    public init(holdSeconds: Double = 10) {
        self.holdSeconds = holdSeconds
    }

    public mutating func update(needs: SensorNeeds, now: TimeInterval) -> SensorNeeds {
        SensorNeeds(
            arkit: hold(&arkit, wanted: needs.arkit, now: now),
            depth: hold(&depth, wanted: needs.depth, now: now),
            motion: hold(&motion, wanted: needs.motion, now: now),
            altimeter: hold(&altimeter, wanted: needs.altimeter, now: now),
            battery: hold(&battery, wanted: needs.battery, now: now),
            gnss: hold(&gnss, wanted: needs.gnss, now: now)
        )
    }

    private func hold(_ field: inout Field, wanted: Bool, now: TimeInterval) -> Bool {
        if wanted {
            field.active = true
            field.falseSince = nil
            return true
        }
        guard field.active else { return false }
        if field.falseSince == nil {
            field.falseSince = now
        }
        if now - (field.falseSince ?? now) < holdSeconds {
            return true
        }
        field.active = false
        field.falseSince = nil
        return false
    }

    private struct Field: Equatable, Sendable {
        var active = false
        var falseSince: TimeInterval?
    }
}
