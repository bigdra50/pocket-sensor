import Foundation

/// ARFrame のうち、姿勢、RGB、深度として送るものを決める。
///
/// 1 段目は時刻で選ぶ。ARKit が届けるフレームの数は熱で減るので、枚数だけで間引くと、
/// 送るレートがその割合で上限を下回る（実機では 7.5 Hz のはずが 0.5 Hz まで下がった）。
/// 2 段目は、1 段目で選んだフレームの通し番号で選ぶ。こうすると遅いストリームのフレームは
/// 速いストリームのフレームに必ず含まれ、レートの設定を変えたあとも RGB と深度が同じフレームへ揃う。
/// ストリームごとに別々の時刻で間引くと、この揃い方が設定の変更の履歴に左右される。
public struct FrameSchedule: Sendable {
    public struct Due: Equatable, Sendable {
        public var pose: Bool
        public var color: Bool
        public var depth: Bool

        public static let none = Due(pose: false, color: false, depth: false)
    }

    /// フレームの時刻の揺れを吸収する幅。60 fps の間隔（16.7 ms）より十分に小さくして、
    /// 1 つ手前のフレームを誤って選ばないようにする。
    private static let toleranceSeconds = 0.003

    private var lastTick: TimeInterval?
    private var tickIndex: UInt64 = 0

    public init() {}

    public mutating func next(
        timestamp: TimeInterval,
        poseHz: Double,
        colorHz: Double,
        depthHz: Double,
        thermal: ThermalLevel
    ) -> Due {
        let baseHz = max(poseHz, colorHz, depthHz)
        guard baseHz > 0 else { return .none }
        let interval = Double(thermal.rateDivisor) / baseHz
        // 時刻が戻るのは ARKit を動かし直したときなので、待たずに選ぶ
        if let last = lastTick, timestamp >= last, timestamp - last < interval - Self.toleranceSeconds {
            return .none
        }
        lastTick = timestamp
        let index = tickIndex
        tickIndex &+= 1
        return Due(
            pose: Self.isDue(index: index, baseHz: baseHz, rateHz: poseHz),
            color: Self.isDue(index: index, baseHz: baseHz, rateHz: colorHz),
            depth: Self.isDue(index: index, baseHz: baseHz, rateHz: depthHz)
        )
    }

    private static func isDue(index: UInt64, baseHz: Double, rateHz: Double) -> Bool {
        guard rateHz > 0 else { return false }
        let every = max(1, Int((baseHz / rateHz).rounded(.up)))
        return index % UInt64(every) == 0
    }
}
