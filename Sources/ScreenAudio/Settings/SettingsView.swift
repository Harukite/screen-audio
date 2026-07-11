import Combine
import ScreenAudioCore
import SwiftUI

/// 设置面板，替换 volume popover 显示：开机自启 / 波形 / 衰减 / 作者。
struct SettingsView: View {
    @ObservedObject var model: SettingsViewModel

    var body: some View {
        VStack(spacing: 16) {
            // 标题
            Text("设置").font(.headline)

            Divider()

            // 开机自启
            Toggle("开机自启", isOn: Binding(
                get: { model.settings.launchAtLogin },
                set: { model.setLaunchAtLogin($0) }
            ))

            // 波形形态
            VStack(alignment: .leading, spacing: 4) {
                Text("波形形态").font(.caption).foregroundStyle(.secondary)
                Picker("", selection: Binding(
                    get: { model.settings.waveformPreset },
                    set: { model.setWaveformPreset($0) }
                )) {
                    Text("紧凑 (3条)").tag(WaveformPreset.compact)
                    Text("舒展 (5条)").tag(WaveformPreset.spread)
                    Text("跳动 (7条)").tag(WaveformPreset.bouncy)
                }
                .pickerStyle(.segmented)
            }

            // 衰减速度
            VStack(alignment: .leading, spacing: 4) {
                Text("衰减速度").font(.caption).foregroundStyle(.secondary)
                Picker("", selection: Binding(
                    get: { model.settings.decaySpeed },
                    set: { model.setDecaySpeed($0) }
                )) {
                    Text("快").tag(DecaySpeed.fast)
                    Text("中").tag(DecaySpeed.medium)
                    Text("慢").tag(DecaySpeed.slow)
                }
                .pickerStyle(.segmented)
            }

            Divider()

            // 项目作者
            VStack(alignment: .leading, spacing: 4) {
                Text("项目作者").font(.caption).foregroundStyle(.secondary)
                TextField("输入作者名", text: Binding(
                    get: { model.settings.authorName },
                    set: { model.setAuthorName($0) }
                ))
                .textFieldStyle(.roundedBorder)
            }

            Divider()

            // 返回按钮
            Button { model.onBack?() } label: {
                Label("返回音量控制", systemImage: "chevron.left")
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
        .frame(width: 240)
    }
}

/// 设置视图的 ViewModel：绑定 SettingsState，变更通过 onSave 回传 AppDelegate。
final class SettingsViewModel: ObservableObject {
    @Published var settings: SettingsState
    var onSave: ((SettingsState) -> Void)?
    var onBack: (() -> Void)?

    init(settings: SettingsState) {
        self.settings = settings
    }

    func setLaunchAtLogin(_ v: Bool) {
        settings.launchAtLogin = v
        onSave?(settings)
    }
    func setWaveformPreset(_ p: WaveformPreset) {
        settings.waveformPreset = p
        onSave?(settings)
    }
    func setDecaySpeed(_ d: DecaySpeed) {
        settings.decaySpeed = d
        onSave?(settings)
    }
    func setAuthorName(_ n: String) {
        settings.authorName = n
        onSave?(settings)
    }
}
