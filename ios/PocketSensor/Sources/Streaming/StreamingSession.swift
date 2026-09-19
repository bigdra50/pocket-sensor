import Foundation
import PocketSensorCore
import PocketSensorServer
import QuartzCore
import UIKit

/// 前面にいるあいだの 1 セッション。背景へ回ると捨てて作り直す。
final class StreamingSession: @unchecked Sendable {
    let sessionId: String
    let server: FoxgloveServer
    private let runtime: StreamingRuntime
    private let arFrames: ARFramePublisher
    private let motionPub: MotionPublisher
    private let locationPub: LocationPublisher
    private let statusPub: StatusPublisher
    private let arkit: ARKitCapture
    private let motion: MotionCapture
    private let location: LocationCapture
    private let battery: BatteryCapture
    private var motionRunning = false
    private var locationRunning = false
    private var batteryRunning = false
    private let sensorLock = NSLock()

    var onServerState: ((String, UInt16?) -> Void)?
    var onClientCount: ((Int) -> Void)?
    var onOriginEpoch: ((UInt32) -> Void)?

    init(
        deviceName: String,
        arkit: ARKitCapture,
        motion: MotionCapture,
        location: LocationCapture,
        battery: BatteryCapture,
        thermal: ProcessInfo.ThermalState
    ) {
        sessionId = UUID().uuidString
        let anchor = SessionClocks.makeAnchor()
        let config = ServerConfig(port: 8765, deviceName: deviceName, sessionId: sessionId, advertiseBonjour: true)
        let parameters = ParameterStore(specs: Contract.parameters)
        let server = FoxgloveServer(
            config: config,
            parameters: parameters,
            anchor: anchor,
            monoClockNs: { SessionClocks.mediaNs() }
        )
        self.server = server
        self.arkit = arkit
        self.motion = motion
        self.location = location
        self.battery = battery
        runtime = StreamingRuntime(server: server, anchor: anchor, sessionId: sessionId, deviceName: deviceName)
        runtime.setThermal(StreamingMap.thermal(thermal))
        arFrames = ARFramePublisher(runtime: runtime)
        motionPub = MotionPublisher(runtime: runtime)
        locationPub = LocationPublisher(runtime: runtime)
        location.prepare()
        statusPub = StatusPublisher(runtime: runtime) { [location] in
            StreamingMap.locationAuthorization(location.authorizationStatus)
        }
        runtime.onLatchNeeded = { [weak self] in
            self?.statusPub.scheduleLatched()
        }
    }

    var originEpoch: UInt32 {
        runtime.rates().epoch
    }

    func start() {
        server.onStateChange = { [weak self] state in
            guard let self else { return }
            let port = self.server.actualPort
            self.onServerState?(state, port)
        }
        server.onClientCountChange = { [weak self] count in
            self?.onClientCount?(count)
        }
        server.onSubscribersChange = { [weak self] _, _ in
            self?.refreshSensors()
        }
        server.onParametersChange = { [weak self] changed in
            guard let self else { return }
            self.runtime.apply(changed)
            self.statusPub.publishLatchedNow()
            if changed.contains(where: { $0.name == "imu.rate" || $0.name == "imu.reference_frame" }) {
                self.restartMotionIfRunning()
            }
        }
        server.registerService("reset_origin") { [weak self] _, _ in
            guard let self else { return .failure(ServiceFailure(message: "stopped")) }
            self.resetOrigin()
            return .success(encodeCDR(StdSrvs.Trigger.Response(success: true, message: "ok")))
        }
        server.start()
        statusPub.start()
        if ARKitCapture.isSupported {
            arkit.start(reset: true)
        }
    }

    func stop() {
        runtime.markStopped()
        statusPub.stop()
        sensorLock.lock()
        let stopMotion = motionRunning
        let stopLocation = locationRunning
        let stopBattery = batteryRunning
        motionRunning = false
        locationRunning = false
        batteryRunning = false
        sensorLock.unlock()
        if stopMotion { motion.stop() }
        if stopLocation { location.stop() }
        if stopBattery { battery.stop() }
        arkit.pause()
        server.stop()
        onServerState?("stopped", nil)
        onClientCount?(0)
    }

    func handleFrame(_ sample: ARFrameSample) {
        arFrames.publish(sample)
    }

    func handleAccel(_ sample: AccelSample) {
        motionPub.handleAccel(sample)
    }

    func handleGyro(_ sample: GyroSample) {
        motionPub.handleGyro(sample)
    }

    func handleDeviceMotion(_ sample: DeviceMotionSample) {
        motionPub.handleDeviceMotion(sample)
    }

    func handleAltimeter(_ sample: AltimeterSample) {
        motionPub.handleAltimeter(sample)
    }

    func handleLocation(_ sample: LocationSample) {
        locationPub.publish(sample)
    }

    func handleBattery(_ sample: BatterySample) {
        statusPub.publishBattery(sample)
    }

    func handleThermal(_ state: ProcessInfo.ThermalState) {
        runtime.setThermal(StreamingMap.thermal(state))
    }

    func resetOrigin() {
        let epoch = runtime.incrementOriginEpoch()
        arFrames.resetGates()
        arkit.resetOrigin()
        onOriginEpoch?(epoch)
    }

    func effectiveRates() -> [String: Double] {
        let stats = server.stats()
        let nowS = CACurrentMediaTime()
        var rates: [String: Double] = [:]
        for (key, var meter) in stats.sentRateByChannelKey {
            rates[key] = meter.hz(now: nowS)
        }
        return rates
    }

    func clientCount() -> Int {
        server.stats().clients
    }

    private func refreshSensors() {
        let wantMotion =
            server.hasSubscribers("imu_raw")
            || server.hasSubscribers("imu")
            || server.hasSubscribers("mag")
            || server.hasSubscribers("pressure")
        let wantLocation = server.hasSubscribers("gnss_fix") || server.hasSubscribers("gnss_time_reference")
        let wantBattery = server.hasSubscribers("battery")

        sensorLock.lock()
        let startMotion = wantMotion && !motionRunning
        let stopMotion = !wantMotion && motionRunning
        let startLocation = wantLocation && !locationRunning
        let stopLocation = !wantLocation && locationRunning
        let startBattery = wantBattery && !batteryRunning
        let stopBattery = !wantBattery && batteryRunning
        if startMotion { motionRunning = true }
        if stopMotion { motionRunning = false }
        if startLocation { locationRunning = true }
        if stopLocation { locationRunning = false }
        if startBattery { batteryRunning = true }
        if stopBattery { batteryRunning = false }
        let imuRate = runtime.rates().imu
        let imuRef = runtime.rates().reference
        sensorLock.unlock()

        if startMotion {
            motion.start(rateHz: imuRate, referenceFrame: StreamingMap.cmAttitudeFrame(imuRef))
        } else if stopMotion {
            motion.stop()
        }
        if startLocation {
            location.start()
        } else if stopLocation {
            location.stop()
        }
        if startBattery {
            battery.start()
        } else if stopBattery {
            battery.stop()
        }
    }

    private func restartMotionIfRunning() {
        sensorLock.lock()
        let running = motionRunning
        let imuRate = runtime.rates().imu
        let imuRef = runtime.rates().reference
        sensorLock.unlock()
        guard running else { return }
        motion.start(rateHz: imuRate, referenceFrame: StreamingMap.cmAttitudeFrame(imuRef))
    }
}
