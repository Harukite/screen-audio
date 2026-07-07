import Foundation

/// 检测 BlackHole 是否已装；缺失时提供 brew 安装命令。
public enum BlackHoleInstaller {
    public static let cask = "blackhole-2ch"
    public static let deviceName = "BlackHole 2ch"

    /// 是否已安装（按设备名出现在系统设备列表判断）。
    public static var isInstalled: Bool {
        let devices = AudioDeviceResolver.listDevices()
        return devices.contains { $0.name == deviceName }
    }

    /// 返回安装命令字符串（UI 展示用）。
    public static var installCommand: String {
        "brew install --cask \(cask)"
    }
}
