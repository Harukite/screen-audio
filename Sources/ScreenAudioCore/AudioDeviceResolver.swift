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

    /// 启动时选择目标输出设备。
    ///
    /// 优先 HDMI（本应用的存在意义），否则沿用系统当前默认输出；若当前默认是
    /// BlackHole（上次未还原留下的）或查询失败(0)，退回任一非 BlackHole 设备，
    /// 避免把中转用的虚拟设备当成目标。
    public static func preferredStartupOutput(devices: DeviceList,
                                              currentDefault: AudioDeviceID) -> AudioDeviceID? {
        if let hdmi = hdmiOutput(devices: devices) { return hdmi }
        if currentDefault != 0,
           let match = devices.first(where: { $0.id == currentDefault }),
           !match.name.contains("BlackHole") {
            return match.id
        }
        return devices.first(where: { !$0.name.contains("BlackHole") })?.id
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
        var size = UInt32(name.count)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &name) == noErr else { return "" }
        return decodeCString(name)
    }

    /// 把 Core Audio 回填的定长 C 字符串缓冲区解码为 String。
    /// 先截断到第一个 NUL，再按 UTF-8 解码；非法字节以 U+FFFD 修复，
    /// 与已废弃的 `String(cString:)` 行为一致。缓冲区未以 NUL 结尾时取全部字节。
    static func decodeCString(_ buffer: [CChar]) -> String {
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// 设备暴露音量属性的 element；不支持音量控制则为 nil。
    ///
    /// 绝大多数设备（内置扬声器、BlackHole、多数 USB/蓝牙）只在 master(0) 上暴露音量，
    /// 少数按声道暴露在 1/2。旧实现固定只查 element 1，导致内置扬声器这类设备被误判为
    /// 「不支持音量」，被推进需要麦克风权限的中转路径，且直通模式的写入也总是失败。
    static func volumeElement(_ id: AudioDeviceID) -> AudioObjectPropertyElement? {
        for element: AudioObjectPropertyElement in [kAudioObjectPropertyElementMain, 1, 2] {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: element)
            if AudioObjectHasProperty(id, &address) { return element }
        }
        return nil
    }

    /// 设备是否支持软件音量控制（决定中转 vs 直通）。
    /// HDMI 设备（DELL）不支持 → false；内置/AirPods/USB → true。
    public static func deviceSupportsVolume(_ id: AudioDeviceID) -> Bool {
        volumeElement(id) != nil
    }

    /// 设置设备音量（0.0–1.0）。用于直通模式控制系统音量。
    public static func setDeviceVolume(_ id: AudioDeviceID, _ volume: Float) {
        guard let element = volumeElement(id) else {
            print("[Resolver] setDeviceVolume: \(deviceName(id)) 不支持音量控制")
            return
        }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: element)
        var vol = max(0.0, min(1.0, volume))
        let size = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectSetPropertyData(id, &address, 0, nil, size, &vol)
        if status != noErr {
            print("[Resolver] setDeviceVolume(\(deviceName(id))), vol=\(vol) status=\(status)")
        }
    }
}
