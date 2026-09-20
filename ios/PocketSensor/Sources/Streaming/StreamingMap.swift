import ARKit
import CoreLocation
import CoreMotion
import Foundation
import PocketSensorCore
import simd
import UIKit

/// capture の Apple 値を Core の型へ写す。単位変換は MessageBuilders 側。
enum StreamingMap {
    static func tracking(_ state: ARCamera.TrackingState) -> (state: TrackingState, reason: TrackingReason) {
        switch state {
        case .normal:
            return (.normal, .none)
        case .notAvailable:
            return (.notAvailable, .none)
        case .limited(let reason):
            switch reason {
            case .initializing: return (.limited, .initializing)
            case .excessiveMotion: return (.limited, .excessiveMotion)
            case .insufficientFeatures: return (.limited, .insufficientFeatures)
            case .relocalizing: return (.limited, .relocalizing)
            @unknown default: return (.limited, .none)
            }
        }
    }

    static func thermal(_ state: ProcessInfo.ThermalState) -> ThermalLevel {
        switch state {
        case .nominal: return .nominal
        case .fair: return .fair
        case .serious: return .serious
        case .critical: return .critical
        @unknown default: return .nominal
        }
    }

    static func locationAuthorization(_ status: CLAuthorizationStatus) -> LocationAuthorization {
        switch status {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .restricted: return .restricted
        case .authorizedWhenInUse, .authorizedAlways: return .authorized
        @unknown default: return .unknown
        }
    }

    static func battery(_ state: UIDevice.BatteryState) -> BatteryChargeState {
        switch state {
        case .unknown: return .unknown
        case .unplugged: return .discharging
        case .charging: return .charging
        case .full: return .full
        @unknown default: return .unknown
        }
    }

    static func imuReference(_ value: String) -> ImuReferenceFrame {
        value == "true_north" ? .trueNorth : .arbitrary
    }

    static func cmAttitudeFrame(_ reference: ImuReferenceFrame) -> CMAttitudeReferenceFrame {
        switch reference {
        case .arbitrary: return .xArbitraryCorrectedZVertical
        case .trueNorth: return .xTrueNorthZVertical
        }
    }

    /// CMAttitude.quaternion は DEVICE 系のベクトルを基準系へ回す。逆は取らない。
    /// 根拠: docs/measurements.md
    static func attitudeDeviceToReference(x: Double, y: Double, z: Double, w: Double) -> simd_quatd {
        simd_quatd(ix: x, iy: y, iz: z, r: w)
    }

    static func shouldSend(lastSent: Double?, now: Double, maxHz: Double) -> Bool {
        guard maxHz > 0 else { return false }
        guard let last = lastSent else { return true }
        return now - last >= 1.0 / maxHz
    }

    static func poseMatrix(_ m: simd_float4x4) -> simd_double4x4 {
        let c = m.columns
        return simd_double4x4(columns: (
            SIMD4(Double(c.0.x), Double(c.0.y), Double(c.0.z), Double(c.0.w)),
            SIMD4(Double(c.1.x), Double(c.1.y), Double(c.1.z), Double(c.1.w)),
            SIMD4(Double(c.2.x), Double(c.2.y), Double(c.2.z), Double(c.2.w)),
            SIMD4(Double(c.3.x), Double(c.3.y), Double(c.3.z), Double(c.3.w))
        ))
    }

    static func colorIntrinsics(matrix: simd_float3x3, width: Int, height: Int) -> Intrinsics {
        let c = matrix.columns
        let doubled = simd_double3x3(columns: (
            SIMD3(Double(c.0.x), Double(c.0.y), Double(c.0.z)),
            SIMD3(Double(c.1.x), Double(c.1.y), Double(c.1.z)),
            SIMD3(Double(c.2.x), Double(c.2.y), Double(c.2.z))
        ))
        return Intrinsics(arkitMatrix: doubled, width: width, height: height)
    }

    static func linkRows(from interfaces: [(name: String, address: String)]) -> [LinkAddresses.Record] {
        LinkAddresses.select(from: interfaces)
    }
}
