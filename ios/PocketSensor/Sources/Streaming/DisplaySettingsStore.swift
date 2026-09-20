import Foundation
import PocketSensorCore

/// 画面の区画表示。キーが無いときは既定（Pose / IMU / Environment ON、GNSS OFF）。
final class DisplaySettingsStore {
    static let defaultKey = "pocketsensor.displaySettings"

    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = DisplaySettingsStore.defaultKey) {
        self.defaults = defaults
        self.key = key
    }

    func load() -> DisplaySettings {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode(DisplaySettings.self, from: data)
        else {
            return DisplaySettings()
        }
        return decoded
    }

    func save(_ settings: DisplaySettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: key)
    }
}
