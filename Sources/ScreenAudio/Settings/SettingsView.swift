import Combine
import Foundation
import ScreenAudioCore
import SwiftUI

// MARK: - Settings View Model

/// 设置视图的 ViewModel：绑定 SettingsState，变更通过 onSave 回传 AppDelegate。
final class SettingsViewModel: ObservableObject {
    @Published var settings: SettingsState
    var onSave: ((SettingsState) -> Void)?

    init(settings: SettingsState) {
        self.settings = settings
    }

    func setLaunchAtLogin(_ v: Bool) { settings.launchAtLogin = v; onSave?(settings) }
    func setWaveformPreset(_ p: WaveformPreset) { settings.waveformPreset = p; onSave?(settings) }
    func setDecaySpeed(_ d: DecaySpeed) { settings.decaySpeed = d; onSave?(settings) }
    func setAuthorName(_ n: String) { settings.authorName = n; onSave?(settings) }
}

// MARK: - Settings View

/// macOS 原生风格设置面板：三段分层（通用 / 波形 / 关于），
/// 波形区带实时音波形预览——切换形态或衰减速度时即时变化。
struct SettingsView: View {
    @ObservedObject var model: SettingsViewModel

    var body: some View {
        VStack(spacing: 0) {
            // ---- 通用 ----
            SectionHeader("通用")
            ToggleSettingsRow("开机自启", isOn: binding(\.launchAtLogin) { model.setLaunchAtLogin($0) }) {
                model.setLaunchAtLogin(!model.settings.launchAtLogin)
            }

            Divider().padding(.vertical, 10)

            // ---- 波形 ----
            SectionHeader("波形")
            VStack(alignment: .leading, spacing: 6) {
                Text("形态").font(.caption).foregroundStyle(.secondary)
                Picker("", selection: binding(\.waveformPreset) { model.setWaveformPreset($0) }) {
                    Text("紧凑").tag(WaveformPreset.compact)
                    Text("舒展").tag(WaveformPreset.spread)
                    Text("跳动").tag(WaveformPreset.bouncy)
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                // 实时波形预览
                WaveformPreview(preset: model.settings.waveformPreset)
                    .frame(height: 28)
                    .padding(.vertical, 4)

                Text("衰减速度").font(.caption).foregroundStyle(.secondary)
                    .padding(.top, 6)
                Picker("", selection: binding(\.decaySpeed) { model.setDecaySpeed($0) }) {
                    Text("快").tag(DecaySpeed.fast)
                    Text("中").tag(DecaySpeed.medium)
                    Text("慢").tag(DecaySpeed.slow)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            Divider().padding(.vertical, 10)

            // ---- 关于 ----
            SectionHeader("关于")
            VStack(alignment: .leading, spacing: 6) {
                Text("项目作者").font(.caption).foregroundStyle(.secondary)
                TextField("输入作者名", text: binding(\.authorName) { model.setAuthorName($0) })
                    .textFieldStyle(.roundedBorder)
            }

            Spacer()

            // 底部版本号
            Text("ScreenAudio v0.1")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.bottom, 8)
        }
        .padding(20)
        .frame(width: 380)
    }

    // helper — 双向 binding 转 onSet
    private func binding<T>(_ keyPath: WritableKeyPath<SettingsState, T>,
                            onSet: @escaping (T) -> Void)
        -> Binding<T>
    {
        Binding(
            get: { model.settings[keyPath: keyPath] },
            set: { onSet($0) }
        )
    }
}

// MARK: - Section Header

private struct SectionHeader: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.bottom, 8)
    }
}

// MARK: - Toggle Row

private struct ToggleSettingsRow: View {
    let label: String
    let isOn: Binding<Bool>
    let action: () -> Void
    init(_ label: String, isOn: Binding<Bool>, action: @escaping () -> Void) {
        self.label = label; self.isOn = isOn; self.action = action
    }
    var body: some View {
        HStack {
            Text(label)
                .frame(maxWidth: .infinity, alignment: .leading)
            Toggle("", isOn: Binding(get: { isOn.wrappedValue },
                           set: { _ in action() }))
                .labelsHidden()
        }
    }
}

// MARK: - Waveform Preview

/// 根据当前波形形态绘制静态预览（3/5/7 根条）。
/// 切换形态时跟状态栏波形同步变化。
private struct WaveformPreview: View {
    let preset: WaveformPreset

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: CGFloat(preset.barCount > 5 ? 2 : 3)) {
                ForEach(0..<preset.barCount, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(.secondary)
                        .frame(width: barWidth)
                        // 每根条高度按权重缩放（预览模拟"有音频"状态，取标高 0.7）
                        .frame(height: max(4, CGFloat(preset.weights[i]) * geo.size.height * 0.7))
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private var barWidth: CGFloat { preset.barCount > 5 ? 3 : 4 }
}
