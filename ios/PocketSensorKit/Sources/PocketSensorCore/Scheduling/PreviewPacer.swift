import Foundation

/// プレビュー画像を作るフレームを間引く。配信経路には載せない。
///
/// ARKit は 60 Hz で届くが、画面のプレビューは 30 Hz までにする。
/// 前の 1 組をまだ作っているあいだは、間隔が空いていても捨てる。
public struct PreviewPacer: Sendable {
    private let maxRateHz: Double
    private var lastAccepted: TimeInterval?

    public init(maxRateHz: Double) {
        self.maxRateHz = maxRateHz
    }

    /// `busy` のあいだは捨て、last accepted は動かさない。
    /// 時刻が戻ったときはセッションの作り直しとみなし、受けてリセットする。
    public mutating func shouldRender(timestamp: TimeInterval, busy: Bool) -> Bool {
        guard !busy else { return false }
        if let last = lastAccepted, timestamp >= last {
            // 1/maxRateHz − 3 ms。既定 30 Hz なら 60 Hz 入力（16.67 ms 間隔）の 2 枚に 1 枚通す
            let minInterval = (1.0 / maxRateHz) - 0.003
            if timestamp - last < minInterval {
                return false
            }
        }
        lastAccepted = timestamp
        return true
    }
}
