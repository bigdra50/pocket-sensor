import CoreMotion
import Foundation
import PocketSensorCore
import QuartzCore
import simd
import UIKit

/// ARKit と Core Motion などの capture を持ち、前面セッションを配信サーバーへ繋ぐ。
@MainActor
final class AppController: ObservableObject {
    @Published private(set) var tracking = "unavailable"
    @Published private(set) var deliveredFps = 0.0
    @Published private(set) var poseHz = 0.0
    @Published private(set) var colorHz = 0.0
    @Published private(set) var depthHz = 0.0
    @Published private(set) var imuHz = 0.0
    @Published private(set) var originEpoch = 0
    @Published private(set) var depthCenterM: Float?
    @Published private(set) var thermal = ProcessInfo.processInfo.thermalState.wireName
    @Published private(set) var batteryText = "—"
    @Published private(set) var previewVisible = false
    @Published private(set) var depthPreview: UIImage?
    @Published private(set) var position: SIMD3<Float>?
    @Published private(set) var orientation: simd_quatf?
    @Published private(set) var arkitSupported = ARKitCapture.isSupported
    @Published private(set) var serverState = "stopped"
    @Published private(set) var serverPort: UInt16?
    @Published private(set) var clients = 0
    @Published private(set) var deviceName = DeviceName.defaultValue
    @Published private(set) var linkAddresses: [LinkAddresses.Record] = []

    let arkit = ARKitCapture()
    let motion = MotionCapture()
    let location = LocationCapture()
    let battery = BatteryCapture()
    let thermalMonitor = ThermalMonitor()
    let nameStore = DeviceNameStore()

    private var session: StreamingSession?
    private var probe: Probe?
    private var statusTimer: Timer?
    private var didStart = false
    private var previewEnabled = false
    private let probeMode = ProcessInfo.processInfo.arguments.contains("-PocketSensorProbe")
    private let statsLock = NSLock()
    private var lastTracking = "unavailable"
    private var lastDepthCenter: Float?
    private var framesInWindow = 0
    private var lastDepthSummaryAt: TimeInterval = 0

    init() {
        deviceName = nameStore.load()
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
        }
        motion.onGyro { [weak self] sample in
            self?.session?.handleGyro(sample)
        }
        motion.onDeviceMotion { [weak self] sample in
            self?.session?.handleDeviceMotion(sample)
        }
        motion.onAltimeter { [weak self] sample in
            self?.session?.handleAltimeter(sample)
        }
        location.onLocation { [weak self] sample in
            self?.session?.handleLocation(sample)
        }
        battery.onSample { [weak self] sample in
            self?.session?.handleBattery(sample)
            DispatchQueue.main.async {
                self?.applyBattery(sample)
            }
        }
        thermalMonitor.onChange { [weak self] state in
            self?.session?.handleThermal(state)
            DispatchQueue.main.async {
                self?.thermal = state.wireName
            }
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

        statusTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
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
            thermal: thermalMonitor.current
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
                self?.originEpoch = Int(epoch)
            }
        }
        self.session = session
        originEpoch = 0
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
            originEpoch += 1
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

    /// 画面タップ用。ON のあいだだけ ARFrame レートでヒートマップを作る。
    func togglePreview() {
        previewVisible.toggle()
        previewEnabled = previewVisible
        if !previewVisible {
            depthPreview = nil
            position = nil
            orientation = nil
        }
    }

    private func handleFrame(_ sample: ARFrameSample) {
        let label = ARKitCapture.trackingLabel(sample.trackingState)
        var preview: UIImage?
        var position: SIMD3<Float>?
        var orientation: simd_quatf?
        if previewEnabled {
            preview = sample.depthMap.flatMap { DepthPreview.image(of: $0) }
            let t = sample.cameraTransform.columns.3
            position = SIMD3(t.x, t.y, t.z)
            orientation = simd_quatf(sample.cameraTransform).normalized
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
        statsLock.lock()
        lastTracking = label
        framesInWindow += 1
        if updatedCenter {
            lastDepthCenter = newCenter
        }
        let depthCenter = lastDepthCenter
        statsLock.unlock()

        if previewEnabled {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.previewVisible else { return }
                self.tracking = label
                self.depthPreview = preview
                self.position = position
                self.orientation = orientation
                self.depthCenterM = depthCenter
            }
        }
    }

    private func tickStatus() {
        statsLock.lock()
        let n = framesInWindow
        framesInWindow = 0
        let label = lastTracking
        let depth = lastDepthCenter
        statsLock.unlock()
        deliveredFps = Double(n)
        tracking = label
        depthCenterM = depth
        linkAddresses = LinkAddresses.current()
        if let session {
            originEpoch = Int(session.originEpoch)
            let rates = session.effectiveRates()
            poseHz = rates["odom"] ?? 0
            colorHz = rates["color_image"] ?? 0
            depthHz = rates["depth_image"] ?? 0
            imuHz = rates["imu"] ?? rates["imu_raw"] ?? 0
            clients = session.clientCount()
        }
    }

    private func applyBattery(_ sample: BatterySample) {
        if sample.level >= 0 {
            batteryText = String(format: "%.0f%%  %@", sample.level * 100, sample.state.wireName)
        } else {
            batteryText = "—"
        }
    }
}
