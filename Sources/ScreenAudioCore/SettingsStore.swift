import Foundation

/// 应用设置持久化（UserDefaults + JSON）。沿用 VolumeStore 模式。
public final class SettingsStore {
    private let defaults: UserDefaults
    private let key = "screenaudio.settings.v1"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func save(_ state: SettingsState) {
        if let data = try? JSONEncoder().encode(state) {
            defaults.set(data, forKey: key)
        }
    }

    /// 若无已存储设置，返回 .default。
    public func load() -> SettingsState {
        guard let data = defaults.data(forKey: key) else { return .default }
        return (try? JSONDecoder().decode(SettingsState.self, from: data)) ?? .default
    }
}
