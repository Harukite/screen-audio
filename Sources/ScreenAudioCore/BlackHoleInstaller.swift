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

public enum InstallError: Error, CustomStringConvertible {
    case brewNotFound
    case installFailed(Int32)

    public var description: String {
        switch self {
        case .brewNotFound:
            return "未找到 brew，请先安装 Homebrew"
        case .installFailed(let code):
            return "安装失败（退出码 \(code)）"
        }
    }
}

extension BlackHoleInstaller {
    /// 用 osascript 弹系统密码框，以 admin 权限跑 brew install。
    /// 阻塞直到安装完成（调用方应在后台线程调）。
    public static func install() throws {
        let brewPaths = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
        guard let brew = brewPaths.first(where: {
            FileManager.default.isExecutableFile(atPath: $0)
        }) else {
            throw InstallError.brewNotFound
        }
        let task = Process()
        task.launchPath = "/usr/bin/osascript"
        task.arguments = [
            "-e",
            "do shell script \"'\(brew)' install --cask \(cask)\" with administrator privileges",
        ]
        try task.run()
        task.waitUntilExit()
        if task.terminationStatus != 0 {
            throw InstallError.installFailed(task.terminationStatus)
        }
    }
}
