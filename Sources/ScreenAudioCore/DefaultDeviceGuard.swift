import CoreAudio
import Foundation

/// 启动时把默认输出设为 BlackHole（记下原值），退出时还原。
///
/// 防污染：若启动时默认输出已是 BlackHole（上次没还原留下的）或查询失败(0)，
/// 不能把它当 original——否则 restore 会还原成 BlackHole，形成正反馈死锁。
/// 此时改找真正的原设备（优先 HDMI/DELL，排除 BlackHole）。
public final class DefaultDeviceGuard {
    private var original: AudioDeviceID?

    public init() {}

    /// 记录当前默认输出，并切到 device。
    public func captureAndSet(to device: AudioDeviceID) {
        let current = Self.currentDefault()
        if current != 0 && current != device {
            original = current
            print("[Guard] captureAndSet: 当前默认 = \(Self.name(of: current))，目标 = \(Self.name(of: device)) → original 记为 \(Self.name(of: current))")
        } else {
            // 污染（current == device）或失败（0）：找真正的原设备
            let found = Self.findRestorableOutput(excluding: device)
            original = found
            print("[Guard] captureAndSet: 当前默认 = \(Self.name(of: current)) 是 target/无效 → 找到 original = \(found.map { Self.name(of: $0) } ?? "nil")")
        }
        Self.setDefault(device)
    }

    /// 还原到启动前的默认输出。
    public func restore() {
        print("[Guard] restore: original = \(original.map { Self.name(of: $0) } ?? "nil")")
        if let orig = original { Self.setDefault(orig) }
        original = nil
    }

    public static func currentDefault() -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        if status != noErr { print("[Guard] currentDefault 查询失败 status=\(status)") }
        return id
    }

    /// 设默认输出设备（公开，供 AppDelegate 切换音源时调用）。
    public static func setDefault(_ id: AudioDeviceID) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var did = id
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, size, &did)
        print("[Guard] setDefault(\(name(of: id))) status=\(status)")
    }

    /// 找可还原的输出设备（排除 target）：优先 HDMI（DELL），其次任意非 target / 非 BlackHole 设备。
    private static func findRestorableOutput(excluding target: AudioDeviceID) -> AudioDeviceID? {
        let devices = AudioDeviceResolver.listDevices()
        if let hdmi = AudioDeviceResolver.hdmiOutput(devices: devices), hdmi != target {
            return hdmi
        }
        return devices.first(where: { $0.id != target && !$0.name.contains("BlackHole") })?.id
    }

    private static func name(of id: AudioDeviceID) -> String {
        let n = AudioDeviceResolver.deviceName(id)
        return n.isEmpty ? "<id:\(id)>" : n
    }
}
