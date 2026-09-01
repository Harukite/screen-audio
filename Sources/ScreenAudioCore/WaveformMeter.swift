import Foundation

/// 将源 RMS 电平转换为菜单栏像素波形所需的显示档位、布局与交互步进。
public enum WaveformMeter {
    private static let sourceAmplification: Float = 6
    private static let displayGamma: Float = 0.55
    private static let displayGain: Float = 1.1
    private static let pixelLevelCount = 5
    public static let mutedIconOpacity: Float = 0.42

    /// 24×16 点的固定画布，保证 3/5/7 列都落在同一菜单栏占位里。
    public struct IconLayout: Equatable, Sendable {
        public let canvasWidth: Int
        public let canvasHeight: Int
        public let barCount: Int
        public let barWidth: Int
        public let gap: Int
        public let startX: Int
        public let baselineY: Int
        public let pixelHeight: Int
        public let rowGap: Int

        public var totalBarWidth: Int {
            barCount * barWidth + max(0, barCount - 1) * gap
        }
    }

    public struct PixelRect: Equatable, Sendable {
        public let x: Int
        public let y: Int
        public let width: Int
        public let height: Int
    }

    public struct Particle: Equatable, Sendable {
        public let x: Int
        public let y: Int
        public let size: Int
        public let alpha: Float
    }

    /// 把触控板余数攒到整数音量步进，鼠标滚轮则一格一档。
    public struct ScrollAccumulator: Equatable, Sendable {
        public static let mouseStep = 4
        public static let mouseFineStep = 1
        public static let preciseUnit = 1.6
        public static let preciseFineUnit = 4.0

        public var remainder: Double

        public init(remainder: Double = 0) {
            self.remainder = remainder
        }

        public mutating func consume(
            scrollingDeltaY: Double,
            isPrecise: Bool,
            fineControl: Bool
        ) -> Int {
            guard scrollingDeltaY != 0 else { return 0 }
            if !isPrecise {
                remainder = 0
                let step = fineControl ? Self.mouseFineStep : Self.mouseStep
                return scrollingDeltaY > 0 ? step : -step
            }

            remainder += scrollingDeltaY
            let unit = fineControl ? Self.preciseFineUnit : Self.preciseUnit
            guard unit > 0 else { return 0 }
            let steps = Int(remainder / unit)
            remainder -= Double(steps) * unit
            return steps
        }
    }

    /// 保留音频动态范围，避免普通声音在输入端过早饱和。
    public static func sourceLevel(fromRMS rms: Float) -> Float {
        min(1, max(0, rms) * sourceAmplification)
    }

    /// 用非线性曲线抬升低音量，使小信号也能触发像素档位。
    public static func displayLevel(fromSourceLevel sourceLevel: Float) -> Float {
        let raw = min(1, max(0, sourceLevel))
        return min(1, pow(raw, displayGamma) * displayGain)
    }

    /// 将旧帧率下的指数衰减系数换算到当前显示帧率。
    public static func decayCoefficient(
        base: Float,
        sourceRate: Double,
        displayRate: Double
    ) -> Float {
        guard sourceRate > 0, displayRate > 0 else { return base }
        let clampedBase = min(1, max(0, base))
        return 1 - pow(1 - clampedBase, Float(sourceRate / displayRate))
    }

    /// 将显示电平和列权重量化为 1…5 的像素高度档位。
    public static func pixelLevel(displayLevel: Float, weight: Float) -> Int {
        let weightedLevel = max(0, displayLevel) * max(0, weight)
        return min(pixelLevelCount, max(1, Int((weightedLevel * Float(pixelLevelCount)).rounded(.up))))
    }

    /// 按列数给出整数网格布局，让 3/5/7 列在 24 点宽度内视觉居中。
    public static func iconLayout(barCount: Int) -> IconLayout {
        let count = max(1, barCount)
        let (barWidth, gap): (Int, Int)
        switch count {
        case 1...3:
            (barWidth, gap) = (2, 3)
        case 4, 5:
            (barWidth, gap) = (2, 2)
        default:
            (barWidth, gap) = (2, 1)
        }
        let totalWidth = count * barWidth + max(0, count - 1) * gap
        return IconLayout(
            canvasWidth: 24,
            canvasHeight: 18,
            barCount: count,
            barWidth: barWidth,
            gap: gap,
            startX: max(0, (24 - totalWidth) / 2),
            baselineY: 1,
            pixelHeight: 2,
            rowGap: 1
        )
    }

