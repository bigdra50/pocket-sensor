import CoreMotion
import Foundation
import PocketSensorCore
import QuartzCore
import simd
import UIKit

/// ARKit と Core Motion などの capture を持ち、前面セッションを配信サーバーへ繋ぐ。
@MainActor
final class AppController: ObservableObject {
    @Published private(set) var snapshot = SensorSnapshot()
    @Published private(set) var previewVisible = false
    @Published private(set) var preview: PreviewPair?
    @Published private(set) var arkitSupported = ARKitCapture.isSupported
    @Published private(set) var serverState = "stopped"
    @Published private(set) var serverPort: UInt16?
    @Published private(set) var clients = 0
    @Published private(set) var deviceName = DeviceName.defaultValue
    @Published private(set) var linkAddresses: [LinkAddresses.Record] = []
    @Published private(set) var monitorOn = true

    let arkit = ARKitCapture()
    let motion = MotionCapture()
    let location = LocationCapture()
    let battery = BatteryCapture()
    let thermalMonitor = ThermalMonitor()
    let nameStore = DeviceNameStore()
    let monitorStore = MonitorStore()

    private var session: StreamingSession?
    private var probe: Probe?
    private var statusTimer: Timer?
    private var didStart = false
    private var previewEnabled = false
    private let previewRenderer = PreviewRenderer()
    private let probeMode = ProcessInfo.processInfo.arguments.contains("-PocketSensorProbe")
    private let demoValues = ProcessInfo.processInfo.arguments.contains("-PocketSensorDemoValues")
    private let demoPreview = ProcessInfo.processInfo.arguments.contains("-PocketSensorDemoPreview")
    private let sampleBox = SampleBox()
    private var lastDepthSummaryAt: TimeInterval = 0

    private static let demoDeviceName = "pocketsensor_lab_01"
    private static let demoAddresses = [
        LinkAddresses.Record(name: "en0", address: "192.168.10.123"),
        LinkAddresses.Record(name: "en2", address: "169.254.12.34"),
    ]

    init() {
        deviceName = nameStore.load()
        monitorOn = monitorStore.load()
        if demoValues {
            snapshot = .demo
            deviceName = Self.demoDeviceName
            linkAddresses = Self.demoAddresses
            serverState = "ready"
            serverPort = 8765
            clients = 1
        }
        if demoPreview {
            previewVisible = true
            previewEnabled = true
            preview = PreviewPair(rgb: DepthPreview.demoColorBars(), depth: DepthPreview.demoGradient())
        }
        if probeMode {
            start()
        }
    }

