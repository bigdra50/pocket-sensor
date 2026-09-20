import Foundation

public enum ThermalLevel: String, Equatable, Sendable {
    case nominal
    case fair
    case serious
    case critical

    /// serious で半分、critical で 1/6。`FrameSchedule` が、フレームを選ぶ間隔へ掛ける。
    public var rateDivisor: Int {
        switch self {
        case .nominal, .fair: return 1
        case .serious: return 2
        case .critical: return 6
        }
    }
}
