import Foundation

/// 0–100 滑块值 ↔ 0.0–1.0 线性 gain 的感知曲线映射。
/// 人耳对音量是对数感知，用 (v/100)^exponent 指数曲线。
public enum PerceivedVolume {
    /// 曲线指数。MVP 固定 2.5；v2 可调。
    public static let exponent: Double = 2.5

    /// 滑块值（0–100，自动 clamp）→ 线性 gain（0.0–1.0）
    public static func toGain(_ value: Int) -> Double {
        let clamped = max(0, min(100, value))
        return pow(Double(clamped) / 100.0, exponent)
    }

    /// 线性 gain（0.0–1.0，自动 clamp）→ 滑块值（0–100）
    public static func toValue(_ gain: Double) -> Int {
        let clamped = max(0.0, min(1.0, gain))
        return Int((pow(clamped, 1.0 / exponent) * 100.0).rounded())
    }
}