    func start() {
        guard !didStart else { return }
        didStart = true
        UIApplication.shared.isIdleTimerDisabled = true

        arkit.onFrame { [weak self] sample in
            self?.session?.handleFrame(sample)
            self?.handleFrame(sample)
        }
        motion.onAccel { [weak self] sample in
            self?.session?.handleAccel(sample)
            self?.sampleBox.update { $0.accelG = SIMD3(sample.x, sample.y, sample.z) }
        }
        motion.onGyro { [weak self] sample in
            self?.session?.handleGyro(sample)
            self?.sampleBox.update { $0.gyroRadS = SIMD3(sample.x, sample.y, sample.z) }
        }
        motion.onDeviceMotion { [weak self] sample in
            self?.session?.handleDeviceMotion(sample)
            self?.sampleBox.update { $0.motion = sample }
        }
        motion.onAltimeter { [weak self] sample in
            self?.session?.handleAltimeter(sample)
            self?.sampleBox.update { $0.altimeter = sample }
        }
        location.onLocation { [weak self] sample in
            self?.session?.handleLocation(sample)
            self?.sampleBox.update { $0.location = sample }
        }
        battery.onSample { [weak self] sample in
            self?.session?.handleBattery(sample)
            self?.sampleBox.update { $0.battery = sample }
        }
        thermalMonitor.onChange { [weak self] state in
            self?.session?.handleThermal(state)
            self?.sampleBox.update { $0.thermal = state }
        }

        // Probe は callback を購読するだけ。ARKit と IMU の start はここが一度だけ行う。
        // 購読を先に付けてから start しないと、最初のフレームが rates 窓から落ちる。
        if probeMode {
            let probe = Probe(arkit: arkit, motion: motion, battery: battery, thermal: thermalMonitor)
            self.probe = probe
            probe.start()
        }

        thermalMonitor.start()
        if probeMode {
            battery.start()
            motion.start(rateHz: 100, referenceFrame: .xArbitraryCorrectedZVertical)
            if arkitSupported {
                arkit.start(reset: false)
            }
        } else {
            enterForeground()
        }

        tickStatus()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickStatus() }
        }
    }

    func enterForeground() {
        guard didStart, !probeMode else { return }
        guard session == nil else { return }
        UIApplication.shared.isIdleTimerDisabled = true
        let session = StreamingSession(
            deviceName: deviceName,
            arkit: arkit,
            motion: motion,
            location: location,
            battery: battery,
            thermal: thermalMonitor.current,
            monitorOn: monitorOn
        )
        session.onServerState = { [weak self] state, port in
            DispatchQueue.main.async {
                self?.serverState = state
                self?.serverPort = port
            }
        }
        session.onClientCount = { [weak self] count in
            DispatchQueue.main.async {
                self?.clients = count
            }
        }
        session.onOriginEpoch = { [weak self] epoch in
            DispatchQueue.main.async {
                self?.snapshot.originEpoch = epoch
            }
        }
        self.session = session
        snapshot.originEpoch = 0
        session.start()
    }

    func enterBackground() {
        guard didStart, !probeMode else { return }
        session?.stop()
        session = nil
        serverState = "stopped"
        serverPort = nil
        clients = 0
        UIApplication.shared.isIdleTimerDisabled = false
    }

    func resetOrigin() {
        if let session {
            session.resetOrigin()
        } else {
            snapshot.originEpoch += 1
            arkit.resetOrigin()
        }
    }

    func isValidDeviceName(_ name: String) -> Bool {
        DeviceName.isValid(name)
    }

    func setDeviceName(_ name: String) -> Bool {
        guard nameStore.save(name) else { return false }
        deviceName = name
        guard !probeMode, session != nil else { return true }
        enterBackground()
        enterForeground()
        return true
    }

    func setMonitorOn(_ on: Bool) {
        monitorOn = on
        monitorStore.save(on)
        session?.setMonitorOn(on)
    }

    /// 画面タップ用。ON のあいだだけプレビュー用 queue で RGB と深度の 1 組を作る。
    func togglePreview() {
        previewVisible.toggle()
        previewEnabled = previewVisible
        if !previewVisible {
            preview = nil
        } else if demoPreview {
            preview = PreviewPair(rgb: DepthPreview.demoColorBars(), depth: DepthPreview.demoGradient())
        }
    }

    private func handleFrame(_ sample: ARFrameSample) {
        let label = ARKitCapture.trackingLabel(sample.trackingState)
        if previewEnabled {
            previewRenderer.submit(sample) { pair in
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.previewVisible else { return }
                    self.preview = pair
                }
            }
        }
        var updatedCenter = false
        var newCenter: Float?
        if sample.timestamp - lastDepthSummaryAt >= 1.0 {
            lastDepthSummaryAt = sample.timestamp
            updatedCenter = true
            if let depth = sample.depthMap {
                newCenter = DepthSummary.centerMedian(
                    of: depth, confidence: sample.confidenceMap, fraction: DepthSummary.centerFraction
                )
            }
        }
        sampleBox.update { latest in
            latest.tracking = label
            latest.cameraTransform = sample.cameraTransform
            if updatedCenter {
                latest.depthCenterM = newCenter
            }
        }
    }

    private func tickStatus() {
        linkAddresses = LinkAddresses.current()
        if demoValues {
            snapshot = .demo
            deviceName = Self.demoDeviceName
            linkAddresses = Self.demoAddresses
            if serverPort == nil {
                serverState = "ready"
                serverPort = 8765
            }
            clients = session?.clientCount() ?? clients
            if clients == 0 {
                clients = 1
            }
            return
        }
        let latest = sampleBox.copy()
        var ratesHz: [String: Double] = [:]
        var drops: [String: Int] = [:]
        var imuReference = ImuReferenceFrame.arbitrary
        var clock = ClockCheckStatus.pending
        var origin = snapshot.originEpoch
        if let session {
            let panel = session.panelStats()
            ratesHz = panel.ratesHz
            drops = panel.drops
            clients = panel.clients
            imuReference = panel.imuReference
            clock = panel.clock
            origin = panel.originEpoch
        }
        let motionSample = latest.motion
        snapshot = SensorSnapshot.make(
            SensorSnapshot.Input(
                tracking: latest.tracking,
                originEpoch: origin,
                cameraTransform: latest.cameraTransform.map { StreamingMap.poseMatrix($0) },
                accelG: latest.accelG,
                userAccelG: motionSample.map { SIMD3($0.userAccelerationX, $0.userAccelerationY, $0.userAccelerationZ) },
                gravityG: motionSample.map { SIMD3($0.gravityX, $0.gravityY, $0.gravityZ) },
                rotationRateRadS: motionSample.map { SIMD3($0.rotationRateX, $0.rotationRateY, $0.rotationRateZ) }
                    ?? latest.gyroRadS,
                attitudeDeviceToReference: motionSample.map {
                    StreamingMap.attitudeDeviceToReference(
                        x: $0.attitudeX,
                        y: $0.attitudeY,
                        z: $0.attitudeZ,
                        w: $0.attitudeW
                    )
                },
                imuReference: imuReference,
                magneticFieldUT: motionSample.map { SIMD3($0.magneticFieldX, $0.magneticFieldY, $0.magneticFieldZ) },
                magCalibration: motionSample.map { MagCalibration.fromAccuracyRaw($0.magneticFieldAccuracy) } ?? .unknown,
                pressureKPa: latest.altimeter?.pressure,
                relativeAltitudeM: latest.altimeter?.relativeAltitude,
                gnssLatitude: latest.location?.latitude,
                gnssLongitude: latest.location?.longitude,
                gnssHorizontalAccuracyM: latest.location?.horizontalAccuracy,
                gnssAltitudeM: latest.location.flatMap { $0.verticalAccuracy >= 0 ? $0.ellipsoidalAltitude : nil },
                locationAuthorization: StreamingMap.locationAuthorization(location.authorizationStatus),
                batteryLevel: latest.battery?.level ?? -1,
                batteryState: latest.battery?.state.wireName ?? "unknown",
                thermal: latest.thermal.wireName,
                clock: clock,
                ratesHz: ratesHz,
                drops: drops,
                depthCenterM: latest.depthCenterM
            )
        )
    }
}
