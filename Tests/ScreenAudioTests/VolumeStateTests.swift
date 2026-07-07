import XCTest
@testable import ScreenAudioCore

final class VolumeStateTests: XCTestCase {
    func testDefaultAndClamp() {
        let s = VolumeState()
        XCTAssertEqual(s.value, 50)
        XCTAssertFalse(s.muted)
        let clamped = VolumeState(value: 200)
        XCTAssertEqual(clamped.value, 100)
    }
    func testEffectiveGainUsesCurve() {
        let s = VolumeState(value: 100)
        XCTAssertEqual(s.effectiveGain, 1.0, accuracy: 1e-9)
    }
    func testMuteZeroesGainButKeepsValue() {
        let s = VolumeState(value: 80, muted: true)
        XCTAssertEqual(s.effectiveGain, 0.0, accuracy: 1e-9)
        XCTAssertEqual(s.value, 80)
    }
    func testImmutability() {
        let original = VolumeState(value: 30)
        let changed = original.settingValue(70)
        XCTAssertEqual(original.value, 30)            // 原值不变
        XCTAssertEqual(changed.value, 70)
    }
}
