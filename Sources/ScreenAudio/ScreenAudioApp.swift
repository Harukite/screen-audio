import AppKit
import CoreAudio
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
    private var levelTimer: Timer?

    /// 中转模式：BlackHole → 设备（gain 控音量）；直通模式：默认输出设备（系统音量控）。
    private enum OutputMode { case transfer, direct }
    private var outputMode: OutputMode = .transfer
    private var currentOutputDevice: AudioDeviceID = 0

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
        // 固定宽度：状态栏渲染 3 根音波竖条（28pt 图像 + 留白），40pt 足够。
        statusItem = NSStatusBar.system.statusItem(withLength: 40)
        statusItem.button?.image = Self.waveformImage(level: 0)
        statusItem.button?.image?.isTemplate = true   // 追随深浅色
        statusItem.button?.action = #selector(togglePanel(_:))
        statusItem.button?.target = self
        // 启动电平刷新（30fps）：Timer 回调不在 MainActor，跳主线程刷 image。
        levelTimer = Timer.scheduledTimer(withTimeInterval: 1.0/30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshWaveform() }
        }

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
            outputMode = .transfer
            currentOutputDevice = dell
            if let saved = store.load() { state = saved }
            engine?.setTargetGain(state.effectiveGain)
            setUpPanel()
        } catch {
            // 引擎启动失败：image 保持 level=0（refreshWaveform 读 engine==nil → 0，静止矮条）。
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
        viewModel.outputDevices = availableOutputDevices()
        viewModel.currentOutputDeviceID = currentOutputDevice
        viewModel.onApply = { [weak self] next in self?.apply(next) }
        viewModel.onInstall = { [weak self] in self?.installBlackHole() }
        viewModel.onSwitchOutput = { [weak self] id in self?.switchOutputDevice(to: id) }

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
        // 状态栏视觉由 levelTimer 驱动 image 刷新，不再用 title。
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

    // MARK: - 状态栏音波

    /// 读取 AudioEngine 实时电平，刷新状态栏 image（30fps）。
    @MainActor
    private func refreshWaveform() {
        let level = engine?.currentLevelValue() ?? 0
        statusItem.button?.image = Self.waveformImage(level: level)
    }

    /// 绘制 3 根竖条音波；level 0.0–1.0，电平越高条越高。template 图像追随深浅色。
    /// lockFocus 必须在主线程（用到当前 graphics context），refreshWaveform 已是 @MainActor。
    private static func waveformImage(level: Float) -> NSImage {
        let size = NSSize(width: 28, height: 16)
        let image = NSImage(size: size)
        image.isTemplate = true   // 每个新 image 都要设，否则不追随深浅色
        image.lockFocus()
        // 3 根条，中间最高、右侧次之、左侧最矮，加固定权重让形状像音波。
        let weights: [CGFloat] = [0.55, 1.0, 0.7]
        let barWidth: CGFloat = 4
        let gap: CGFloat = 3
        let totalWidth = CGFloat(weights.count) * barWidth + CGFloat(weights.count - 1) * gap
        let startX = (size.width - totalWidth) / 2
        NSColor.labelColor.setFill()
        for (i, w) in weights.enumerated() {
            let h = max(2.0, CGFloat(level) * w * size.height)
            let x = startX + CGFloat(i) * (barWidth + gap)
            let rect = NSRect(x: x, y: 0, width: barWidth, height: h)
            let path = NSBezierPath(roundedRect: rect, xRadius: 1.5, yRadius: 1.5)
            path.fill()
        }
        image.unlockFocus()
        return image
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

    /// 列出可选输出设备（过滤掉 BlackHole —— 它是中转源，不能作 sink）。
    private func availableOutputDevices() -> [OutputDevice] {
        AudioDeviceResolver.listDevices()
            .filter { !$0.name.contains("BlackHole") }
            .map { OutputDevice(id: $0.id, name: $0.name) }
    }

    private func apply(_ next: VolumeState) {
        state = next
        store.save(next)
        viewModel?.value = next.value
        viewModel?.muted = next.muted
        switch outputMode {
        case .transfer:
            engine?.setTargetGain(next.effectiveGain)
        case .direct:
            // 直通模式：控系统音量（静音时 0）。
            AudioDeviceResolver.setDeviceVolume(currentOutputDevice, Float(next.effectiveGain))
        }
        // 状态栏 image 由 levelTimer 持续刷新，apply 不需手动更新。
    }

    /// 切换输出音源：原生设备（支持软件音量）走直通，HDMI/DP 走中转。
    @MainActor
    func switchOutputDevice(to device: AudioDeviceID) {
        let supportsVol = AudioDeviceResolver.deviceSupportsVolume(device)
        if supportsVol {
            // 直通：停 engine，默认输出切到 device，控系统音量。
            engine?.stop()
            engine = nil
            DefaultDeviceGuard.setDefault(device)
            outputMode = .direct
        } else {
            // 中转：默认输出切 BlackHole，engine sink 换 device。
            let devices = AudioDeviceResolver.listDevices()
            guard let bh = AudioDeviceResolver.blackHole(devices: devices) else { return }
            DefaultDeviceGuard.setDefault(bh)
            do {
                if let existing = engine {
                    try existing.switchOutput(to: device)
                } else {
                    let newEngine = AudioEngine(input: bh, output: device)
                    try newEngine.start()
                    engine = newEngine
                }
            } catch {
                print("switch output failed: \(error)")
            }
            outputMode = .transfer
        }
        currentOutputDevice = device
        viewModel?.currentOutputDeviceID = device
        apply(state)
    }

    private func quit() {
        engine?.stop()
        engine = nil
        guard_.restore()
        NSApp.terminate(nil)
    }
}
