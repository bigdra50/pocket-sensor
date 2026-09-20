import Foundation

public enum MagCalibration: String, Equatable, Sendable {
    case unknown
    case uncalibrated
    case low
    case medium
    case high

    /// Core Motion の `CMMagneticFieldCalibrationAccuracy.rawValue`。
    /// -1 が未較正、0 / 1 / 2 が low / medium / high。
    public static func fromAccuracyRaw(_ raw: Int32) -> MagCalibration {
        switch raw {
        case -1: return .uncalibrated
        case 0: return .low
        case 1: return .medium
        case 2: return .high
        default: return .unknown
        }
    }
}

/// 位置情報の許可の状態。許可されるまで GNSS は 1 件も届かないので、クライアントが理由を知るために流す。
public enum LocationAuthorization: String, Equatable, Sendable {
    case unknown
    case notDetermined = "not_determined"
    case denied
    case restricted
    case authorized
}

public struct DiagnosticsInput: Equatable, Sendable {
    public var deviceName: String
    public var trackingState: TrackingState
    public var trackingReason: TrackingReason
    public var thermal: ThermalLevel
    public var clients: Int
    public var ratesHz: [String: Double]
    public var drops: [String: Int]
    public var encodeSkips: [String: Int]
    public var clock: ClockCheckStatus
    public var magCalibration: MagCalibration
    public var locationAuthorization: LocationAuthorization
    /// ホールド後に実際に動いているセンサー群。sim はすべて on。
    public var sensors: SensorNeeds

    public init(
        deviceName: String,
        trackingState: TrackingState,
        trackingReason: TrackingReason,
        thermal: ThermalLevel,
        clients: Int,
        ratesHz: [String: Double],
        drops: [String: Int],
        encodeSkips: [String: Int] = [:],
        clock: ClockCheckStatus,
        magCalibration: MagCalibration,
        locationAuthorization: LocationAuthorization,
        sensors: SensorNeeds = .allOn
    ) {
        self.deviceName = deviceName
        self.trackingState = trackingState
        self.trackingReason = trackingReason
        self.thermal = thermal
        self.clients = clients
        self.ratesHz = ratesHz
        self.drops = drops
        self.encodeSkips = encodeSkips
        self.clock = clock
        self.magCalibration = magCalibration
        self.locationAuthorization = locationAuthorization
        self.sensors = sensors
    }
}

public enum Diagnostics {
    public static func build(stampNs: UInt64, input: DiagnosticsInput) -> DiagnosticMsgs.DiagnosticArray {
        DiagnosticMsgs.DiagnosticArray(
            header: WireStamp.header(stampNs: stampNs, frameId: ""),
            status: [
                trackingStatus(input),
                thermalStatus(input),
                streamsStatus(input),
                clockStatus(input),
                magStatus(input),
                gnssStatus(input),
                sensorsStatus(input),
            ]
        )
    }

    private static func trackingStatus(_ input: DiagnosticsInput) -> DiagnosticMsgs.DiagnosticStatus {
        if !input.sensors.arkit {
            return status(
                level: DiagnosticMsgs.DiagnosticStatus.ok,
                name: "pocketsensor/tracking",
                message: "stopped",
                hardwareId: input.deviceName,
                values: [
                    ("state", String(TrackingState.notAvailable.rawValue)),
                    ("reason", String(TrackingReason.none.rawValue)),
                ]
            )
        }
        let level: UInt8
        let message: String
        switch input.trackingState {
        case .normal:
            level = DiagnosticMsgs.DiagnosticStatus.ok
            message = "normal"
        case .limited:
            level = DiagnosticMsgs.DiagnosticStatus.warn
            message = "limited"
        case .notAvailable:
            level = DiagnosticMsgs.DiagnosticStatus.error
            message = "not_available"
        }
        return status(
            level: level,
            name: "pocketsensor/tracking",
            message: message,
            hardwareId: input.deviceName,
            values: [
                ("state", String(input.trackingState.rawValue)),
                ("reason", String(input.trackingReason.rawValue)),
            ]
        )
    }

    private static func thermalStatus(_ input: DiagnosticsInput) -> DiagnosticMsgs.DiagnosticStatus {
        let level: UInt8
        switch input.thermal {
        case .nominal, .fair:
            level = DiagnosticMsgs.DiagnosticStatus.ok
        case .serious:
            level = DiagnosticMsgs.DiagnosticStatus.warn
        case .critical:
            level = DiagnosticMsgs.DiagnosticStatus.error
        }
        return status(
            level: level,
            name: "pocketsensor/thermal",
            message: String(describing: input.thermal),
            hardwareId: input.deviceName,
            values: [("level", String(describing: input.thermal))]
        )
    }

