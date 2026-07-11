import Combine
import Foundation
import ScreenAudioCore
import SwiftUI

// MARK: - Settings View Model

final class SettingsViewModel: ObservableObject {
    @Published var settings: SettingsState
    @Published var selectedTab: SettingsTab = .general
    var onSave: ((SettingsState) -> Void)?

    init(settings: SettingsState) {
        self.settings = settings
    }

    func setLaunchAtLogin(_ v: Bool) { settings.launchAtLogin = v; onSave?(settings) }
    func setWaveformPreset(_ p: WaveformPreset) { settings.waveformPreset = p; onSave?(settings) }
    func setDecaySpeed(_ d: DecaySpeed) { settings.decaySpeed = d; onSave?(settings) }
    func setAuthorName(_ n: String) { settings.authorName = n; onSave?(settings) }
}

enum SettingsTab: String, CaseIterable, Identifiable {
    case general = "通用"
    case about = "关于"
    var id: String { rawValue }
    var systemImage: String {
        switch self {
        case .general: return "gearshape"
        case .about: return "info.circle"
        }
    }
}

// MARK: - Settings View

/// macOS 原生偏好设置窗口：顶部 Tab（通用/关于），下方切换内容。
struct SettingsView: View {
    @ObservedObject var model: SettingsViewModel

    var body: some View {
        VStack(spacing: 0) {
            // 顶部 Tab 栏
            tabBar

            Divider()

            // 内容区
            Group {
                switch model.selectedTab {
                case .general:
                    GeneralTab(model: model)
                case .about:
                    AboutTab()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 480, height: 360)
    }

    private var tabBar: some View {
        Picker("", selection: $model.selectedTab) {
            ForEach(SettingsTab.allCases) { tab in
                Label(tab.rawValue, systemImage: tab.systemImage).tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

// MARK: - General Tab

private struct GeneralTab: View {
    @ObservedObject var model: SettingsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // 开机自启
            Toggle("开机自启", isOn: binding(\.launchAtLogin) { model.setLaunchAtLogin($0) })

            // 波形形态
            VStack(alignment: .leading, spacing: 6) {
                Text("波形形态").foregroundStyle(.primary)
                Picker("", selection: binding(\.waveformPreset) { model.setWaveformPreset($0) }) {
                    Text("紧凑").tag(WaveformPreset.compact)
                    Text("舒展").tag(WaveformPreset.spread)
                    Text("跳动").tag(WaveformPreset.bouncy)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            // 衰减速度
            VStack(alignment: .leading, spacing: 6) {
                Text("衰减速度").foregroundStyle(.primary)
                Picker("", selection: binding(\.decaySpeed) { model.setDecaySpeed($0) }) {
                    Text("快").tag(DecaySpeed.fast)
                    Text("中").tag(DecaySpeed.medium)
                    Text("慢").tag(DecaySpeed.slow)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            // 项目作者
            VStack(alignment: .leading, spacing: 6) {
                Text("项目作者").foregroundStyle(.primary)
                TextField("输入作者名", text: binding(\.authorName) { model.setAuthorName($0) })
                    .textFieldStyle(.roundedBorder)
            }

            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
    }

    private func binding<T>(_ keyPath: WritableKeyPath<SettingsState, T>,
                            onSet: @escaping (T) -> Void) -> Binding<T> {
        Binding(get: { model.settings[keyPath: keyPath] }, set: { onSet($0) })
    }
}

// MARK: - About Tab

private struct AboutTab: View {
    var body: some View {
        VStack(spacing: 14) {
            Spacer()

            // 应用图标（SF Symbol）
            Image(systemName: "waveform")
                .font(.system(size: 64, weight: .light))
                .foregroundStyle(.tint)
                .padding(20)
                .background(
                    RoundedRectangle(cornerRadius: 20)
                        .fill(.regularMaterial)
                )

            // 应用名
            Text("ScreenAudio")
                .font(.system(size: 20, weight: .semibold))

            // 版本号
            Text("版本 0.1")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            Spacer()

            // 底部链接
            HStack(spacing: 24) {
                Link(destination: URL(string: "https://github.com/Harukite/screen-audio")!) {
                    Label("GitHub 仓库", systemImage: "globe")
                }
                Divider().frame(height: 14)
                Link(destination: URL(string: "https://github.com/Harukite/screen-audio/issues/new")!) {
                    Label("问题反馈", systemImage: "envelope")
                }
            }
            .font(.system(size: 12))
            .padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity)
    }
}
