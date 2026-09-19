/// 直近 2 秒の送信回数から Hz を出す。
public struct RateMeter: Equatable, Sendable {
    public var window: Double
    private var stamps: [Double]

    public init(window: Double = 2.0) {
        self.window = window
        stamps = []
    }

    public mutating func record(at t: Double) {
        stamps.append(t)
        trim(now: t)
    }

    public mutating func hz(now: Double) -> Double {
        trim(now: now)
        guard window > 0 else { return 0 }
        return Double(stamps.count) / window
    }

    private mutating func trim(now: Double) {
        stamps.removeAll { now - $0 > window }
    }
}
