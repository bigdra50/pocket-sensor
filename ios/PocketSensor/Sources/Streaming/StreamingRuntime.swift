import Darwin
import Foundation
import PocketSensorCore
import PocketSensorMedia
import PocketSensorServer
import QuartzCore

func encodeCDR<T: CDREncodable>(_ value: T) -> Data {
    var encoder = CDREncoder()
    encoder.encode(value)
    return encoder.data
}

enum SessionClocks {
    static func wallNs() -> Int64 {
        var ts = timespec()
        clock_gettime(CLOCK_REALTIME, &ts)
        return Int64(ts.tv_sec) * 1_000_000_000 + Int64(ts.tv_nsec)
    }

    /// `ARFrame.timestamp` / `CMLogItem.timestamp` と同じ `CACurrentMediaTime()` 系。
    static func mediaNs() -> Int64 {
        Int64((CACurrentMediaTime() * 1_000_000_000.0).rounded())
    }

    static func makeAnchor() -> ClockAnchor {
        ClockAnchor(wallNs: wallNs(), monoNs: mediaNs())
    }
}

struct SessionRates {
    var pose: Double
    var color: Double
    var width: Double
    var quality: Double
    var depth: Double
    var imu: Double
    var reference: ImuReferenceFrame
    var name: String
    var epoch: UInt32
    var thermal: ThermalLevel
    var trackingState: TrackingState
    var trackingReason: TrackingReason
    var encodeSkips: Int
    var clock: ClockCheckStatus
    var magCalibration: MagCalibration
    var colorSourceWidth: Int
    var colorSourceHeight: Int
    var depthWidth: Int
    var depthHeight: Int
    var sensors: SensorNeeds
}

/// セッション中の共有状態。capture のキューから触るので lock で守る。
final class StreamingRuntime: @unchecked Sendable {
    let server: FoxgloveServer
    let anchor: ClockAnchor
    let sessionId: String
    let jpeg = JPEGEncoder()
    let encodeQueue = DispatchQueue(label: "pocketsensor.encode", qos: .userInitiated)
    let latchQueue = DispatchQueue(label: "pocketsensor.latch")
    let lock = NSLock()

    var stopped = false
    var deviceName: String
    var originEpoch: UInt32 = 0
    var poseRate = 30.0
    var colorRate = 15.0
    var colorWidth = 960.0
    var jpegQuality = 0.8
    var depthRate = 15.0
    var imuRate = 100.0
    var imuReference = ImuReferenceFrame.arbitrary
    var thermal = ThermalLevel.nominal
    var trackingState = TrackingState.notAvailable
    var trackingReason = TrackingReason.none
    var encodeSkipCount = 0
    var colorEncodeBusy = false
    var clockStatus = ClockCheckStatus.pending
    var magCalibration = MagCalibration.unknown
    var colorSourceWidth = 1920
    var colorSourceHeight = 1440
    var depthWidth = 256
    var depthHeight = 192
    var sensors = SensorNeeds.none
    var clockAR: ClockSelfCheck?
    var clockAccel: ClockSelfCheck?
    var clockGyro: ClockSelfCheck?
    var clockMotion: ClockSelfCheck?
    var onLatchNeeded: (() -> Void)?

    init(server: FoxgloveServer, anchor: ClockAnchor, sessionId: String, deviceName: String) {
        self.server = server
        self.anchor = anchor
        self.sessionId = sessionId
        self.deviceName = deviceName
    }

    var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    func markStopped() {
        lock.lock()
        stopped = true
        lock.unlock()
    }

    func names() -> FrameNames {
        lock.lock()
        let name = deviceName
        lock.unlock()
        return FrameNames(deviceName: name)
    }

    func rates() -> SessionRates {
        lock.lock()
        defer { lock.unlock() }
        return SessionRates(
            pose: poseRate,
            color: colorRate,
            width: colorWidth,
            quality: jpegQuality,
            depth: depthRate,
            imu: imuRate,
            reference: imuReference,
            name: deviceName,
            epoch: originEpoch,
            thermal: thermal,
            trackingState: trackingState,
            trackingReason: trackingReason,
            encodeSkips: encodeSkipCount,
            clock: clockStatus,
            magCalibration: magCalibration,
            colorSourceWidth: colorSourceWidth,
            colorSourceHeight: colorSourceHeight,
            depthWidth: depthWidth,
            depthHeight: depthHeight,
            sensors: sensors
        )
    }

    func nowStampNs() -> UInt64 {
        anchor.wireTime(sensorSeconds: CACurrentMediaTime())
    }

    func apply(_ changed: [ParameterValue]) {
        lock.lock()
        defer { lock.unlock() }
        for item in changed {
            switch (item.name, item.value) {
            case ("pose.rate", .number(let value)): poseRate = value
            case ("color.rate", .number(let value)): colorRate = value
            case ("color.width", .number(let value)): colorWidth = value
            case ("color.jpeg_quality", .number(let value)): jpegQuality = value
            case ("depth.rate", .number(let value)): depthRate = value
            case ("imu.rate", .number(let value)): imuRate = value
            case ("imu.reference_frame", .string(let value)):
                imuReference = StreamingMap.imuReference(value)
            default:
                break
            }
        }
    }

    func setTracking(_ mapped: (state: TrackingState, reason: TrackingReason)) {
        lock.lock()
        trackingState = mapped.state
        trackingReason = mapped.reason
        lock.unlock()
    }

    func setThermal(_ level: ThermalLevel) {
        lock.lock()
        thermal = level
        lock.unlock()
    }

    func setMagCalibration(_ value: MagCalibration) {
        lock.lock()
        magCalibration = value
        lock.unlock()
    }

    func setSourceSize(colorWidth: Int, colorHeight: Int, depthWidth: Int?, depthHeight: Int?) {
        lock.lock()
        colorSourceWidth = colorWidth
        colorSourceHeight = colorHeight
        if let depthWidth { self.depthWidth = depthWidth }
        if let depthHeight { self.depthHeight = depthHeight }
        lock.unlock()
    }

    func setSensors(_ value: SensorNeeds) {
        lock.lock()
        sensors = value
        lock.unlock()
    }

    func incrementOriginEpoch() -> UInt32 {
        lock.lock()
        originEpoch += 1
        let value = originEpoch
        lock.unlock()
        return value
    }

    func noteClock(arframe: ClockSelfCheck? = nil, accel: ClockSelfCheck? = nil, gyro: ClockSelfCheck? = nil, motion: ClockSelfCheck? = nil) {
        lock.lock()
        if clockAR == nil, let arframe { clockAR = arframe }
        if clockAccel == nil, let accel { clockAccel = accel }
        if clockGyro == nil, let gyro { clockGyro = gyro }
        if clockMotion == nil, let motion { clockMotion = motion }
        let next = ClockCheckStatus.reducing([clockAR, clockAccel, clockGyro, clockMotion].compactMap { $0 })
        let changed = next != clockStatus
        clockStatus = next
        lock.unlock()
        if changed {
            onLatchNeeded?()
        }
    }

    func beginColorEncode() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if colorEncodeBusy {
            encodeSkipCount += 1
            return false
        }
        colorEncodeBusy = true
        return true
    }

    func endColorEncode() {
        lock.lock()
        colorEncodeBusy = false
        lock.unlock()
    }
}
