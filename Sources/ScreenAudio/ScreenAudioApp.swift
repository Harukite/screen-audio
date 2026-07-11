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
    private var waveformHeights: [Float] = [0, 0, 0]

    private let settingsStore = SettingsStore()
    private var settingsState = SettingsState.default

    /// 中转模式：BlackHole → 设备（gain 控音量）；直通模式：默认输出设备（系统音量控）。
    private enum OutputMode { case transfer, direct }
    private var outputMode: OutputMode = .transfer
    private var currentOutputDevice: AudioDeviceID = 0

    private let panelWidth: CGFloat = 240

    /// 主音量面板
    private lazy var panel: NSPanel = {
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: 400),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
            backing: .buffered, defer: false)
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        p.isMovableByWindowBackground = false
        p.hidesOnDeactivate = false
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isReleasedWhenClosed = false
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.delegate = self
        let blur = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: panelWidth, height: 400))
        blur.material = .popover
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 12
        blur.layer?.masksToBounds = true
        p.contentView = blur
        return p
    }()

    /// 独立设置面板（点齿轮弹出，独立 NSHostingView，不和音量面板冲突）
    private var settingsPanel: NSPanel?
    private var settingsVM: SettingsViewModel?

    func applicationDidFinishLaunching(_ note: Notification) {
        // — ViewModel —
        viewModel = VolumeViewModel(
            state: state,
            deviceSummary: deviceSummaryText(),
            installNeeded: !BlackHoleInstaller.isInstalled
        )
        viewModel.onApply = { [weak self] next in self?.apply(next) }
        viewModel.onInstall = { [weak self] in self?.installBlackHole() }
        viewModel.onSwitchOutput = { [weak self] id in self?.switchOutputDevice(to: id) }
        viewModel.onSettings = { [weak self] in self?.openSettings() }

        // — statusItem —
        statusItem = NSStatusBar.system.statusItem(withLength: 40)
        statusItem.button?.image = Self.waveformImage(heights: [0, 0, 0])
        statusItem.button?.image?.isTemplate = true
        statusItem.button?.action = #selector(togglePanel(_:))
        statusItem.button?.target = self

        // — 读取设置 —
        settingsState = settingsStore.load()
        if settingsState.launchAtLogin && !LaunchAgentManager.isEnabled {
            let execPath = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().path
            try? LaunchAgentManager.setEnabled(true, executablePath: execPath)
            LaunchAgentManager.load()
        }

        // — 主 Host（纯 VolumePopoverView，永不重建）—
        guard let blur = panel.contentView as? NSVisualEffectView else { return }
        let host = NSHostingView(rootView: VolumePopoverView(model: viewModel, onQuit: { [weak self] in self?.quit() }))
        host.frame = blur.bounds
        host.autoresizingMask = [.width, .height]
        host.wantsLayer = true
        host.layer?.backgroundColor = .clear
        blur.addSubview(host)

        // — 音波 Timer —
        levelTimer = Timer.scheduledTimer(withTimeInterval: 1.0/30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshWaveform() }
        }

        // — 启动 —
        if !BlackHoleInstaller.isInstalled {
            state = VolumeState(value: 50)
            refreshVolumeUI()
            return
        }
        startEngineIfPossible()
    }

    private func startEngineIfPossible() {
        let devices = AudioDeviceResolver.listDevices()
        guard let bh = AudioDeviceResolver.blackHole(devices: devices),
              let dell = AudioDeviceResolver.hdmiOutput(devices: devices) else {
            refreshVolumeUI()
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
            refreshVolumeUI()
        } catch {
            print("AudioEngine start failed: \(error)")
            refreshVolumeUI()
        }
    }

    @MainActor
    private func refreshVolumeUI() {
        viewModel.value = state.value
        viewModel.muted = state.muted
        viewModel.deviceSummary = deviceSummaryText()
        viewModel.installNeeded = !BlackHoleInstaller.isInstalled
        viewModel.outputDevices = availableOutputDevices()
        viewModel.currentOutputDeviceID = currentOutputDevice
    }

    // MARK: — 独立设置面板 —
    @MainActor
    private func openSettings() {
        print("[DEBUG] openSettings called")
        if let sp = settingsPanel {
            sp.makeKeyAndOrderFront(nil)
            return
        }
        let settingsVM = SettingsViewModel(settings: settingsState)
        settingsVM.onSave = { [weak self] s in self?.saveSettings(s) }
        settingsVM.onBack = { [weak self] in self?.closeSettings() }
        self.settingsVM = settingsVM

        let sp = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 360),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered, defer: false)
        sp.title = "ScreenAudio 设置"
        sp.isReleasedWhenClosed = false
        sp.center()

        let host = NSHostingView(rootView: SettingsView(model: settingsVM))
        host.frame = NSRect(x: 0, y: 0, width: 280, height: 360)
        host.autoresizingMask = [.width, .height]
        sp.contentView = host

        settingsPanel = sp
        sp.orderFrontRegardless()
    }

    @MainActor
    private func closeSettings() {
        settingsPanel?.orderOut(nil)
    }

    private func saveSettings(_ s: SettingsState) {
        settingsState = s
        settingsStore.save(s)
        let execPath = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().path
        do {
            try LaunchAgentManager.setEnabled(s.launchAtLogin, executablePath: execPath)
            // launchctl 仅在本次操作有效时才调用 load/unload
            if s.launchAtLogin && FileManager.default.fileExists(atPath: LaunchAgentManager.plistURL.path) {
                LaunchAgentManager.load()
            } else if !s.launchAtLogin {
                // 已在 LaunchAgentManager.setEnabled(false) 删了 plist
            }
        } catch {
            print("[Settings] LaunchAgent 操作失败: \(error)")
        }
    }

    // MARK: — Panel toggle —
    @objc private func togglePanel(_ sender: Any?) {
        if panel.isVisible { closePanel() }
        else { showPanel() }
    }

    private func positionPanel() {
        guard let button = statusItem.button, let win = button.window else { return }
        let buttonRect = win.convertToScreen(button.convert(button.bounds, to: nil))
        let origin = NSPoint(
            x: buttonRect.midX - panelWidth / 2,
            y: buttonRect.minY - 400 - 6)
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
            Task { @MainActor in self?.panel.orderOut(nil) }
        })
    }

    func windowDidResignKey(_ notification: Notification) {
        if (notification.object as? NSPanel) === panel {
            closePanel()
        }
    }

    // MARK: — 音量控制 / 设备 / 安装 —
    func installBlackHole() {
        viewModel?.deviceSummary = "正在安装 BlackHole…（请在弹出的密码框输入 Mac 密码）"
        viewModel?.installNeeded = false
        DispatchQueue.global(qos: .userInitiated).async {
            let result: Result<Void, Error>
            do { try BlackHoleInstaller.install(); result = .success(()) }
            catch { result = .failure(error) }
            Task { @MainActor in self.handleInstallResult(result) }
        }
    }

    @MainActor
    func handleInstallResult(_ result: Result<Void, Error>) {
        switch result {
        case .success:
            if BlackHoleInstaller.isInstalled {
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

    private func apply(_ next: VolumeState) {
        state = next
        store.save(next)
        viewModel?.value = next.value
        viewModel?.muted = next.muted
        switch outputMode {
        case .transfer: engine?.setTargetGain(next.effectiveGain)
        case .direct: AudioDeviceResolver.setDeviceVolume(currentOutputDevice, Float(next.effectiveGain))
        }
    }

    @MainActor
    func switchOutputDevice(to device: AudioDeviceID) {
        let supportsVol = AudioDeviceResolver.deviceSupportsVolume(device)
        if supportsVol {
            engine?.stop(); engine = nil
            DefaultDeviceGuard.setDefault(device)
            outputMode = .direct
        } else {
            let devices = AudioDeviceResolver.listDevices()
            guard let bh = AudioDeviceResolver.blackHole(devices: devices) else { return }
            DefaultDeviceGuard.setDefault(bh)
            do {
                if let existing = engine { try existing.switchOutput(to: device) }
                else { let e = AudioEngine(input: bh, output: device); try e.start(); engine = e }
            } catch { print("switch output failed: \(error)") }
            outputMode = .transfer
        }
        currentOutputDevice = device
        viewModel?.currentOutputDeviceID = device
        apply(state)
    }

    private func quit() {
        engine?.stop(); engine = nil
        settingsPanel?.orderOut(nil)
        guard_.restore()
        NSApp.terminate(nil)
    }

    // MARK: — 音波 —
    @MainActor
    private func refreshWaveform() {
        let raw = max(0, engine?.currentLevelValue() ?? 0)
        let preset = settingsState.waveformPreset
        let weights = preset.weights
        let d = settingsState.decaySpeed.coefficient
        if waveformHeights.count != preset.barCount {
            waveformHeights = Array(repeating: 0, count: preset.barCount)
        }
        for i in waveformHeights.indices {
            let target = raw * weights[i]
            if target >= waveformHeights[i] { waveformHeights[i] = target }
            else { waveformHeights[i] += (target - waveformHeights[i]) * d }
        }
        statusItem.button?.image = Self.waveformImage(heights: waveformHeights)
    }

    private static func waveformImage(heights: [Float]) -> NSImage {
        let size = NSSize(width: 28, height: 16)
        let image = NSImage(size: size)
        image.isTemplate = true
        image.lockFocus()
        let barWidth: CGFloat = 4, gap: CGFloat = 3
        let totalWidth = CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * gap
        let startX = (size.width - totalWidth) / 2
        NSColor.labelColor.setFill()
        for (i, hf) in heights.enumerated() {
            let h = max(2.0, CGFloat(hf) * size.height)
            let rect = NSRect(x: startX + CGFloat(i) * (barWidth + gap), y: 0, width: barWidth, height: h)
            let path = NSBezierPath(roundedRect: rect, xRadius: 1.5, yRadius: 1.5)
            path.fill()
        }
        image.unlockFocus()
        return image
    }

    // MARK: — Helpers —
    private func deviceSummaryText() -> String {
        let devs = AudioDeviceResolver.listDevices()
        let dell = AudioDeviceResolver.hdmiOutput(devices: devs).map { AudioDeviceResolver.deviceName($0) }
        if !BlackHoleInstaller.isInstalled { return "未装 BlackHole" }
        return dell.map { "● \($0)" } ?? "未找到 HDMI 设备"
    }

    private func availableOutputDevices() -> [OutputDevice] {
        AudioDeviceResolver.listDevices()
            .filter { !$0.name.contains("BlackHole") }
            .map { OutputDevice(id: $0.id, name: $0.name) }
    }
}
