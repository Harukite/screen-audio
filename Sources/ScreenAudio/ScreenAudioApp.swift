import AppKit
import ScreenAudioCore

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

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var engine: AudioEngine?
    private var guard_ = DefaultDeviceGuard()
    private var state = VolumeState()
    private let store = VolumeStore()

    func applicationDidFinishLaunching(_ note: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        rebuildMenu()

        // 若 BlackHole 未装，菜单显示安装指引；否则尝试启动中转。
        if !BlackHoleInstaller.isInstalled {
            state = VolumeState(value: 50)
            rebuildMenu()
            return
        }
        startEngineIfPossible()
    }

    private func startEngineIfPossible() {
        let devices = AudioDeviceResolver.listDevices()
        guard let bh = AudioDeviceResolver.blackHole(devices: devices),
              let dell = AudioDeviceResolver.hdmiOutput(devices: devices) else {
            rebuildMenu()
            return
        }
        do {
            engine = AudioEngine(input: bh, output: dell)
            guard_.captureAndSet(to: bh)
            try engine?.start()
            if let saved = store.load() { state = saved }
            engine?.setTargetGain(state.effectiveGain)
            rebuildMenu()
        } catch {
            statusItem.button?.title = "⚠️"
            print("AudioEngine start failed: \(error)")
        }
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        let title = state.muted ? "🔇 \(state.value)" : "🔊 \(state.value)"
        statusItem.button?.title = title
        menu.addItem(withTitle: "ScreenAudio", action: nil, keyEquivalent: "")

        menu.addItem(.separator())

        let less = NSMenuItem(title: "− 10", action: #selector(dec), keyEquivalent: "")
        less.target = self
        let more = NSMenuItem(title: "+ 10", action: #selector(inc), keyEquivalent: "")
        more.target = self
        let mute = NSMenuItem(title: state.muted ? "取消静音" : "静音", action: #selector(toggleMute), keyEquivalent: "")
        mute.target = self
        menu.addItem(less)
        menu.addItem(more)
        menu.addItem(mute)
        menu.addItem(.separator())

        let quit = NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu
    }

    @objc private func inc() { apply(state.settingValue(state.value + 10)) }
    @objc private func dec() { apply(state.settingValue(state.value - 10)) }
    @objc private func toggleMute() { apply(state.settingMuted(!state.muted)) }

    private func apply(_ next: VolumeState) {
        state = next
        engine?.setTargetGain(next.effectiveGain)
        store.save(next)
        rebuildMenu()
    }

    @objc private func quit() {
        engine?.stop()
        engine = nil
        guard_.restore()
        NSApp.terminate(nil)
    }
}
