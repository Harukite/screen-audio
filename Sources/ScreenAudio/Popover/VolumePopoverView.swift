import Combine
import CoreAudio
import ScreenAudioCore
import SwiftUI

/// UI 层的输出设备模型（比裸元组更便于 SwiftUI ForEach 识别）。
struct OutputDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let name: String
}

/// 菜单栏点击图标弹出的 popover：横向滑块 + 静音 + 设备显示。
///
/// 设计要点：
/// - 固定宽度 240pt，内容垂直堆叠；
/// - 原生横向 `Slider`（不再用 `rotationEffect` hack）；
/// - 音量数字用 `.contentTransition(.numericText())` 平滑滚动（macOS 13+）；
/// - 静音切换时图标颜色 / tint 用 `.snappy` 动画过渡。
struct VolumePopoverView: View {
    @ObservedObject var model: VolumeViewModel
    var onQuit: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            // MARK: 音量数字（顶部主视觉，居中放大）
            Text("\(model.value)")
                .font(.system(size: 40, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(model.muted ? .secondary : .primary)
                .contentTransition(.numericText(value: 1))
                .animation(.snappy, value: model.value)
                .animation(.snappy, value: model.muted)

            // MARK: 横向音量滑块（原生）
            Slider(value: Binding(
                get: { Double(model.value) },
                set: { model.setValue(Int($0.rounded())) }
            ), in: 0...100) {
                Text("音量")
            } minimumValueLabel: {
                Image(systemName: "speaker.fill")
            } maximumValueLabel: {
                Image(systemName: "speaker.wave.3.fill")
            }
            .tint(model.muted ? .secondary : .accentColor)
            .disabled(model.muted)
            .animation(.snappy, value: model.muted)

            Divider()

            // MARK: 当前输出设备
            Text(model.deviceSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            // MARK: 输出设备列表（智能路由：原生→直通，HDMI→中转）
            if !model.outputDevices.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    Text("输出设备")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    let devices = model.outputDevices
                    ForEach(devices) { (dev: OutputDevice) in
                        Button {
                            model.selectOutput(dev.id)
                        } label: {
                            HStack {
                                Text(dev.name)
                                    .foregroundStyle(dev.id == model.currentOutputDeviceID ? Color.accentColor : Color.primary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                Spacer()
                                if dev.id == model.currentOutputDeviceID {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }

            // MARK: 操作区（条件安装 + 静音/退出）
            VStack(spacing: 8) {
                if model.installNeeded {
                    Button {
                        model.onInstall?()
                    } label: {
                        Label("一键安装 BlackHole", systemImage: "arrow.down.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
                }

                HStack(spacing: 8) {
                    Button { model.onSettings?() } label: {
                        Image(systemName: "gear")
                    }
                    .buttonStyle(.borderless)

                    Button(model.muted ? "取消静音" : "静音") {
                        model.toggleMute()
                    }
                    .buttonStyle(.bordered)

                    Spacer()

                    Button("退出", action: onQuit)
                        .buttonStyle(.bordered)
                }
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
        .frame(width: 240)
    }
}

/// popover 的状态：值 + 静音 + 设备摘要。`onApply` 把 UI 改动回调给 AppDelegate。
final class VolumeViewModel: ObservableObject {
    @Published var value: Int
    @Published var muted: Bool
    @Published var deviceSummary: String
    @Published var installNeeded: Bool
    /// 可选输出设备（已过滤 BlackHole）。
    @Published var outputDevices: [OutputDevice] = []
    /// 当前选中输出设备 id。
    @Published var currentOutputDeviceID: AudioDeviceID = 0
    var onApply: ((VolumeState) -> Void)?
    var onInstall: (() -> Void)?
    var onSwitchOutput: ((AudioDeviceID) -> Void)?
    var onSettings: (() -> Void)?

    /// 是否显示设置面板（由 AppDelegate 切换，PanelRootView 感应）。
    @Published var showSettings: Bool = false


    init(state: VolumeState, deviceSummary: String, installNeeded: Bool = false) {
        self.value = state.value
        self.muted = state.muted
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
