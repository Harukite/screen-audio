import XCTest
import CoreAudio
@testable import ScreenAudioCore

final class AudioDeviceResolverTests: XCTestCase {
    // 设备列表用 (id, name) 元组注入，避开真实 Core Audio
    typealias Dev = (id: AudioDeviceID, name: String)

    func testFindBlackHole() {
        let devices: [Dev] = [(1, "Mac mini扬声器"), (2, "BlackHole 2ch"), (3, "DELL S2725QS")]
        XCTAssertEqual(AudioDeviceResolver.blackHole(devices: devices), 2)
    }
    func testFindDellByName() {
        let devices: [Dev] = [(1, "Mac mini扬声器"), (2, "BlackHole 2ch"), (3, "DELL S2725QS")]
        XCTAssertEqual(AudioDeviceResolver.hdmiOutput(devices: devices), 3)
    }
    func testFallbackToHDMIKeyword() {
        let devices: [Dev] = [(1, "Mac mini扬声器"), (2, "BlackHole 2ch"), (5, "HDMI 输出")]
        XCTAssertEqual(AudioDeviceResolver.hdmiOutput(devices: devices), 5)
    }
    func testNotFoundReturnsNil() {
        let devices: [Dev] = [(1, "Mac mini扬声器")]
        XCTAssertNil(AudioDeviceResolver.blackHole(devices: devices))
        XCTAssertNil(AudioDeviceResolver.hdmiOutput(devices: devices))
    }
}
