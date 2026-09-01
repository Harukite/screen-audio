import AppKit
import AVFoundation
import CoreAudio
import QuartzCore
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
    private var waveformFallHolds: [Int] = [1, 1, 1]
    private var waveformFrame: [Int] = [1, 1, 1]
    private var waveformTick = 0
    private var waveformTailVisible = false
    private var waveformMuted = false
    private var scrollAccumulator = WaveformMeter.ScrollAccumulator()

    private let settingsStore = SettingsStore()
    private var settingsState = SettingsState.default

    /// 中转模式：BlackHole → 设备（gain 控音量）；直通模式：默认输出设备（系统音量控）。
    private enum OutputMode { case transfer, direct }
    private var outputMode: OutputMode = .transfer
    private var currentOutputDevice: AudioDeviceID = 0

    private let panelWidth: CGFloat = PopoverMetrics.width
    private let initialPanelHeight: CGFloat = 300
    private var naturalPanelContentHeight: CGFloat = 300
    private let settingsWindowSize = NSSize(width: 460, height: 360)

    /// 主音量面板
    private lazy var panel: NSPanel = {
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: initialPanelHeight),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered, defer: false)
        p.isMovableByWindowBackground = false
        // 不可用 hidesOnDeactivate：本应用是 .accessory 且面板是 .nonactivatingPanel，
        // NSApp 几乎永远处于非激活态，AppKit 会直接不让面板上屏（isVisible 仍返回 true，
        // 导致 togglePanel 的状态判断也一起失效）。点击外部收起改由全局鼠标监听负责。
        p.hidesOnDeactivate = false
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isReleasedWhenClosed = false
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.delegate = self
        let container = NSView(frame: NSRect(x: 0, y: 0, width: panelWidth, height: initialPanelHeight))
        container.wantsLayer = true
        container.layer?.cornerRadius = PopoverMetrics.cornerRadius
        container.layer?.cornerCurve = .continuous
        container.layer?.masksToBounds = true

        let blur = NSVisualEffectView(frame: container.bounds)
        blur.autoresizingMask = [.width, .height]
        blur.material = .popover
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = PopoverMetrics.cornerRadius
        blur.layer?.cornerCurve = .continuous
        blur.layer?.masksToBounds = true
        container.addSubview(blur)
        p.contentView = container
        return p
    }()

    /// 独立设置面板（点齿轮弹出，独立 NSHostingView，不和音量面板冲突）
    private var settingsPanel: NSPanel?

    /// 面板打开期间的全局鼠标监听，用于点击外部收起。
    private var outsideClickMonitor: Any?

    /// SIGTERM/SIGINT 的处理源。kill 与 Xcode Stop 都要走正常终止流程，
    /// 否则系统默认输出会被留在 BlackHole 上造成全局静音。
    private var signalSources: [DispatchSourceSignal] = []

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
        let iconLayout = WaveformMeter.iconLayout(barCount: waveformFrame.count)
        statusItem = NSStatusBar.system.statusItem(withLength: CGFloat(iconLayout.canvasWidth + 6))
        configureStatusItemButton()
        statusItem.button?.image = Self.pixelWaveformImage(
            levels: waveformFrame,
            tick: 0,
            showTail: false,
            muted: false
        )
        installStatusItemScrollCatcher()

        // — 读取设置 —
        settingsState = settingsStore.load()
        if settingsState.launchAtLogin && !LaunchAgentManager.isEnabled {
            let execPath = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().path
            try? LaunchAgentManager.setEnabled(true, executablePath: execPath)
            LaunchAgentManager.load()
        }

        // — 主 Host（纯 VolumePopoverView，永不重建）—
        guard let container = panel.contentView else { return }
        let host = FirstMouseHostingView(rootView: VolumePopoverView(
            model: viewModel,
            onQuit: { [weak self] in self?.quit() },
            onContentHeightChange: { [weak self] height in self?.resizePanel(to: height) }
        ))
        host.frame = container.bounds
        host.autoresizingMask = [.width, .height]
        host.wantsLayer = true
        host.layer?.backgroundColor = .clear
        container.addSubview(host)

        installTerminationHandlers()

        // — 音波 Timer：.common 以免拖动音量时波形停住 —
        let timer = Timer(timeInterval: 1.0 / 24.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshWaveform() }
        }
        RunLoop.main.add(timer, forMode: .common)
        levelTimer = timer

        // — 启动 —
        if !BlackHoleInstaller.isInstalled {
            state = VolumeState(value: 50)
            refreshVolumeUI()
            return
        }
        startPreferredOutput()
    }

    /// 启动策略：只有当目标输出确实不支持音量控制时才需要 BlackHole 中转，
    /// 也只有那一种情况才请求麦克风权限。支持音量的设备走直通模式，全程不采集音频。
    private func startPreferredOutput() {
        let devices = AudioDeviceResolver.listDevices()
        guard let target = AudioDeviceResolver.preferredStartupOutput(
            devices: devices,
            currentDefault: DefaultDeviceGuard.currentDefault()
        ) else {
            refreshVolumeUI()
            return
        }

        if AudioDeviceResolver.deviceSupportsVolume(target) {
            startDirectMode(on: target)
        } else {
            requestAudioAccessAndStart(target: target)
        }
    }

    /// 直通模式：不启引擎、不改系统路由，只把该设备自身的音量交给面板控制。
    /// 不读取任何输入设备，因此不需要麦克风权限。
    private func startDirectMode(on device: AudioDeviceID) {
        engine?.stop()
        engine = nil
        outputMode = .direct
        currentOutputDevice = device
        if let saved = store.load() { state = saved }
        AudioDeviceResolver.setDeviceVolume(device, Float(state.effectiveGain))
        refreshVolumeUI()
    }

    private func requestAudioAccessAndStart(target: AudioDeviceID) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            startEngineIfPossible(target: target)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                Task { @MainActor in
                    guard let self else { return }
                    if granted {
                        self.startEngineIfPossible(target: target)
                    } else {
                        self.showAudioPermissionMessage()
                    }
                }
            }
        case .denied, .restricted:
            showAudioPermissionMessage()
        @unknown default:
            showAudioPermissionMessage()
        }
    }

    private func showAudioPermissionMessage() {
        viewModel?.isConnected = false
        viewModel?.deviceSummary = "请在系统设置中允许 ScreenAudio 访问麦克风"
        viewModel?.installNeeded = false
    }

    private func startEngineIfPossible(target: AudioDeviceID) {
        let devices = AudioDeviceResolver.listDevices()
        guard let bh = AudioDeviceResolver.blackHole(devices: devices) else {
            refreshVolumeUI()
            return
        }
        let dell = target

        let nextEngine = AudioEngine(input: bh, output: dell)
        do {
            try nextEngine.start()
            // 引擎确认可以启动后再切换默认输出，失败时不会把系统留在 BlackHole。
            guard_.captureAndSet(to: bh)
            engine = nextEngine
            outputMode = .transfer
            currentOutputDevice = dell
            if let saved = store.load() { state = saved }
            nextEngine.setTargetGain(state.effectiveGain)
            refreshVolumeUI()
        } catch {
            nextEngine.stop()
            engine = nil
            guard_.restore()
            currentOutputDevice = 0
            print("AudioEngine start failed: \(error)")
            refreshVolumeUI()
            viewModel?.deviceSummary = "音频启动失败，请检查麦克风权限或输出设备"
        }
    }

    @MainActor
    private func refreshVolumeUI() {
        viewModel.value = state.value
        viewModel.muted = state.muted
        viewModel.deviceSummary = deviceSummaryText()
        viewModel.installNeeded = !BlackHoleInstaller.isInstalled
        viewModel.outputListHeightLimit = nil
        let devices = AudioDeviceResolver.listDevices()
        viewModel.outputDevices = devices
            .filter { !$0.name.contains("BlackHole") }
            .map { OutputDevice(id: $0.id, name: $0.name) }
        viewModel.currentOutputDeviceID = currentOutputDevice
        viewModel.isConnected = currentOutputDevice != 0 && devices.contains { $0.id == currentOutputDevice }
        updateStatusItemAccessibility()
    }

    // MARK: — 独立设置面板 —
    @MainActor
    private func openSettings() {
        print("[DEBUG] openSettings called")
        // 关旧窗口再新建——避免关闭后 makeKeyAndOrderFront 不生效的问题
        settingsPanel?.orderOut(nil)
        settingsPanel = nil

        let settingsVM = SettingsViewModel(settings: settingsState)
        settingsVM.onSave = { [weak self] s in self?.saveSettings(s) }

        let sp = NSPanel(
            contentRect: NSRect(origin: .zero, size: settingsWindowSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        sp.title = "ScreenAudio"
        // 透明标题栏 + 全尺寸内容：Tab 条与左侧红绿灯同处一行，接近现代 macOS 工具栏。
        sp.titlebarAppearsTransparent = true
        sp.titleVisibility = .hidden
        sp.isMovableByWindowBackground = true
        sp.level = .floating
        sp.isReleasedWhenClosed = false
        sp.hidesOnDeactivate = false          // 失焦不隐藏，保持打开
        sp.isFloatingPanel = true
        sp.center()

        let host = NSHostingView(rootView: SettingsView(model: settingsVM))
        host.frame.origin = .zero
        host.frame.size = settingsWindowSize
        host.autoresizingMask = [.width, .height]
        sp.contentView = host

        settingsPanel = sp
        NSApp.activate(ignoringOtherApps: true)
        sp.makeKeyAndOrderFront(nil)
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
        if NSApp.currentEvent?.modifierFlags.contains(.option) == true {
            apply(state.settingMuted(!state.muted))
            refreshWaveform()
            return
        }
        if panel.isVisible { closePanel() }
        else { showPanel() }
    }

    private func configureStatusItemButton() {
        guard let button = statusItem.button else { return }
        button.imageScaling = .scaleNone
        button.imagePosition = .imageOnly
        button.action = #selector(togglePanel(_:))
        button.target = self
        button.toolTip = "滚动调节音量，Option-点击静音"
        button.setAccessibilityLabel("屏幕音频")
        button.setAccessibilityHelp("滚动调节音量，Option 点击静音")
        updateStatusItemAccessibility()
    }

    private func updateStatusItemAccessibility() {
        let valueText = state.muted ? "已静音，\(state.value)%" : "\(state.value)%"
        statusItem.button?.setAccessibilityValue(valueText)
    }

    private func installStatusItemScrollCatcher() {
        guard let button = statusItem.button else { return }
        let catcher = StatusItemScrollCatcher(frame: button.bounds)
        catcher.autoresizingMask = [.width, .height]
        catcher.setAccessibilityElement(false)
        catcher.onScroll = { [weak self] event in
            self?.handleStatusItemScroll(event)
        }
        button.addSubview(catcher)
    }

    private func handleStatusItemScroll(_ event: NSEvent) {
        let fineControl = event.modifierFlags.contains(.shift) || event.modifierFlags.contains(.option)
        let delta = scrollAccumulator.consume(
            scrollingDeltaY: event.scrollingDeltaY,
            isPrecise: event.hasPreciseScrollingDeltas,
            fineControl: fineControl
        )
        guard delta != 0 else { return }
        let nextValue = max(0, min(100, state.value + delta))
        let wasMuted = state.muted
        apply(VolumeState(value: nextValue, muted: false))
        if wasMuted {
            refreshWaveform()
        }
    }

    private func setStatusItemHighlighted(_ highlighted: Bool) {
        DispatchQueue.main.async { [weak self] in
            self?.statusItem.button?.highlight(highlighted)
        }
    }

    private func positionPanel() {
        guard let button = statusItem.button, let win = button.window else { return }
        let buttonRect = win.convertToScreen(button.convert(button.bounds, to: nil))
        let margin: CGFloat = 6
        let panelHeight = panel.frame.height
        var x = buttonRect.midX - panelWidth / 2
        var y = buttonRect.minY - panelHeight - margin

        if let visibleFrame = win.screen?.visibleFrame {
            let maxX = max(visibleFrame.minX + margin, visibleFrame.maxX - panelWidth - margin)
            let maxY = max(visibleFrame.minY + margin, visibleFrame.maxY - panelHeight - margin)
            x = min(max(x, visibleFrame.minX + margin), maxX)
            y = min(max(y, visibleFrame.minY + margin), maxY)
        }

        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func resizePanel(to contentHeight: CGFloat) {
        if viewModel.outputListHeightLimit == nil {
            naturalPanelContentHeight = contentHeight
        }

        let margin: CGFloat = 6
        let screen = statusItem?.button?.window?.screen ?? NSScreen.main
        let maximumHeight = screen.map { $0.visibleFrame.height - margin * 2 } ?? contentHeight

        if contentHeight > maximumHeight,
           viewModel.outputListHeightLimit == nil,
           !viewModel.outputDevices.isEmpty {
            let rowCount = CGFloat(viewModel.outputDevices.count)
            let naturalListHeight = rowCount * PopoverMetrics.rowHeight
                + max(0, rowCount - 1) * PopoverMetrics.rowSpacing
            let overflow = contentHeight - maximumHeight
            viewModel.outputListHeightLimit = max(70, naturalListHeight - overflow)
            setPanelHeight(maximumHeight)
            return
        }

        setPanelHeight(min(contentHeight, maximumHeight))
    }

    private func setPanelHeight(_ height: CGFloat) {
        let targetHeight = ceil(height)
        let currentHeight = panel.contentView?.bounds.height ?? panel.frame.height
        guard targetHeight > 0, abs(currentHeight - targetHeight) >= 1 else { return }

        panel.setContentSize(NSSize(width: panelWidth, height: targetHeight))
        if panel.isVisible {
            positionPanel()
        }
    }

    private func showPanel() {
        viewModel.outputListHeightLimit = nil
        resizePanel(to: naturalPanelContentHeight)
        positionPanel()
        setStatusItemHighlighted(true)
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        startOutsideClickMonitor()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
            panel.animator().alphaValue = 1
        }
    }

    /// 点击本应用以外的任何位置就收起面板。全局监听只收到发往其它应用的事件，
    /// 因此点面板自身与点状态栏图标都不会触发（后者仍由 togglePanel 处理）。
    /// 鼠标事件的全局监听不需要辅助功能授权。
    private func startOutsideClickMonitor() {
        guard outsideClickMonitor == nil else { return }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.panel.isVisible else { return }
                // 不依赖「全局监听收不到本应用事件」这条保证：.nonactivatingPanel 在后台
                // 应用下的事件归属不确定，一旦误触发就会在按下瞬间收起面板，导致无法拖动。
                // 显式排除落在面板和状态栏按钮内的点击。
                let click = NSEvent.mouseLocation
                if self.panel.frame.contains(click) { return }
                if let button = self.statusItem?.button, let window = button.window,
                   window.convertToScreen(button.convert(button.bounds, to: nil)).contains(click) {
                    return
                }
                self.closePanel()
            }
        }
    }

    private func stopOutsideClickMonitor() {
        guard let monitor = outsideClickMonitor else { return }
        NSEvent.removeMonitor(monitor)
        outsideClickMonitor = nil
    }

    private func closePanel() {
        stopOutsideClickMonitor()
        setStatusItemHighlighted(false)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.1
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                self?.panel.orderOut(nil)
                self?.setStatusItemHighlighted(false)
            }
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
                startPreferredOutput()
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
        updateStatusItemAccessibility()
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
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized:
                switchToTransferOutput(device)
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                    Task { @MainActor in
                        guard let self else { return }
                        if granted {
                            self.switchToTransferOutput(device)
                        } else {
                            self.showAudioPermissionMessage()
                        }
                    }
                }
            case .denied, .restricted:
                showAudioPermissionMessage()
            @unknown default:
                showAudioPermissionMessage()
            }
            return
        }
        currentOutputDevice = device
        viewModel?.currentOutputDeviceID = device
        viewModel?.isConnected = true
        viewModel?.deviceSummary = deviceSummaryText()
        apply(state)
    }

    private func switchToTransferOutput(_ device: AudioDeviceID) {
        let devices = AudioDeviceResolver.listDevices()
        guard let bh = AudioDeviceResolver.blackHole(devices: devices) else { return }
        do {
            if let existing = engine {
                try existing.switchOutput(to: device)
            } else {
                let nextEngine = AudioEngine(input: bh, output: device)
                try nextEngine.start()
                engine = nextEngine
            }
            // 新输出已能启动后才切回 BlackHole 中转路由。
            DefaultDeviceGuard.setDefault(bh)
        } catch {
            print("switch output failed: \(error)")
            refreshVolumeUI()
            return
        }
        outputMode = .transfer
        currentOutputDevice = device
        viewModel?.currentOutputDeviceID = device
        viewModel?.isConnected = true
        viewModel?.deviceSummary = deviceSummaryText()
        apply(state)
    }

    private func quit() {
        settingsPanel?.orderOut(nil)
        NSApp.terminate(nil)   // 音频与资源清理统一在 applicationWillTerminate
    }

    /// 让 kill / Xcode Stop 也走 NSApp.terminate，从而触发 applicationWillTerminate。
    /// 默认的 SIGTERM 行为会直接结束进程，跳过所有清理。
    private func installTerminationHandlers() {
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { NSApp.terminate(nil) }
            source.resume()
            signalSources.append(source)
        }
    }

    /// 唯一的清理出口：正常退出、kill、注销、Xcode Stop 都会经过这里。
    /// 关键是把系统默认输出从 BlackHole 切回原设备，否则用户会全局没声音。
    func applicationWillTerminate(_ notification: Notification) {
        stopOutsideClickMonitor()
        levelTimer?.invalidate()
        levelTimer = nil
        engine?.stop()
        engine = nil
        guard_.restore()
    }

    // MARK: — 音波 —
    @MainActor
    private func refreshWaveform() {
        let raw = max(0, engine?.currentLevelValue() ?? 0)
        let preset = settingsState.waveformPreset
        let weights = preset.weights
        let visualRaw = WaveformMeter.displayLevel(fromSourceLevel: raw)
        waveformTick = (waveformTick + 1) % 24
        if waveformFrame.count != preset.barCount {
            waveformFrame = Array(repeating: 1, count: preset.barCount)
            waveformFallHolds = Array(repeating: 1, count: preset.barCount)
        }

        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        var nextFrame = Array(repeating: 1, count: preset.barCount)
        var nextHolds = waveformFallHolds
        var rising = Array(repeating: false, count: preset.barCount)
        if !reduceMotion {
            let interval = settingsState.decaySpeed.fallInterval
            for i in waveformFrame.indices {
                let target = WaveformMeter.columnTarget(
                    displayLevel: visualRaw,
                    weight: weights[i],
                    column: i,
                    tick: waveformTick
                )
                let stepped = WaveformMeter.steppedLevel(
                    current: waveformFrame[i],
                    target: target,
                    framesUntilFall: waveformFallHolds[i],
                    fallInterval: interval
                )
                rising[i] = stepped.level > waveformFrame[i]
                nextFrame[i] = stepped.level
                nextHolds[i] = stepped.framesUntilFall
            }
        }

        let muted = state.muted
        let showTail = !reduceMotion && !muted && raw > 0.01 && nextFrame.contains(where: { $0 > 1 })
        let frameChanged = nextFrame != waveformFrame
        let tailChanged = showTail != waveformTailVisible
        let muteChanged = muted != waveformMuted
        guard frameChanged || showTail || tailChanged || muteChanged else { return }

        waveformFrame = nextFrame
        waveformFallHolds = nextHolds
        waveformTailVisible = showTail
        waveformMuted = muted
        statusItem.button?.image = Self.pixelWaveformImage(
            levels: nextFrame,
            rising: rising,
            tick: waveformTick,
            showTail: showTail,
            muted: muted
        )
        if panel.isVisible {
            statusItem.button?.highlight(true)
        }
    }

    private static func pixelWaveformImage(
        levels: [Int],
        rising: [Bool] = [],
        tick: Int,
        showTail: Bool,
        muted: Bool
    ) -> NSImage {
        let layout = WaveformMeter.iconLayout(barCount: max(1, levels.count))
        let pointSize = NSSize(width: layout.canvasWidth, height: layout.canvasHeight)
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let pixelsWide = max(1, Int((pointSize.width * scale).rounded()))
        let pixelsHigh = max(1, Int((pointSize.height * scale).rounded()))
        let image = NSImage(size: pointSize)

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelsWide,
            pixelsHigh: pixelsHigh,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            image.isTemplate = true
            return image
        }

        rep.size = pointSize
        NSGraphicsContext.saveGraphicsState()
        if let context = NSGraphicsContext(bitmapImageRep: rep) {
            NSGraphicsContext.current = context
            context.shouldAntialias = false
            context.imageInterpolation = .none
            context.cgContext.setShouldAntialias(false)
            context.cgContext.interpolationQuality = .none

            let opacity = muted ? CGFloat(WaveformMeter.mutedIconOpacity) : 1
            NSColor.black.withAlphaComponent(opacity).setFill()
            for rect in WaveformMeter.barRects(levels: levels, layout: layout) {
                NSRect(
                    x: rect.x,
                    y: rect.y,
                    width: rect.width,
                    height: rect.height
                ).fill()
            }

            if showTail {
                for particle in WaveformMeter.bounceParticles(
                    levels: levels,
                    rising: rising,
                    tick: tick,
                    layout: layout
                ) {
                    NSColor.black.withAlphaComponent(CGFloat(particle.alpha)).setFill()
                    NSRect(
                        x: particle.x,
                        y: particle.y,
                        width: particle.size,
                        height: particle.size
                    ).fill()
                }
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        image.addRepresentation(rep)
        image.isTemplate = true
        return image
    }

    // MARK: — Helpers —
    private func deviceSummaryText() -> String {
        let devs = AudioDeviceResolver.listDevices()
        if !BlackHoleInstaller.isInstalled { return "未装 BlackHole" }

        let deviceID = currentOutputDevice != 0
            ? currentOutputDevice
            : AudioDeviceResolver.hdmiOutput(devices: devs)
        if let deviceID {
            let name = AudioDeviceResolver.deviceName(deviceID)
            if !name.isEmpty { return name }
        }
        return "未找到 HDMI 设备"
    }

}

/// 承载弹窗 SwiftUI 内容的 hosting view。
///
/// 面板是 .borderless + .nonactivatingPanel，`canBecomeKey` 默认为 false，应用又是
/// .accessory 后台应用，因此面板永远不是 key window，每次点击都算 "first mouse"。
/// AppKit 默认把 first mouse 只用于激活窗口而不下发给视图，Button 靠 mouseUp 尚能响应，
/// 但 DragGesture 需要完整的 mouseDown→drag→up 序列，mouseDown 被吞掉后音量滑杆就拖不动。
/// 与 StatusItemScrollCatcher 同样显式接受 first mouse。
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// 盖在状态栏按钮上，接收滚轮且把点击交回 NSStatusBarButton。
private final class StatusItemScrollCatcher: NSView {
    var onScroll: ((NSEvent) -> Void)?

    override func scrollWheel(with event: NSEvent) {
        onScroll?(event)
    }

    override func mouseDown(with event: NSEvent) {
        superview?.mouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        superview?.mouseUp(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        superview?.mouseDragged(with: event)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}
