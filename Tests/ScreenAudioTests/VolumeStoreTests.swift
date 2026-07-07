import XCTest
@testable import ScreenAudioCore

final class VolumeStoreTests: XCTestCase {
    func testSaveAndLoad() {
        // 用独立 suite 避免污染全局 UserDefaults
        let defaults = UserDefaults(suiteName: "screenaudio-test")!
        defaults.removePersistentDomain(forName: "screenaudio-test")
        let store = VolumeStore(defaults: defaults)
        XCTAssertNil(store.load())   // 初始无记录
        store.save(VolumeState(value: 73, muted: true))
        let loaded = store.load()
        XCTAssertEqual(loaded?.value, 73)
        XCTAssertEqual(loaded?.muted, true)
    }
}
