import AppKit
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

/// macOS 原生偏好设置窗口：顶部居中的紧凑 Tab，下方切换内容。
struct SettingsView: View {
    @ObservedObject var model: SettingsViewModel

    var body: some View {
        VStack(spacing: 0) {
            tabBar

            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 0.5)

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
        .background(.background)
    }

    /// SwiftUI 的 .segmented Picker 在 macOS 不渲染图标，用自定义分段控件还原。
    /// 高度对齐透明标题栏（28pt），使分段控件与左侧红绿灯同一水平线。
    private var tabBar: some View {
        HStack(spacing: 2) {
            ForEach(SettingsTab.allCases) { tab in
                tabButton(tab)
            }
        }
        .padding(2)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        }
        .frame(maxWidth: .infinity)
        .frame(height: Self.titleBarHeight)
    }

    /// macOS 无工具栏 `.titled` 窗口的标题栏高度。
    private static let titleBarHeight: CGFloat = 28

    private func tabButton(_ tab: SettingsTab) -> some View {
        let isSelected = model.selectedTab == tab
        return Button {
            model.selectedTab = tab
        } label: {
            HStack(spacing: 5) {
                Image(systemName: tab.systemImage)
                    .font(.system(size: 11, weight: .medium))
                Text(tab.rawValue)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
            }
            .foregroundStyle(isSelected ? Color.primary : Color.secondary)
            .frame(width: 78, height: 20)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(.background)
                        .shadow(color: .black.opacity(0.10), radius: 1, y: 0.5)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.snappy(duration: 0.18), value: isSelected)
    }
}

// MARK: - General Tab

private struct GeneralTab: View {
    @ObservedObject var model: SettingsViewModel

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                SettingsCard(header: "启动") {
                    SettingsRow(title: "开机自启", subtitle: "登录后自动在菜单栏运行") {
                        Toggle("", isOn: binding(\.launchAtLogin) { model.setLaunchAtLogin($0) })
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .labelsHidden()
                    }
                }

                SettingsCard(header: "菜单栏波形") {
                    SettingsRow(title: "形态", subtitle: "菜单栏音柱的条数与分布") {
                        Picker("", selection: binding(\.waveformPreset) { model.setWaveformPreset($0) }) {
                            Text("紧凑").tag(WaveformPreset.compact)
                            Text("舒展").tag(WaveformPreset.spread)
                            Text("跳动").tag(WaveformPreset.bouncy)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .controlSize(.small)
                        .frame(width: 168)
                    }

                    SettingsDivider()

                    SettingsRow(title: "衰减", subtitle: "音柱回落的快慢") {
                        Picker("", selection: binding(\.decaySpeed) { model.setDecaySpeed($0) }) {
                            Text("快").tag(DecaySpeed.fast)
                            Text("中").tag(DecaySpeed.medium)
                            Text("慢").tag(DecaySpeed.slow)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .controlSize(.small)
                        .frame(width: 168)
                    }
                }
            }
            .frame(maxWidth: 400)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
        }
        .scrollIndicators(.never)
    }

    private func binding<T>(_ keyPath: WritableKeyPath<SettingsState, T>,
                            onSet: @escaping (T) -> Void) -> Binding<T> {
        Binding(get: { model.settings[keyPath: keyPath] }, set: { onSet($0) })
    }
}

// MARK: - 设置页通用容器

/// 分组卡片：可选小标题 + 圆角描边容器，接近 macOS 新版设置的观感。
private struct SettingsCard<Content: View>: View {
    var header: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let header {
                Text(header)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 2)
            }

            VStack(spacing: 0) {
                content
            }
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.035))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5)
            }
        }
    }
}

private struct SettingsRow<Control: View>: View {
    let title: String
    let subtitle: String?
    @ViewBuilder var control: Control

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12.5))
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)

            control
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }
}

private struct SettingsDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.07))
            .frame(height: 0.5)
            .padding(.leading, 12)
    }
}

// MARK: - About Tab

private struct AboutTab: View {
    private let repoURL = URL(string: "https://github.com/Harukite/screen-audio")!
    private let issuesURL = URL(string: "https://github.com/Harukite/screen-audio/issues/new")!

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            // 直接用打包进 bundle 的真实应用图标，避免关于页与 Finder/Dock 里不一致
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 72, height: 72)

            Text("ScreenAudio")
                .font(.system(size: 17, weight: .semibold))
                .padding(.top, 14)

            Text("版本 0.1")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.top, 2)

            Text("把系统声音接到指定输出设备，菜单栏实时显示电平。")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
                .padding(.top, 10)

            Spacer()

            HStack(spacing: 8) {
                LinkChip(title: "GitHub 仓库", systemImage: "chevron.left.forwardslash.chevron.right", url: repoURL)
                LinkChip(title: "问题反馈", systemImage: "exclamationmark.bubble", url: issuesURL)
            }
            .padding(.bottom, 22)
        }
        .frame(maxWidth: .infinity)
    }
}

/// 关于页底部的小胶囊链接按钮。
private struct LinkChip: View {
    let title: String
    let systemImage: String
    let url: URL

    @Environment(\.openURL) private var openURL
    @State private var isHovered = false

    var body: some View {
        Button {
            openURL(url)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 10, weight: .medium))
                Text(title)
                    .font(.system(size: 11.5))
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background {
                Capsule()
                    .fill(Color.primary.opacity(isHovered ? 0.10 : 0.05))
            }
            .overlay {
                Capsule()
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.snappy(duration: 0.15), value: isHovered)
    }
}
