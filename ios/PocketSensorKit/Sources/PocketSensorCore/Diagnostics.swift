import Foundation

public enum MagCalibration: String, Equatable, Sendable {
    case unknown
    case uncalibrated
    case low
    case medium
    case high
}

public struct DiagnosticsInput: Equatable, Sendable {
    public var deviceName: String
    public var trackingState: TrackingState
    public var trackingReason: TrackingReason
    public var thermal: ThermalLevel
    public var clients: Int
    public var ratesHz: [String: Double]
    public var drops: [String: Int]
    public var clock: ClockCheckStatus
    public var magCalibration: MagCalibration

    public init(
        deviceName: String,
        trackingState: TrackingState,
        trackingReason: TrackingReason,
        thermal: ThermalLevel,
        clients: Int,
        ratesHz: [String: Double],
        drops: [String: Int],
        clock: ClockCheckStatus,
        magCalibration: MagCalibration
    ) {
        self.deviceName = deviceName
        self.trackingState = trackingState
        self.trackingReason = trackingReason
        self.thermal = thermal
        self.clients = clients
        self.ratesHz = ratesHz
        self.drops = drops
        self.clock = clock
        self.magCalibration = magCalibration
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
            ]
        )
    }

    private static func trackingStatus(_ input: DiagnosticsInput) -> DiagnosticMsgs.DiagnosticStatus {
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
