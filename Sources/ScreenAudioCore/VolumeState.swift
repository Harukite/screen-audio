import Foundation

/// 音量状态（值类型 + 不可变更新）。UI 线程持有；effectiveGain 由音频线程消费。
public struct VolumeState: Equatable, Codable, Sendable {
    public let value: Int       // 0–100，已 clamp
    public let muted: Bool

    public init(value: Int = 50, muted: Bool = false) {
        self.value = max(0, min(100, value))
        self.muted = muted
    }

    /// 当前实际生效的线性 gain（静音时为 0）。
    public var effectiveGain: Double {
        muted ? 0.0 : PerceivedVolume.toGain(value)
    }

    /// 不可变更新：返回改了 value 的新状态。
    public func settingValue(_ newValue: Int) -> VolumeState {
        VolumeState(value: newValue, muted: self.muted)
    }
    /// 不可变更新：返回改了 muted 的新状态。
    public func settingMuted(_ flag: Bool) -> VolumeState {
        VolumeState(value: self.value, muted: flag)
    }
}
