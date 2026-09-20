import Foundation

/// 画面 Monitor の ON/OFF。キーが無いときは ON。
final class MonitorStore {
    static let defaultKey = "pocketsensor.monitorOn"

    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = MonitorStore.defaultKey) {
        self.defaults = defaults
        self.key = key
    }

    func load() -> Bool {
        if defaults.object(forKey: key) == nil {
            return true
        }
        return defaults.bool(forKey: key)
    }

    func save(_ on: Bool) {
        defaults.set(on, forKey: key)
    }
}