    /// 有声时给各列错相收一档，避免三根柱长时间锁在同一高度。
    public static func columnTarget(
        displayLevel: Float,
        weight: Float,
        column: Int,
        tick: Int
    ) -> Int {
        let base = pixelLevel(displayLevel: displayLevel, weight: weight)
        guard displayLevel > 0.03, base > 1 else { return base }
        let phase = (tick + column * 2) % 6
        if phase >= 4 {
            return max(1, base - 1)
        }
        return base
    }

    /// 瞬时上跳，随后按像素档逐步下落，形成上下跳动而不是平滑淡出。
    public static func steppedLevel(
        current: Int,
        target: Int,
        framesUntilFall: Int,
        fallInterval: Int
    ) -> (level: Int, framesUntilFall: Int) {
        let current = min(pixelLevelCount, max(1, current))
        let target = min(pixelLevelCount, max(1, target))
        let interval = max(1, fallInterval)
        if target >= current {
            return (target, interval)
        }
        if framesUntilFall > 1 {
            return (current, framesUntilFall - 1)
        }
        return (max(1, current - 1), interval)
    }

    /// 主柱的整数像素方块，从下往上堆叠。
    public static func barRects(levels: [Int], layout: IconLayout) -> [PixelRect] {
        var rects: [PixelRect] = []
        for (column, level) in levels.enumerated() where column < layout.barCount {
            let x = layout.startX + column * (layout.barWidth + layout.gap)
            let rows = min(pixelLevelCount, max(1, level))
            for row in 0..<rows {
                let y = layout.baselineY + row * (layout.pixelHeight + layout.rowGap)
                rects.append(
                    PixelRect(x: x, y: y, width: layout.barWidth, height: layout.pixelHeight)
                )
            }
        }
        return rects
    }

    /// 柱顶竖直迸出的 1×1 粒子：上跳、错相、follow-through 拖尾；横移最多 ±1。
    public static func bounceParticles(
        levels: [Int],
        rising: [Bool] = [],
        tick: Int,
        layout: IconLayout
    ) -> [Particle] {
        var particles: [Particle] = []
        let period = 8
        for (column, level) in levels.enumerated() where column < layout.barCount {
            guard level > 1 else { continue }
            let barX = layout.startX + column * (layout.barWidth + layout.gap)
            let topY = layout.baselineY + (level - 1) * (layout.pixelHeight + layout.rowGap)
            let barTop = topY + layout.pixelHeight
            let phase = (tick + column * 3).floorModulo(period)
            let jumped = column < rising.count && rising[column]
            let xJitter = (tick + column).isMultiple(of: 2) ? 0 : min(1, max(0, layout.barWidth - 1))

            if phase < 6 || jumped {
                let rise = jumped ? min(3, 1 + phase % 3) : min(3, phase)
                let y = min(layout.canvasHeight - 2, barTop + rise)
                let x = min(max(barX + xJitter, 0), layout.canvasWidth - 2)
                let alpha: Float = jumped ? 0.95 : (phase < 2 ? 0.92 : (phase < 4 ? 0.58 : 0.3))
                particles.append(Particle(x: x, y: y, size: 1, alpha: alpha))

                if rise >= 2 {
                    let trailY = max(barTop, y - 2)
                    particles.append(Particle(x: x, y: trailY, size: 1, alpha: alpha * 0.45))
                }
            }

            if level >= 3 {
                let phase2 = (tick + column * 3 + 4).floorModulo(period)
                if phase2 < 5 {
                    let rise2 = min(3, phase2)
                    let y2 = min(layout.canvasHeight - 2, barTop + rise2)
                    let x2 = min(max(barX + layout.barWidth - 1, 0), layout.canvasWidth - 2)
                    particles.append(Particle(x: x2, y: y2, size: 1, alpha: phase2 < 2 ? 0.72 : 0.34))
                }
            }
        }
        return particles
    }
}

private extension Int {
    func floorModulo(_ modulus: Int) -> Int {
        guard modulus > 0 else { return 0 }
        let remainder = self % modulus
        return remainder >= 0 ? remainder : remainder + modulus
    }
}
