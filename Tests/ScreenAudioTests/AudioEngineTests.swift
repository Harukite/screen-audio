import CoreAudio
import XCTest
@testable import ScreenAudioCore

final class AudioEngineTests: XCTestCase {
    func testInvalidDevicesFailWithoutLeavingEngineRunning() {
        let engine = AudioEngine(input: AudioDeviceID(0), output: AudioDeviceID(0))

        XCTAssertThrowsError(try engine.start())
        engine.stop()
    }
}
