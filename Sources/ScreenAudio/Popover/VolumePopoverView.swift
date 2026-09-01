import Combine
import CoreAudio
import ScreenAudioCore
import SwiftUI

/// UI 层的输出设备模型（比裸元组更便于 SwiftUI ForEach 识别）。
struct OutputDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let name: String
}

/// 面板的排版常量。AppKit 侧的窗口尺寸与动态高度计算共享同一份数值，
/// 避免改了 SwiftUI 行高后忘记同步 `resizePanel`。
enum PopoverMetrics {
    static let width: CGFloat = 300
    static let cornerRadius: CGFloat = 16
    /// 设备行与操作行统一行高。
    static let rowHeight: CGFloat = 28
    static let rowSpacing: CGFloat = 1
    static let rowCornerRadius: CGFloat = 7
    static let horizontalPadding: CGFloat = 12
}

/// 菜单栏点击图标弹出的主面板。
struct VolumePopoverView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var model: VolumeViewModel
    var onQuit: () -> Void
    var onContentHeightChange: (CGFloat) -> Void = { _ in }

    var body: some View {
        VStack(spacing: 0) {
            header
            volumeControl
                .padding(.top, 14)
            outputSection
                .padding(.top, 14)
            separator
                .padding(.top, 12)
                .padding(.bottom, 6)
            actionSection
        }
        .padding(.horizontal, PopoverMetrics.horizontalPadding)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .frame(width: PopoverMetrics.width)
        .fixedSize(horizontal: false, vertical: true)
        .background {
            GeometryReader { proxy in
                Color.clear.preference(key: ContentHeightPreferenceKey.self, value: proxy.size.height)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: PopoverMetrics.cornerRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5)
        }
        .onPreferenceChange(ContentHeightPreferenceKey.self, perform: onContentHeightChange)
        .transaction { transaction in
            if reduceMotion {
                transaction.disablesAnimations = true
            }
        }
    }

    /// 比 Divider 更轻的分隔线：不占满整行，颜色更淡。
    private var separator: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(height: 0.5)
            .padding(.horizontal, 4)
    }

    private var header: some View {
        HStack(spacing: 9) {
            Image(systemName: "waveform")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color.accentColor, Color.accentColor.opacity(0.72)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                }
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text("屏幕音频")
                    .font(.system(size: 13, weight: .semibold))
                Text(model.deviceSummary)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 4)

            statusDot
        }
    }

    private var statusDot: some View {
        Circle()
            .fill(model.isConnected ? Color.green : Color.secondary.opacity(0.5))
            .frame(width: 6, height: 6)
            .overlay {
                Circle()
                    .stroke(model.isConnected ? Color.green.opacity(0.25) : Color.clear, lineWidth: 3)
            }
            .accessibilityHidden(true)
            .help(model.isConnected ? "已连接" : "未连接")
    }

    private var volumeControl: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 4) {
                Text(model.muted ? "已静音" : "音量")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)

                Spacer(minLength: 0)

                Text("\(model.value)%")
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .contentTransition(.numericText(value: Double(model.value)))
                    .foregroundStyle(model.muted ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
            }

            HStack(spacing: 8) {
                MuteButton(muted: model.muted) { model.toggleMute() }

                DirectVolumeSlider(value: model.value, muted: model.muted) { value in
                    model.setValue(value)
                }
            }
        }
    }

    @ViewBuilder
    private var outputSection: some View {
        if !model.outputDevices.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                Text("输出设备")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)

                if let heightLimit = model.outputListHeightLimit {
                    ScrollView {
                        deviceRows
                    }
                    .frame(height: heightLimit)
                    .scrollIndicators(.never)
                } else {
                    deviceRows
                }
            }
        }
    }

    private var deviceRows: some View {
        VStack(spacing: PopoverMetrics.rowSpacing) {
            ForEach(model.outputDevices) { device in
                OutputDeviceRow(
                    device: device,
                    isSelected: device.id == model.currentOutputDeviceID,
                    action: { model.selectOutput(device.id) }
                )
            }
        }
    }

    private var actionSection: some View {
        VStack(spacing: PopoverMetrics.rowSpacing) {
            if model.installNeeded {
                ActionRow(title: "安装 BlackHole", systemImage: "arrow.down.circle") {
                    model.onInstall?()
                }
            }

            ActionRow(title: "设置…", systemImage: "gearshape") {
                model.onSettings?()
            }

            ActionRow(title: "退出", systemImage: "power", isDestructive: true, action: onQuit)
        }
    }
}

// MARK: - 静音按钮

private struct MuteButton: View {
    let muted: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(muted ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                .frame(width: 22, height: 22)
                .background {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(isHovered ? 0.08 : 0.045))
                }
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(PressableButtonStyle())
        .onHover { isHovered = $0 }
        .animation(.snappy(duration: 0.15), value: isHovered)
        .help(muted ? "取消静音" : "静音")
        .accessibilityLabel(muted ? "取消静音" : "静音")
    }
}

// MARK: - 行

private struct OutputDeviceRow: View {
    let device: OutputDevice
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.tint)
                    .frame(width: 12)
                    .opacity(isSelected ? 1 : 0)
                    .accessibilityHidden(true)

                Text(device.name)
                    .font(.system(size: 12.5, weight: isSelected ? .medium : .regular))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 0)
            }
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, minHeight: PopoverMetrics.rowHeight, alignment: .leading)
            .padding(.horizontal, 7)
            .background {
                RoundedRectangle(cornerRadius: PopoverMetrics.rowCornerRadius, style: .continuous)
                    .fill(isHovered ? Color.primary.opacity(0.06) : Color.clear)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(RowButtonStyle())
        .onHover { isHovered = $0 }
        .animation(.snappy(duration: 0.15), value: isHovered)
        .accessibilityLabel(device.name)
        .accessibilityValue(isSelected ? "已选中" : "")
    }
}

