import CoreAudio
import Foundation

/// 启动时把默认输出设为 BlackHole（记下原值），退出时还原。
public final class DefaultDeviceGuard {
    private var original: AudioDeviceID?

    public init() {}

    /// 记录当前默认输出，并切到 device。
    public func captureAndSet(to device: AudioDeviceID) {
        original = Self.currentDefault()
        Self.set(device)
    }
    /// 还原到启动前的默认输出。
    public func restore() {
        if let orig = original { Self.set(orig) }
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
        _ = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        return id
    }
    private static func set(_ id: AudioDeviceID) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var did = id
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        _ = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, size, &did)
    }
}
