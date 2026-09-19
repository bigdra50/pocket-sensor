import Foundation
import simd

/// Apple の単位から wire の SI 単位への変換。計算は Double。
public enum Units {
    public static let standardGravity = 9.80665

    /// 深度の無効判定。65.535 m 以上は uint16 の mm に収まらない。
    public static let depthMaxM = 65.535

    public static func accelGToMps2(_ g: SIMD3<Double>) -> SIMD3<Double> {
        g * -standardGravity
    }

    public static func magMicroTeslaToTesla(_ microTesla: SIMD3<Double>) -> SIMD3<Double> {
        microTesla * 1e-6
    }

    public static func pressureKPaToPa(_ kPa: Double) -> Double {
        kPa * 1000.0
    }

    /// (-π, π] へ畳む。-π は π にする。
    public static func wrapToPi(_ angle: Double) -> Double {
        let twoPi = 2.0 * Double.pi
        var x = angle.truncatingRemainder(dividingBy: twoPi)
        if x > Double.pi {
            x -= twoPi
        } else if x <= -Double.pi {
            x += twoPi
        }
        return x
    }

    /// 真北 0° 時計回りを、東 0 rad 反時計回りへ。
    public static func courseDegToENUYaw(_ courseDeg: Double) -> Double {
        wrapToPi(.pi / 2.0 - courseDeg * .pi / 180.0)
    }

    public static func accuracyToVariance(_ accuracy: Double) -> Double {
        accuracy * accuracy
    }

    /// 水平精度が負なら NO_FIX。垂直が負なら Up の分散だけ 0。
    public static func navSatCovariance(
        horizontalAccuracy: Double,
        verticalAccuracy: Double
    ) -> (covariance: [Double], type: UInt8, status: Int8) {
        if horizontalAccuracy < 0.0 {
            return (
                Array(repeating: 0.0, count: 9),
                SensorMsgs.NavSatFix.covarianceTypeUnknown,
                SensorMsgs.NavSatStatus.statusNoFix
            )
        }
        let hh = accuracyToVariance(horizontalAccuracy)
        let vv = verticalAccuracy < 0.0 ? 0.0 : accuracyToVariance(verticalAccuracy)
        var cov = Array(repeating: 0.0, count: 9)
        cov[0] = hh
        cov[4] = hh
        cov[8] = vv
        return (cov, SensorMsgs.NavSatFix.covarianceTypeApproximated, SensorMsgs.NavSatStatus.statusFix)
    }

    /// 画素ごとに m を mm の uint16 へ。NaN、0 以下、65.535 以上は 0。半上げは Float を Double にして行う。
    public static func depthMetersToMillimeters(
        base: UnsafeRawPointer,
        width: Int,
        height: Int,
        bytesPerRow: Int
    ) -> Data {
        var out = Data(count: width * height * MemoryLayout<UInt16>.size)
        out.withUnsafeMutableBytes { dest in
            let dst = dest.bindMemory(to: UInt16.self)
            var i = 0
            for row in 0 ..< height {
                let rowBase = base.advanced(by: row * bytesPerRow)
                for col in 0 ..< width {
                    let d = Double(rowBase.load(fromByteOffset: col * MemoryLayout<Float>.size, as: Float.self))
                    dst[i] = depthSampleToMillimeters(d)
                    i += 1
                }
            }
        }
        return out
    }

    public static func depthMetersToMillimeters(_ pixels: [Float]) -> Data {
        pixels.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return Data() }
            return depthMetersToMillimeters(
                base: UnsafeRawPointer(base),
                width: pixels.count,
                height: 1,
                bytesPerRow: pixels.count * MemoryLayout<Float>.size
            )
        }
    }

    /// 行末の詰めを除いて詰める。confidence の uint8 画像に使う。
    public static func packRows(
        base: UnsafeRawPointer,
        width: Int,
        height: Int,
        bytesPerRow: Int,
        bytesPerPixel: Int
    ) -> Data {
        let rowBytes = width * bytesPerPixel
        var out = Data(count: rowBytes * height)
        out.withUnsafeMutableBytes { dest in
            guard let dst = dest.baseAddress else { return }
            for row in 0 ..< height {
                dst.advanced(by: row * rowBytes).copyMemory(
                    from: base.advanced(by: row * bytesPerRow),
                    byteCount: rowBytes
                )
            }
        }
        return out
    }

    private static func depthSampleToMillimeters(_ d: Double) -> UInt16 {
        if d.isNaN || d <= 0.0 || d >= depthMaxM {
            return 0
        }
        return UInt16(floor(d * 1000.0 + 0.5))
    }
}
