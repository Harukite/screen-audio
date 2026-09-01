import XCTest
@testable import ScreenAudioCore

final class LaunchAgentManagerTests: XCTestCase {
    func testIsEnabledAndSetEnabled() throws {
        // 用临时路径隔离
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let plist = tmpDir.appendingPathComponent("com.xzc.screenaudio.plist")
        XCTAssertFalse(FileManager.default.fileExists(atPath: plist.path))

        // 写入
        let plistContent: [String: Any] = [
            "Label": "com.xzc.screenaudio",
            "ProgramArguments": ["/tmp/test"],
            "RunAtLoad": true,
            "KeepAlive": true,
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plistContent, format: .xml, options: 0)
        try data.write(to: plist)
        XCTAssertTrue(FileManager.default.fileExists(atPath: plist.path))

        // 读取验证
        let read = try PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil) as? [String: Any]
        XCTAssertEqual(read?["Label"] as? String, "com.xzc.screenaudio")
        XCTAssertEqual(read?["RunAtLoad"] as? Bool, true)

        // 删除
        try FileManager.default.removeItem(at: plist)
        XCTAssertFalse(FileManager.default.fileExists(atPath: plist.path))
    }
}
