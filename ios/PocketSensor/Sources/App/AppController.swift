import CoreMotion
import Foundation
import QuartzCore
import simd
import UIKit

/// ARKit と Core Motion などの capture を持ち、画面用の状態を出す。
/// この段階では配信サーバーは繋がない。
@MainActor
final class AppController: ObservableObject {
    @Published private(set) var tracking = "unavailable"
    @Published private(set) var deliveredFps = 0.0
    @Published private(set) var originEpoch = 0
    @Published private(set) var depthCenterM: Float?
    @Published private(set) var thermal = ProcessInfo.processInfo.thermalState.wireName
    @Published private(set) var batteryText = "—"
    @Published private(set) var previewVisible = false
    @Published private(set) var depthPreview: UIImage?
    @Published private(set) var position: SIMD3<Float>?
    @Published private(set) var orientation: simd_quatf?
    @Published private(set) var arkitSupported = ARKitCapture.isSupported

    let arkit = ARKitCapture()
    let motion = MotionCapture()
    let location = LocationCapture()
    let battery = BatteryCapture()
    let thermalMonitor = ThermalMonitor()

    private var probe: Probe?
    private var statusTimer: Timer?
    private var didStart = false
    private var previewEnabled = false
    private let statsLock = NSLock()
    private var lastTracking = "unavailable"
    private var lastDepthCenter: Float?
    private var framesInWindow = 0
    private var lastDepthSummaryAt: TimeInterval = 0

    init() {
        if ProcessInfo.processInfo.arguments.contains("-PocketSensorProbe") {
            start()
        }
    }

    func start() {
        guard !didStart else { return }
        didStart = true

        arkit.onFrame { [weak self] sample in
            self?.handleFrame(sample)
        }
        battery.onSample { [weak self] sample in
            DispatchQueue.main.async {
                self?.applyBattery(sample)
            }
        }
        thermalMonitor.onChange { [weak self] state in
            DispatchQueue.main.async {
                self?.thermal = state.wireName
            }
        }

        let probeMode = ProcessInfo.processInfo.arguments.contains("-PocketSensorProbe")
        // Probe は callback を購読するだけ。ARKit と IMU の start はここが一度だけ行う。
        // 購読を先に付けてから start しないと、最初のフレームが rates 窓から落ちる。
        if probeMode {
            let probe = Probe(arkit: arkit, motion: motion, battery: battery, thermal: thermalMonitor)
            self.probe = probe
            probe.start()
        }

        thermalMonitor.start()
        battery.start()
        if probeMode {
            motion.start(rateHz: 100, referenceFrame: .xArbitraryCorrectedZVertical)
        }
        if arkitSupported {
            arkit.start(reset: false)
        }

        statusTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickStatus() }
        }
    }

    func resetOrigin() {
        originEpoch += 1
        arkit.resetOrigin()
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
    }

    private func applyBattery(_ sample: BatterySample) {
        if sample.level >= 0 {
            batteryText = String(format: "%.0f%%  %@", sample.level * 100, sample.state.wireName)
        } else {
            batteryText = "—"
        }
    }
}
