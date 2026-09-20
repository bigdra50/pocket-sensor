import Foundation

/// 待ち受けが失敗したあと、張り直すまでの待ち時間。0.5 秒から倍にし、5 秒で頭打ちにする。
///
/// ネットワークの切り替え（USB の抜き差し、WiFi の移動）では、失敗が数回続くことがある。
/// すぐに諦めず、かといって失敗を毎秒何十回も繰り返さない間隔にする。
public struct RestartBackoff: Equatable, Sendable {
    public static let initialDelay = 0.5
    public static let maxDelay = 5.0
    private var next = RestartBackoff.initialDelay

    public init() {}

    public mutating func nextDelay() -> Double {
        let delay = next
        next = min(next * 2, RestartBackoff.maxDelay)
        return delay
    }

    public mutating func reset() {
        next = RestartBackoff.initialDelay
    }
}