private struct ActionRow: View {
    let title: String
    let systemImage: String
    var isDestructive = false
    let action: () -> Void

    @State private var isHovered = false

    private var tint: Color {
        isDestructive && isHovered ? .red : .primary
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 12)
                Text(title)
                    .font(.system(size: 12.5))
                Spacer(minLength: 0)
            }
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity, minHeight: PopoverMetrics.rowHeight, alignment: .leading)
            .padding(.horizontal, 7)
            .background {
                RoundedRectangle(cornerRadius: PopoverMetrics.rowCornerRadius, style: .continuous)
                    .fill(isHovered
                          ? (isDestructive ? Color.red.opacity(0.10) : Color.primary.opacity(0.06))
                          : Color.clear)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(RowButtonStyle())
        .onHover { isHovered = $0 }
        .animation(.snappy(duration: 0.15), value: isHovered)
    }
}

// MARK: - 滑杆

private struct DirectVolumeSlider: View {
    let value: Int
    let muted: Bool
    let onChange: (Int) -> Void

    @GestureState private var isDragging = false
    @State private var isHovered = false

    private let knobSize: CGFloat = 13

    /// 静止 4pt，悬停/拖动时轨道变厚——现代 macOS 滑杆的手感提示。
    private var trackHeight: CGFloat {
        isDragging || isHovered ? 6 : 4
    }

    var body: some View {
        GeometryReader { proxy in
            let knobInset = knobSize / 2
            let travel = max(0, proxy.size.width - knobSize)
            let progress = CGFloat(value) / 100

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.10))
                    .frame(width: travel, height: trackHeight)
                    .offset(x: knobInset)

                Capsule()
                    .fill(muted ? AnyShapeStyle(Color.secondary.opacity(0.38)) : AnyShapeStyle(Color.accentColor))
                    .frame(width: travel * progress, height: trackHeight)
                    .offset(x: knobInset)

                Circle()
                    .fill(.white)
                    .overlay {
                        Circle().strokeBorder(Color.black.opacity(0.10), lineWidth: 0.5)
                    }
                    .frame(width: knobSize, height: knobSize)
                    .shadow(color: .black.opacity(isDragging ? 0.22 : 0.14), radius: isDragging ? 3 : 1.5, y: 0.5)
                    .scaleEffect(isDragging ? 1.12 : 1)
                    .offset(x: travel * progress)
            }
            // 必须显式撑满 GeometryReader：ZStack 只会按子视图宽度（travel）收缩，
            // contentShape 跟着变窄，右端 knobSize 宽的区域会点不到。
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .leading)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($isDragging) { _, state, _ in state = true }
                    .onChanged { gesture in
                        let x = min(max(gesture.location.x - knobInset, 0), travel)
                        let nextValue = travel > 0 ? Int((x / travel * 100).rounded()) : 0
                        onChange(nextValue)
                    }
            )
        }
        .frame(maxWidth: .infinity)
        .frame(height: 22)
        .focusable()
        .focusEffectDisabled()
        .onHover { isHovered = $0 }
        .onMoveCommand { direction in
            switch direction {
            case .right, .up:
                onChange(min(100, value + 5))
            case .left, .down:
                onChange(max(0, value - 5))
            default:
                break
            }
        }
        .animation(.snappy(duration: 0.2), value: isDragging)
        .animation(.snappy(duration: 0.2), value: isHovered)
        .accessibilityElement()
        .accessibilityLabel("音量")
        .accessibilityValue(muted ? "静音，\(value)%" : "\(value)%")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment:
                onChange(min(100, value + 5))
            case .decrement:
                onChange(max(0, value - 5))
            @unknown default:
                break
            }
        }
    }
}

// MARK: - 样式

private struct RowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.65 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}

private struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.snappy(duration: 0.16), value: configuration.isPressed)
    }
}

private struct ContentHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// popover 的状态：值 + 静音 + 设备摘要。`onApply` 把 UI 改动回调给 AppDelegate。
final class VolumeViewModel: ObservableObject {
    @Published var value: Int
    @Published var muted: Bool
    @Published var isConnected: Bool
    @Published var deviceSummary: String
    @Published var installNeeded: Bool
    /// 可选输出设备（已过滤 BlackHole）。
    @Published var outputDevices: [OutputDevice] = []
    /// 当前选中输出设备 id。
    @Published var currentOutputDeviceID: AudioDeviceID = 0
    /// 仅在完整设备列表高于当前屏幕时启用的安全高度限制。
    @Published var outputListHeightLimit: CGFloat?
    var onApply: ((VolumeState) -> Void)?
    var onInstall: (() -> Void)?
    var onSwitchOutput: ((AudioDeviceID) -> Void)?
    var onSettings: (() -> Void)?

    init(state: VolumeState, deviceSummary: String, installNeeded: Bool = false, isConnected: Bool = false) {
        self.value = state.value
        self.muted = state.muted
        self.isConnected = isConnected
        self.deviceSummary = deviceSummary
        self.installNeeded = installNeeded
    }

    func setValue(_ v: Int) {
        value = max(0, min(100, v))
        onApply?(VolumeState(value: value, muted: muted))
    }

    func toggleMute() {
        muted.toggle()
        onApply?(VolumeState(value: value, muted: muted))
    }

    func selectOutput(_ id: AudioDeviceID) {
        onSwitchOutput?(id)
    }
}
