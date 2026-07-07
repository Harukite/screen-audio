import Combine
import ScreenAudioCore
import SwiftUI

/// 菜单栏点击图标弹出的 popover：垂直滑块 + 静音 + 设备显示。
struct VolumePopoverView: View {
    @ObservedObject var model: VolumeViewModel
    var onQuit: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Text(model.statusIcon)
                .font(.system(size: 28))
            Text("\(model.value)")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(model.muted ? .secondary : .primary)

            // 垂直滑块（仿系统音量 popover）。macOS SwiftUI 无 sliderStyle(.vertical)
            // （该 API 仅 iOS/watchOS），用 rotationEffect 回退实现垂直方向。
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
            .frame(width: 160)
            .rotationEffect(.degrees(-90))
            .frame(width: 24, height: 160)
            .disabled(model.muted)

            Divider()
            Button(model.muted ? "取消静音" : "静音") { model.toggleMute() }
            if model.installNeeded {
                Divider()
                Button {
                    model.onInstall?()
                } label: {
                    Label("一键安装 BlackHole", systemImage: "arrow.down.circle.fill")
                }
            }
            Divider()
            HStack {
                Text(model.deviceSummary).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("退出") { onQuit() }
            }
        }
        .padding(12)
        .frame(width: 220)
    }
}

/// popover 的状态：值 + 静音 + 设备摘要。`onApply` 把 UI 改动回调给 AppDelegate。
final class VolumeViewModel: ObservableObject {
    @Published var value: Int
    @Published var muted: Bool
    @Published var deviceSummary: String
    @Published var installNeeded: Bool
    var onApply: ((VolumeState) -> Void)?
    var onInstall: (() -> Void)?

    init(state: VolumeState, deviceSummary: String, installNeeded: Bool = false) {
        self.value = state.value
        self.muted = state.muted
        self.deviceSummary = deviceSummary
        self.installNeeded = installNeeded
    }

    var statusIcon: String { muted ? "🔇" : "🔊" }

    func setValue(_ v: Int) {
        value = max(0, min(100, v))
        onApply?(VolumeState(value: value, muted: muted))
    }

    func toggleMute() {
        muted.toggle()
        onApply?(VolumeState(value: value, muted: muted))
    }
}
