import Foundation

/// gain 平滑过渡的纯函数集，防止音量跳变爆音。
/// 音频输出回调每帧调用 step()，把 current 向 target 按 50ms 时间常数靠近。
public enum GainRamp {
    /// 计算每帧步进系数。tau = 时间常数（秒），默认 50ms。
    public static func coefficient(sampleRate: Double, framesPerBuffer: Int, tau: Double = 0.05) -> Double {
        let frameDuration = Double(framesPerBuffer) / sampleRate
        return 1.0 - exp(-frameDuration / tau)
    }

    /// 单步 lerp。返回新的 current（向 target 靠近）。
    public static func step(current: Double, target: Double, coefficient: Double) -> Double {
        return current + (target - current) * coefficient
    }
}
