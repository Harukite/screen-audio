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

    // MARK: - 启动目标选择（决定是否需要麦克风权限）

    func testStartupPrefersHDMI() {
        let devices: [Dev] = [(1, "Mac mini扬声器"), (2, "BlackHole 2ch"), (3, "DELL S2725QS")]
        // 即使当前默认是内置扬声器，也应优先 HDMI
        XCTAssertEqual(AudioDeviceResolver.preferredStartupOutput(devices: devices, currentDefault: 1), 3)
    }

    func testStartupFallsBackToCurrentDefaultWhenNoHDMI() {
        let devices: [Dev] = [(1, "Mac mini扬声器"), (2, "BlackHole 2ch"), (4, "AirPods Pro")]
        XCTAssertEqual(AudioDeviceResolver.preferredStartupOutput(devices: devices, currentDefault: 4), 4)
    }

    /// 上次未还原会把默认输出留在 BlackHole；此时不能把中转设备当成目标。
    func testStartupNeverTargetsBlackHole() {
        let devices: [Dev] = [(1, "Mac mini扬声器"), (2, "BlackHole 2ch")]
        XCTAssertEqual(AudioDeviceResolver.preferredStartupOutput(devices: devices, currentDefault: 2), 1)
    }

    /// currentDefault 查询失败返回 0。
    func testStartupHandlesInvalidCurrentDefault() {
        let devices: [Dev] = [(1, "Mac mini扬声器"), (2, "BlackHole 2ch")]
        XCTAssertEqual(AudioDeviceResolver.preferredStartupOutput(devices: devices, currentDefault: 0), 1)
    }

    func testStartupReturnsNilWhenOnlyBlackHole() {
        let devices: [Dev] = [(2, "BlackHole 2ch")]
        XCTAssertNil(AudioDeviceResolver.preferredStartupOutput(devices: devices, currentDefault: 2))
    }

    // MARK: - C 字符串解码（替换已废弃的 String(cString:)）

    /// Core Audio 回填的是定长缓冲区，NUL 之后的填充字节不得进入设备名，
    /// 否则名称完全匹配（"BlackHole 2ch"）会失败。
    private func buffer(_ text: String, capacity: Int = 256) -> [CChar] {
        var buf = [CChar](repeating: 0, count: capacity)
        for (i, byte) in Array(text.utf8).enumerated() {
            buf[i] = CChar(bitPattern: byte)
        }
        return buf
    }

    func testDecodeStopsAtNulTerminator() {
        XCTAssertEqual(AudioDeviceResolver.decodeCString(buffer("BlackHole 2ch")), "BlackHole 2ch")
    }

    func testDecodeHandlesMultibyteUTF8() {
        XCTAssertEqual(AudioDeviceResolver.decodeCString(buffer("Mac mini扬声器")), "Mac mini扬声器")
    }

    func testDecodeEmptyBufferIsEmptyString() {
        XCTAssertEqual(AudioDeviceResolver.decodeCString([CChar](repeating: 0, count: 256)), "")
    }

    /// 缓冲区被填满、没有 NUL 结尾时不应越界，取全部字节。
    func testDecodeWithoutNulTerminatorUsesWholeBuffer() {
        let full = [CChar](repeating: CChar(bitPattern: UInt8(ascii: "A")), count: 8)
        XCTAssertEqual(AudioDeviceResolver.decodeCString(full), "AAAAAAAA")
    }

    /// 非法 UTF-8 按 U+FFFD 修复，与旧的 String(cString:) 行为一致，不得崩溃。
    func testDecodeRepairsInvalidUTF8() {
        var buf = [CChar](repeating: 0, count: 8)
        buf[0] = CChar(bitPattern: UInt8(ascii: "A"))
        buf[1] = CChar(bitPattern: 0xFF)
        XCTAssertEqual(AudioDeviceResolver.decodeCString(buf), "A\u{FFFD}")
    }
}
