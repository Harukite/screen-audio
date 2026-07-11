import Foundation

/// 波形显示形态预设。控制条形数 + 权重分布模式。
public enum WaveformPreset: String, CaseIterable, Codable, Sendable {
    case compact   // 3 条, 紧凑
    case spread    // 5 条, 舒展
    case bouncy    // 7 条, 跳动

    public var barCount: Int {
        switch self {
        case .compact: 3
        case .spread:  5
        case .bouncy:  7
        }
    }

    public var weights: [Float] {
        switch self {
        case .compact: [0.55, 1.0, 0.7]
        case .spread:  [0.4, 0.6, 1.0, 0.6, 0.4]
        case .bouncy:  [0.3, 0.45, 0.65, 1.0, 0.65, 0.45, 0.3]
        }
    }
}

/// 波形衰减速度。指数平滑系数越大下落越快。
public enum DecaySpeed: String, CaseIterable, Codable, Sendable {
    case fast    // 系数 0.10
    case medium  // 系数 0.07
    case slow    // 系数 0.04

    public var coefficient: Float {
        switch self {
        case .fast:   0.10
        case .medium: 0.07
        case .slow:   0.04
        }
    }
}

/// 应用设置状态，Codable 持久化用。
public struct SettingsState: Equatable, Codable, Sendable {
    public var launchAtLogin: Bool
    public var waveformPreset: WaveformPreset
    public var decaySpeed: DecaySpeed
    public var authorName: String

    public static let `default` = SettingsState(
        launchAtLogin: false,
        waveformPreset: .compact,
        decaySpeed: .fast,
        authorName: ""
    )

    public init(launchAtLogin: Bool, waveformPreset: WaveformPreset, decaySpeed: DecaySpeed, authorName: String) {
        self.launchAtLogin = launchAtLogin
        self.waveformPreset = waveformPreset
        self.decaySpeed = decaySpeed
        self.authorName = authorName
    }
}
