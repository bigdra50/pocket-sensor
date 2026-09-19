import Foundation
import PocketSensorCore

/// 端末名を UserDefaults に持つ。不正な値は初期値へ戻す。
final class DeviceNameStore {
    static let defaultKey = "pocketsensor.deviceName"

    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = DeviceNameStore.defaultKey) {
        self.defaults = defaults
        self.key = key
    }

    func load() -> String {
        guard let stored = defaults.string(forKey: key), DeviceName.isValid(stored) else {
            return DeviceName.defaultValue
        }
        return stored
    }

    @discardableResult
    func save(_ name: String) -> Bool {
        guard DeviceName.isValid(name) else { return false }
        defaults.set(name, forKey: key)
        return true
    }
}
