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
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var engine: AudioEngine?
    private var guard_ = DefaultDeviceGuard()
    private var state = VolumeState()
    private let store = VolumeStore()
    private var popover: NSPopover!
    private var viewModel: VolumeViewModel!

    func applicationDidFinishLaunching(_ note: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "🔊 \(state.value)"
        statusItem.button?.action = #selector(togglePopover(_:))
        statusItem.button?.target = self

        // 若 BlackHole 未装，仅构造 popover 显示安装提示；否则尝试启动中转。
        if !BlackHoleInstaller.isInstalled {
            state = VolumeState(value: 50)
            setUpPopover()
            return
        }
        startEngineIfPossible()
    }

    private func startEngineIfPossible() {
        let devices = AudioDeviceResolver.listDevices()
        guard let bh = AudioDeviceResolver.blackHole(devices: devices),
              let dell = AudioDeviceResolver.hdmiOutput(devices: devices) else {
            setUpPopover()
            return
        }
        do {
            engine = AudioEngine(input: bh, output: dell)
            guard_.captureAndSet(to: bh)
            try engine?.start()
            if let saved = store.load() { state = saved }
            engine?.setTargetGain(state.effectiveGain)
            setUpPopover()
        } catch {
            statusItem.button?.title = "⚠️"
            print("AudioEngine start failed: \(error)")
            // 即使引擎启动失败也要构造 popover，否则点击图标会在 IUO 上崩溃。
            setUpPopover()
        }
    }

    private func setUpPopover() {
        viewModel = VolumeViewModel(state: state, deviceSummary: deviceSummaryText())
        viewModel.onApply = { [weak self] next in self?.apply(next) }

        popover = NSPopover()
        popover.behavior = .transient            // 失焦自动关
        popover.contentViewController = NSHostingController(
            rootView: VolumePopoverView(model: viewModel, onQuit: { [weak self] in self?.quit() }))
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        if popover.isShown { popover.performClose(nil) }
        else { popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY) }
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
