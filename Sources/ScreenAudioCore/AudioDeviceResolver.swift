import CoreAudio
import Foundation

/// 定位 BlackHole 与 HDMI 输出设备。匹配逻辑接受注入的设备列表便于测试；
/// listDevices() / deviceName(:) 走真实 Core Audio。
public enum AudioDeviceResolver {
    public typealias DeviceList = [(id: AudioDeviceID, name: String)]

    /// 名称完全匹配。
    public static func findDevice(named name: String, in devices: DeviceList) -> AudioDeviceID? {
        devices.first { $0.name == name }?.id
    }
    /// BlackHole 2ch 虚拟声卡。
    public static func blackHole(devices: DeviceList) -> AudioDeviceID? {
        findDevice(named: "BlackHole 2ch", in: devices)
    }
    /// DELL 优先；否则回退到名字含 HDMI 的设备。
    public static func hdmiOutput(devices: DeviceList) -> AudioDeviceID? {
        if let dell = findDevice(named: "DELL S2725QS", in: devices) { return dell }
        return devices.first { $0.name.localizedCaseInsensitiveContains("HDMI") }?.id
    }

    /// 真实查询：列出所有音频设备 (id, name)。
    public static func listDevices() -> DeviceList {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let systemObject = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(
            systemObject, &address, 0, nil, &size) == noErr
        else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            systemObject, &address, 0, nil, &size, &ids) == noErr
        else { return [] }
        return ids.map { ($0, deviceName($0)) }
    }

    public static func deviceName(_ id: AudioDeviceID) -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name = [CChar](repeating: 0, count: 256)
        var size = UInt32(256)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &name) == noErr else { return "" }
        return String(cString: name)
    }
}
