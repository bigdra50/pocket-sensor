import Foundation
import simd
import UIKit

/// 各センサーの最新 1 件。callback はここへ書くだけで、画面へ hop しない。
final class SampleBox: @unchecked Sendable {
    struct Latest {
        var tracking = "unavailable"
        var cameraTransform: simd_float4x4?
        var depthCenterM: Float?
        var accelG: SIMD3<Double>?
        var gyroRadS: SIMD3<Double>?
        var motion: DeviceMotionSample?
        var altimeter: AltimeterSample?
        var location: LocationSample?
        var battery: BatterySample?
        var thermal: ProcessInfo.ThermalState = .nominal
    }

    private let lock = NSLock()
    private var latest = Latest()

    func update(_ body: (inout Latest) -> Void) {
        lock.lock()
        body(&latest)
        lock.unlock()
    }

    func copy() -> Latest {
        lock.lock()
        defer { lock.unlock() }
        return latest
    }
}
