import Foundation

/// 管理 com.xzc.screenaudio.plist 开机自启 LaunchAgent。
/// plist 读写 + launchctl load/unload（Process 模式，参考 BlackHoleInstaller）。
public enum LaunchAgentManager {
    private static let label = "com.xzc.screenaudio"

    /// plist 文件路径：~/Library/LaunchAgents/com.xzc.screenaudio.plist
    public static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    /// plist 文件是否存在（== 开机自启是否"表面"启用。
    /// 注意：若二进制路径无效，launchd 会静默失败。）
    public static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    /// 写入或删除 plist。`executablePath` 仅在 written=true 时需要。
    /// 如果 ~/Library/LaunchAgents 目录不存在则创建。
    public static func setEnabled(_ written: Bool, executablePath: String) throws {
        if written {
            let dir = plistURL.deletingLastPathComponent()
            if !FileManager.default.fileExists(atPath: dir.path) {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            let plist: [String: Any] = [
                "Label": label,
                "ProgramArguments": [executablePath],
                "RunAtLoad": true,
                "KeepAlive": true,
            ]
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: plistURL)
        } else {
            if isEnabled { try FileManager.default.removeItem(at: plistURL) }
        }
    }

    /// launchctl load plist（启用开机自启）。
    public static func load() {
        let task = Process()
        task.launchPath = "/bin/launchctl"
        task.arguments = ["load", plistURL.path]
        try? task.run()
        task.waitUntilExit()
    }

    /// launchctl unload plist（禁用开机自启）。
    public static func unload() {
        let task = Process()
        task.launchPath = "/bin/launchctl"
        task.arguments = ["unload", plistURL.path]
        try? task.run()
        task.waitUntilExit()
    }
}
