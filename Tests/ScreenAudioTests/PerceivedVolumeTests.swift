import XCTest
@testable import ScreenAudioCore

final class PerceivedVolumeTests: XCTestCase {
    func testExtremes() {
        XCTAssertEqual(PerceivedVolume.toGain(0), 0.0, accuracy: 1e-9)
        XCTAssertEqual(PerceivedVolume.toGain(100), 1.0, accuracy: 1e-9)
    }
    func testMidpointBelowHalf() {
        // (50/100)^2.5 ≈ 0.1768，应 < 0.5（曲线在中段偏低）
        let g = PerceivedVolume.toGain(50)
        XCTAssertLessThan(g, 0.5)
        XCTAssertEqual(g, 0.176776, accuracy: 0.001)
    }
    func testClamping() {
        XCTAssertEqual(PerceivedVolume.toGain(-10), 0.0, accuracy: 1e-9)
        XCTAssertEqual(PerceivedVolume.toGain(150), 1.0, accuracy: 1e-9)
    }
    func testRoundTrip() {
        for v in stride(from: 0, through: 100, by: 5) {
            let back = PerceivedVolume.toValue(PerceivedVolume.toGain(v))
            XCTAssertEqual(back, v, accuracy: 1, "value \(v) not round-tripping")
        }
    }
}
