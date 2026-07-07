import XCTest
@testable import ScreenAudioCore

final class GainRampTests: XCTestCase {
    func testCoefficientPositiveAndLessThanOne() {
        // 48kHz, 512 帧/缓冲, 50ms 时间常数
        let c = GainRamp.coefficient(sampleRate: 48000, framesPerBuffer: 512, tau: 0.05)
        XCTAssertGreaterThan(c, 0)
        XCTAssertLessThan(c, 1)
    }
    func testStepMovesTowardTarget() {
        let c = GainRamp.coefficient(sampleRate: 48000, framesPerBuffer: 512, tau: 0.05)
        let next = GainRamp.step(current: 0.0, target: 1.0, coefficient: c)
        XCTAssertGreaterThan(next, 0.0)
        XCTAssertLessThan(next, 1.0)   // 单步未到目标
    }
    func testStepAtTargetStaysPut() {
        let c = GainRamp.coefficient(sampleRate: 48000, framesPerBuffer: 512, tau: 0.05)
        let next = GainRamp.step(current: 0.5, target: 0.5, coefficient: c)
        XCTAssertEqual(next, 0.5, accuracy: 1e-9)
    }
}
