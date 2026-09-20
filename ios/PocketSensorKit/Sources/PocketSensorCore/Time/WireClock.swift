/// セッション開始時に 1 回だけ求める、システム時刻とモノトニッククロックの差。
public struct ClockAnchor: Equatable, Sendable {
    public var wallNs: Int64
    public var monoNs: Int64
    /// wallNs - monoNs。セッションのあいだ変えない。
    public var anchorNs: Int64

    public init(wallNs: Int64, monoNs: Int64) {
        self.wallNs = wallNs
        self.monoNs = monoNs
        let (diff, overflow) = wallNs.subtractingReportingOverflow(monoNs)
        if overflow {
            self.anchorNs = wallNs >= monoNs ? Int64.max : Int64.min
        } else {
            self.anchorNs = diff
        }
    }

    /// センサー秒を最寄りの ns へ丸めてから anchor を足す。
    public func wireTime(sensorSeconds: Double) -> UInt64 {
        let scaled = sensorSeconds * 1_000_000_000.0
        guard scaled.isFinite else { return 0 }
        let rounded = scaled.rounded()
        guard rounded >= Double(Int64.min), rounded <= Double(Int64.max) else {
            return rounded > 0 ? UInt64.max : 0
        }
        return wireTime(monoNs: Int64(rounded))
    }

    public func wireTime(monoNs: Int64) -> UInt64 {
        let (sum, overflow) = monoNs.addingReportingOverflow(anchorNs)
        if overflow {
            return (monoNs >= 0 && anchorNs >= 0) ? UInt64.max : 0
        }
        if sum < 0 {
            return 0
        }
        return UInt64(sum)
    }

    /// CLLocation.timestamp はシステム時刻なので、モノトニッククロックへ換算する。
    /// t_sensor = mono(now) - (wall(now) - wallTimestamp)
    public func sensorSeconds(wallTimestampNs: Int64, nowWallNs: Int64, nowMonoNs: Int64) -> Double {
        let (wallDelta, wallOverflow) = nowWallNs.subtractingReportingOverflow(wallTimestampNs)
        let delta = wallOverflow ? (nowWallNs >= wallTimestampNs ? Int64.max : Int64.min) : wallDelta
        let (sensor, overflow) = nowMonoNs.subtractingReportingOverflow(delta)
        let sensorNs: Int64
        if overflow {
            sensorNs = nowMonoNs >= delta ? Int64.max : Int64.min
        } else {
            sensorNs = sensor
        }
        return Double(sensorNs) / 1_000_000_000.0
    }
}

/// サンプル時刻と到着時刻が同じモノトニッククロックかを見る。差が 0 秒から 0.5 秒なら ok。
public enum ClockSelfCheck: Equatable, Sendable {
    case ok(delta: Double)
    case suspicious(delta: Double)

    public static func evaluate(sampleTimestampS: Double, arrivalMonoS: Double) -> ClockSelfCheck {
        let delta = arrivalMonoS - sampleTimestampS
        if delta >= 0, delta <= 0.5 {
            return .ok(delta: delta)
        }
        return .suspicious(delta: delta)
    }
}

public enum ClockCheckStatus: String, Equatable, Sendable, Codable {
    case ok
    case suspicious
    case pending

    /// 未到着は無視する。1 件でも suspicious なら suspicious。何も無ければ pending。
    public static func reducing(_ checks: [ClockSelfCheck]) -> ClockCheckStatus {
        if checks.isEmpty { return .pending }
        for check in checks {
            if case .suspicious = check {
                return .suspicious
            }
        }
        return .ok
    }
}

enum WireStamp {
    static let nanosPerSecond: UInt64 = 1_000_000_000

    static func time(_ stampNs: UInt64) -> BuiltinInterfaces.Time {
        let sec = stampNs / nanosPerSecond
        let nanosec = stampNs % nanosPerSecond
        let sec32: Int32
        if sec > UInt64(Int32.max) {
            sec32 = Int32.max
        } else {
            sec32 = Int32(sec)
        }
        return BuiltinInterfaces.Time(sec: sec32, nanosec: UInt32(nanosec))
    }

    static func header(stampNs: UInt64, frameId: String) -> StdMsgs.Header {
        StdMsgs.Header(stamp: time(stampNs), frameId: frameId)
    }
}
