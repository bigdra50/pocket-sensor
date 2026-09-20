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
    private var arkitRunning = false
    private var arkitStartedInSession = false
    private var depthRunning = false
    private var motionRunning = false
    private var altimeterRunning = false
    private var locationRunning = false
    private var batteryRunning = false
    private var display: DisplaySettings
    private var previewVisible: Bool
    private var hold = SensorHold()
    private var effectiveSensors = SensorNeeds.none
    private let sensorLock = NSLock()
    private let holdQueue = DispatchQueue(label: "pocketsensor.sensors")
    private var holdTimer: DispatchSourceTimer?

    var onServerState: ((String, UInt16?) -> Void)?
    var onClientCount: ((Int) -> Void)?
    var onOriginEpoch: ((UInt32) -> Void)?

    init(
        deviceName: String,
        arkit: ARKitCapture,
        motion: MotionCapture,
        location: LocationCapture,
        battery: BatteryCapture,
        thermal: ProcessInfo.ThermalState,
        display: DisplaySettings = DisplaySettings(),
        previewVisible: Bool = false
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
        self.display = display
        self.previewVisible = previewVisible
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
            self?.reconcileSensors()
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
        startHoldTimer()
        reconcileSensors()
    }

    func stop() {
        runtime.markStopped()
        statusPub.stop()
        holdTimer?.cancel()
        holdTimer = nil
        sensorLock.lock()
        let stopARKit = arkitRunning
        let stopMotion = motionRunning
        let stopAltimeter = altimeterRunning
        let stopLocation = locationRunning
        let stopBattery = batteryRunning
        arkitRunning = false
        depthRunning = false
        motionRunning = false
        altimeterRunning = false
        locationRunning = false
        batteryRunning = false
        effectiveSensors = .none
        sensorLock.unlock()
        runtime.setSensors(.none)
        if stopMotion { motion.stopMotion() }
        if stopAltimeter { motion.stopAltimeter() }
        if stopLocation { location.stop() }
        if stopBattery { battery.stop() }
        if stopARKit { arkit.pause() }
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
        sensorLock.lock()
        let running = arkitRunning
        sensorLock.unlock()
        let epoch = runtime.incrementOriginEpoch()
        arFrames.resetGates()
        if running {
            arkit.resetOrigin()
        }
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

    func setDisplaySettings(_ settings: DisplaySettings) {
        sensorLock.lock()
        display = settings
        sensorLock.unlock()
        reconcileSensors()
    }

    func setPreviewVisible(_ visible: Bool) {
        sensorLock.lock()
        previewVisible = visible
        sensorLock.unlock()
        reconcileSensors()
    }

    func runningSensors() -> SensorNeeds {
        sensorLock.lock()
        defer { sensorLock.unlock() }
        return effectiveSensors
    }

    func panelStats() -> (
        ratesHz: [String: Double],
        drops: [String: Int],
        clients: Int,
        originEpoch: UInt32,
        imuReference: ImuReferenceFrame,
        clock: ClockCheckStatus,
        magCalibration: MagCalibration,
        sensors: SensorNeeds
    ) {
        let stats = server.stats()
        let nowS = CACurrentMediaTime()
        var rates: [String: Double] = [:]
        for (key, var meter) in stats.sentRateByChannelKey {
            rates[key] = meter.hz(now: nowS)
        }
        let sessionRates = runtime.rates()
        return (
            rates,
            stats.dropsByChannelKey,
            stats.clients,
            sessionRates.epoch,
            sessionRates.reference,
            sessionRates.clock,
            sessionRates.magCalibration,
            sessionRates.sensors
        )
    }

    private func startHoldTimer() {
        let timer = DispatchSource.makeTimerSource(queue: holdQueue)
        timer.schedule(deadline: .now() + 1.0, repeating: 1.0, leeway: .milliseconds(50))
        timer.setEventHandler { [weak self] in
            self?.reconcileSensors()
        }
        timer.resume()
        holdTimer = timer
    }

    /// 購読、画面、プレビュー、ホールド期限から start/stop を決める。
    /// センサーの経路へは入らず、capture のキューも待たない。
    private func reconcileSensors() {
        let subscribed = server.subscribedKeys()
        sensorLock.lock()
        let needs = SensorDemand.needs(
            subscribedKeys: subscribed,
            display: display,
            previewVisible: previewVisible
        )
        let effective = hold.update(needs: needs, now: CACurrentMediaTime())
        var running = effective
        if !ARKitCapture.isSupported {
            running.arkit = false
            running.depth = false
        }
        effectiveSensors = running
        runtime.setSensors(running)

        let startARKit = running.arkit && !arkitRunning
        let stopARKit = !running.arkit && arkitRunning
        let bumpEpoch = startARKit && arkitStartedInSession
        let changeDepth = running.arkit && arkitRunning && running.depth != depthRunning
        let depthWanted = running.depth
        let startMotion = running.motion && !motionRunning
        let stopMotion = !running.motion && motionRunning
        let startAltimeter = running.altimeter && !altimeterRunning
        let stopAltimeter = !running.altimeter && altimeterRunning
        let startLocation = running.gnss && !locationRunning
        let stopLocation = !running.gnss && locationRunning
        let startBattery = running.battery && !batteryRunning
        let stopBattery = !running.battery && batteryRunning
        if startARKit {
            arkitRunning = true
            arkitStartedInSession = true
            depthRunning = depthWanted
        }
        if stopARKit {
            arkitRunning = false
            depthRunning = false
        }
        if changeDepth {
            depthRunning = depthWanted
        }
        if startMotion { motionRunning = true }
        if stopMotion { motionRunning = false }
        if startAltimeter { altimeterRunning = true }
        if stopAltimeter { altimeterRunning = false }
        if startLocation { locationRunning = true }
        if stopLocation { locationRunning = false }
        if startBattery { batteryRunning = true }
        if stopBattery { batteryRunning = false }
        let imuRate = runtime.rates().imu
        let imuRef = runtime.rates().reference
        sensorLock.unlock()

        if startARKit {
            if bumpEpoch {
                let epoch = runtime.incrementOriginEpoch()
                arFrames.resetGates()
                onOriginEpoch?(epoch)
            }
            arkit.start(reset: true, depth: depthWanted)
        } else if stopARKit {
            arkit.pause()
            runtime.setTracking((.notAvailable, .none))
        } else if changeDepth {
            arkit.setDepth(depthWanted)
        }

        if startMotion {
            motion.start(rateHz: imuRate, referenceFrame: StreamingMap.cmAttitudeFrame(imuRef))
        } else if stopMotion {
            motion.stopMotion()
        }
        if startAltimeter {
            motion.startAltimeter()
        } else if stopAltimeter {
            motion.stopAltimeter()
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