    private static func streamsStatus(_ input: DiagnosticsInput) -> DiagnosticMsgs.DiagnosticStatus {
        var values: [(String, String)] = [("clients", String(input.clients))]
        for key in input.ratesHz.keys.sorted() {
            values.append(("rate.\(key)", formatRate(input.ratesHz[key] ?? 0)))
        }
        for key in input.drops.keys.sorted() {
            values.append(("drops.\(key)", String(input.drops[key] ?? 0)))
        }
        for key in input.encodeSkips.keys.sorted() {
            values.append(("encode_skips.\(key)", String(input.encodeSkips[key] ?? 0)))
        }
        let dropTotal = input.drops.values.reduce(0, +)
        let level = dropTotal > 0 ? DiagnosticMsgs.DiagnosticStatus.warn : DiagnosticMsgs.DiagnosticStatus.ok
        return status(
            level: level,
            name: "pocketsensor/streams",
            message: dropTotal > 0 ? "drops" : "ok",
            hardwareId: input.deviceName,
            values: values
        )
    }

    private static func clockStatus(_ input: DiagnosticsInput) -> DiagnosticMsgs.DiagnosticStatus {
        let level: UInt8
        switch input.clock {
        case .ok, .pending:
            level = DiagnosticMsgs.DiagnosticStatus.ok
        case .suspicious:
            level = DiagnosticMsgs.DiagnosticStatus.error
        }
        return status(
            level: level,
            name: "pocketsensor/clock",
            message: input.clock.rawValue,
            hardwareId: input.deviceName,
            values: [("self_check", input.clock.rawValue)]
        )
    }

    private static func magStatus(_ input: DiagnosticsInput) -> DiagnosticMsgs.DiagnosticStatus {
        let level: UInt8
        switch input.magCalibration {
        case .high, .medium:
            level = DiagnosticMsgs.DiagnosticStatus.ok
        case .low, .unknown:
            level = DiagnosticMsgs.DiagnosticStatus.warn
        case .uncalibrated:
            level = DiagnosticMsgs.DiagnosticStatus.error
        }
        return status(
            level: level,
            name: "pocketsensor/mag",
            message: input.magCalibration.rawValue,
            hardwareId: input.deviceName,
            values: [("calibration", input.magCalibration.rawValue)]
        )
    }

    private static func gnssStatus(_ input: DiagnosticsInput) -> DiagnosticMsgs.DiagnosticStatus {
        let level: UInt8
        switch input.locationAuthorization {
        case .authorized:
            level = DiagnosticMsgs.DiagnosticStatus.ok
        case .notDetermined, .unknown:
            // 許可のダイアログは、GNSS の最初の購読か画面の GNSS 表示 ON で出る。答えるまで測位は届かない。
            level = DiagnosticMsgs.DiagnosticStatus.warn
        case .denied, .restricted:
            level = DiagnosticMsgs.DiagnosticStatus.error
        }
        return status(
            level: level,
            name: "pocketsensor/gnss",
            message: input.locationAuthorization.rawValue,
            hardwareId: input.deviceName,
            values: [("authorization", input.locationAuthorization.rawValue)]
        )
    }

    private static func sensorsStatus(_ input: DiagnosticsInput) -> DiagnosticMsgs.DiagnosticStatus {
        let sensors = input.sensors
        func token(_ on: Bool) -> String { on ? "on" : "off" }
        return status(
            level: DiagnosticMsgs.DiagnosticStatus.ok,
            name: "pocketsensor/sensors",
            message: sensors.runningMessage,
            hardwareId: input.deviceName,
            values: [
                ("arkit", token(sensors.arkit)),
                ("depth", token(sensors.depth)),
                ("motion", token(sensors.motion)),
                ("altimeter", token(sensors.altimeter)),
                ("battery", token(sensors.battery)),
                ("gnss", token(sensors.gnss)),
            ]
        )
    }

    private static func status(
        level: UInt8,
        name: String,
        message: String,
        hardwareId: String,
        values: [(String, String)]
    ) -> DiagnosticMsgs.DiagnosticStatus {
        DiagnosticMsgs.DiagnosticStatus(
            level: level,
            name: name,
            message: message,
            hardwareId: hardwareId,
            values: values.map { DiagnosticMsgs.KeyValue(key: $0.0, value: $0.1) }
        )
    }

    private static func formatRate(_ hz: Double) -> String {
        String(hz)
    }
}
