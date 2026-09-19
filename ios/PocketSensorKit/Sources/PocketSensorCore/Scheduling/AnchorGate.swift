/// 参照画像 anchor は追跡中だけ、名前ごとに intervalS を超えない間隔で送る。未追跡は送らない。
public struct AnchorGate: Equatable, Sendable {
    public var intervalS: Double
    private var lastSent: [String: Double]

    public init(intervalS: Double = 0.5) {
        self.intervalS = intervalS
        lastSent = [:]
    }

    public mutating func shouldSend(name: String, isTracked: Bool, atS: Double) -> Bool {
        guard isTracked else { return false }
        if let last = lastSent[name], atS - last < intervalS {
            return false
        }
        lastSent[name] = atS
        return true
    }

    public mutating func reset() {
        lastSent.removeAll()
    }
}
