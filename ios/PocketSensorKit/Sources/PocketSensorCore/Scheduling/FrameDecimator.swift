import Foundation

public enum ThermalLevel: String, Equatable, Sendable {
    case nominal
    case fair
    case serious
    case critical

    /// serious で半分、critical で 1/6。ARFrame の通し番号の除数へ掛ける。
    public var rateDivisor: Int {
        switch self {
        case .nominal, .fair: return 1
        case .serious: return 2
        case .critical: return 6
        }
    }
}

/// ARFrame の通し番号で間引く。遅いストリームが速いストリームの部分集合になる。
public enum FrameDecimator {
    public static func divisor(rateLimitHz: Double, baseFps: Double = 60, thermal: ThermalLevel) -> Int {
        guard rateLimitHz > 0, baseFps > 0 else { return Int.max }
        let n = Int(ceil(baseFps / rateLimitHz))
        return max(1, n) * thermal.rateDivisor
    }

    public static func shouldSend(frameIndex: UInt64, divisor: Int) -> Bool {
        guard divisor > 0 else { return false }
        return frameIndex % UInt64(divisor) == 0
    }
}
