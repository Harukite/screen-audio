import AppKit
import ScreenAudioCore
import SwiftUI

@main
struct ScreenAudioApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)   // 无 Dock 图标（不需 Info.plist）
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem!
    private var engine: AudioEngine?
    private var guard_ = DefaultDeviceGuard()
    private var state = VolumeState()
    private let store = VolumeStore()
    private var viewModel: VolumeViewModel!

    private let panelWidth: CGFloat = 240

    /// 无边框 NSPanel：毛玻璃 popover 材质 + 圆角，浮在菜单栏层。
    /// 替代 NSPopover 以紧贴菜单栏下方（无箭头、无默认边框），现代菜单栏 App 风格。
    private lazy var panel: NSPanel = {
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: 400),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
            backing: .buffered, defer: false)
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        p.isMovableByWindowBackground = false
        p.hidesOnDeactivate = false
        p.level = .statusBar                       // 浮在菜单栏层
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isReleasedWhenClosed = false
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.delegate = self                           // windowDidResignKey 失焦关闭
        // 毛玻璃背景（系统 popover 材质）+ 圆角裁剪
        let blur = NSVisualEffectView(
            frame: NSRect(x: 0, y: 0, width: panelWidth, height: 400))
        blur.material = .popover
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 12
        blur.layer?.masksToBounds = true
        p.contentView = blur
        return p
    }()

    func applicationDidFinishLaunching(_ note: Notification) {
        // 固定宽度：title 含音量数字（拖滑块时变化），variableLength 会让 button 宽度
        // 随数字位数变化 → panel 水平锚点漂移。固定 60pt 容下 "🔊 100"。
        statusItem = NSStatusBar.system.statusItem(withLength: 60)
        statusItem.button?.title = "🔊 \(state.value)"
        statusItem.button?.action = #selector(togglePanel(_:))
        statusItem.button?.target = self

        // 若 BlackHole 未装，仅构造 panel 显示安装提示；否则尝试启动中转。
        if !BlackHoleInstaller.isInstalled {
            state = VolumeState(value: 50)
            setUpPanel()
            return
        }
        startEngineIfPossible()
    }

    private func startEngineIfPossible() {
        let devices = AudioDeviceResolver.listDevices()
        guard let bh = AudioDeviceResolver.blackHole(devices: devices),
              let dell = AudioDeviceResolver.hdmiOutput(devices: devices) else {
            setUpPanel()
            return
        }
        do {
            engine = AudioEngine(input: bh, output: dell)
            guard_.captureAndSet(to: bh)
            try engine?.start()
            if let saved = store.load() { state = saved }
            engine?.setTargetGain(state.effectiveGain)
            setUpPanel()
        } catch {
            statusItem.button?.title = "⚠️"
            print("AudioEngine start failed: \(error)")
            // 即使引擎启动失败也要构造 panel，否则点击图标会在 IUO 上崩溃。
            setUpPanel()
        }
    }

    private func setUpPanel() {
        viewModel = VolumeViewModel(
            state: state,
            deviceSummary: deviceSummaryText(),
            installNeeded: !BlackHoleInstaller.isInstalled
        )
        viewModel.onApply = { [weak self] next in self?.apply(next) }
        viewModel.onInstall = { [weak self] in self?.installBlackHole() }

        // 每次重建 hosting view，保证 model 更新生效。
        let host = NSHostingView(
            rootView: VolumePopoverView(model: viewModel, onQuit: { [weak self] in self?.quit() }))
        host.translatesAutoresizingMaskIntoConstraints = false
        host.wantsLayer = true
        // hosting 背景透明，让 blur 显示；圆角交给 blur 层裁剪。
        host.layer?.backgroundColor = .clear

        guard let blur = panel.contentView as? NSVisualEffectView else { return }
        blur.subviews.forEach { $0.removeFromSuperview() }
        blur.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: blur.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: blur.trailingAnchor),
            host.topAnchor.constraint(equalTo: blur.topAnchor),
            host.bottomAnchor.constraint(equalTo: blur.bottomAnchor),
        ])

        statusItem.button?.title = state.muted ? "🔇 \(state.value)" : "🔊 \(state.value)"
    }

    @MainActor
    func installBlackHole() {
        viewModel?.deviceSummary = "正在安装 BlackHole…（请在弹出的密码框输入 Mac 密码）"
        viewModel?.installNeeded = false
        DispatchQueue.global(qos: .userInitiated).async {
            let result: Result<Void, Error>
            do {
                try BlackHoleInstaller.install()
                result = .success(())
            } catch {
                result = .failure(error)
            }
            Task { @MainActor in self.handleInstallResult(result) }
        }
    }

    @MainActor
    func handleInstallResult(_ result: Result<Void, Error>) {
        switch result {
        case .success:
            if BlackHoleInstaller.isInstalled {
                // 装好了，重新启动引擎流程（内部会 setUpPanel 刷新状态）
                viewModel?.deviceSummary = "BlackHole 已安装，启动中…"
                startEngineIfPossible()
            } else {
                viewModel?.deviceSummary = "安装未生效，请检查后重启 App"
                viewModel?.installNeeded = true
            }
        case .failure(let error):
            viewModel?.deviceSummary = "安装失败：\(error)"
            viewModel?.installNeeded = true
        }
    }

    @objc private func togglePanel(_ sender: Any?) {
        if panel.isVisible {
            closePanel()
        } else {
            showPanel()
        }
    }

    /// 水平居中紧贴 statusItem.button 下方。高度依赖 SwiftUI 内容自适应（fittingSize）。
    private func positionPanel() {
        let fitHeight = hostingView()?.fittingSize.height ?? 200
        panel.setContentSize(NSSize(width: panelWidth, height: max(fitHeight, 120)))

        guard let button = statusItem.button, let win = button.window else { return }
        // button.bounds 是 button 自身坐标系（原点 0,0），convertToScreen 期望窗口坐标。
        // 先把 bounds 转到窗口坐标系，再转屏幕，得到按钮在屏幕上的真实位置。
        let buttonRect = win.convertToScreen(button.convert(button.bounds, to: nil))
        let origin = NSPoint(
            x: buttonRect.midX - panelWidth / 2,
            y: buttonRect.minY - fitHeight - 6)   // 紧贴菜单栏下方，留 6pt
        panel.setFrameOrigin(origin)
    }

    private func showPanel() {
        positionPanel()
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 1
        }
    }

    private func closePanel() {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            // completionHandler 是 Sendable；显式跳回 MainActor 操作 NSPanel。
            Task { @MainActor in self?.panel.orderOut(nil) }
        })
    }

    private func hostingView() -> NSHostingView<VolumePopoverView>? {
        (panel.contentView as? NSVisualEffectView)?
            .subviews
            .compactMap { $0 as? NSHostingView<VolumePopoverView> }
            .first
    }

    // MARK: - NSWindowDelegate

    func windowDidResignKey(_ notification: Notification) {
        if (notification.object as? NSPanel) === panel {
            closePanel()
        }
    }

    private func deviceSummaryText() -> String {
        let devices = AudioDeviceResolver.listDevices()
        let dell = AudioDeviceResolver.hdmiOutput(devices: devices).map { AudioDeviceResolver.deviceName($0) }
        if !BlackHoleInstaller.isInstalled { return "未装 BlackHole" }
        return dell.map { "● \($0)" } ?? "未找到 HDMI 设备"
    }

    private func apply(_ next: VolumeState) {
        state = next
        engine?.setTargetGain(next.effectiveGain)
        store.save(next)
        viewModel?.value = next.value
        viewModel?.muted = next.muted
        statusItem.button?.title = next.muted ? "🔇 \(next.value)" : "🔊 \(next.value)"
    }

    private func quit() {
        engine?.stop()
        engine = nil
        guard_.restore()
        NSApp.terminate(nil)
    }
}
