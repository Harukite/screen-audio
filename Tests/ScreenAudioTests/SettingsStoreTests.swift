import XCTest
@testable import ScreenAudioCore

final class SettingsStoreTests: XCTestCase {
    func testSaveAndLoad() {
        let defaults = UserDefaults(suiteName: "screenaudio-settings-test")!
        defaults.removePersistentDomain(forName: "screenaudio-settings-test")
        let store = SettingsStore(defaults: defaults)
        var s = store.load()
        // 初始无记录时应返回 .default
        XCTAssertFalse(s.launchAtLogin)
        XCTAssertEqual(s.waveformPreset, .compact)
        s.launchAtLogin = true
        s.waveformPreset = .bouncy
        s.decaySpeed = .slow
        s.authorName = "TestAuthor"
        store.save(s)
        let loaded = store.load()
        XCTAssertTrue(loaded.launchAtLogin)
        XCTAssertEqual(loaded.waveformPreset, .bouncy)
        XCTAssertEqual(loaded.decaySpeed, .slow)
        XCTAssertEqual(loaded.authorName, "TestAuthor")
    }
}
