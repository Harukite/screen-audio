import Foundation

/// 音量状态持久化。注入 defaults 便于测试。
public final class VolumeStore {
    private let defaults: UserDefaults
    private let key = "screenaudio.volumeState.v1"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func save(_ state: VolumeState) {
        if let data = try? JSONEncoder().encode(state) {
            defaults.set(data, forKey: key)
        }
    }

    public func load() -> VolumeState? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(VolumeState.self, from: data)
    }
}
