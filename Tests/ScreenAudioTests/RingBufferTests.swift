import XCTest
@testable import ScreenAudioCore

final class RingBufferTests: XCTestCase {
    func testWriteThenRead() {
        let rb = RingBuffer(capacitySamples: 16)
        var src: [Float] = [1, 2, 3, 4]
        let written = src.withUnsafeBufferPointer { rb.write($0.baseAddress!, count: 4) }
        XCTAssertEqual(written, 4)
        var out = [Float](repeating: 0, count: 4)
        let read = out.withUnsafeMutableBufferPointer { rb.read($0.baseAddress!, count: 4) }
        XCTAssertEqual(read, 4)
        XCTAssertEqual(out, [1, 2, 3, 4])
    }
    func testEmptyReadReturnsZero() {
        let rb = RingBuffer(capacitySamples: 16)
        var out = [Float](repeating: 0, count: 4)
        let read = out.withUnsafeMutableBufferPointer { rb.read($0.baseAddress!, count: 4) }
        XCTAssertEqual(read, 0)
    }
    func testWriteBeyondCapacityDrops() {
        let rb = RingBuffer(capacitySamples: 4)
        var src: [Float] = [1, 2, 3, 4, 5, 6]
        let written = src.withUnsafeBufferPointer { rb.write($0.baseAddress!, count: 6) }
        XCTAssertEqual(written, 4)   // 仅写入 capacity 个
    }
    func testWraparound() {
        let rb = RingBuffer(capacitySamples: 4)
        var a: [Float] = [10, 20]
        _ = a.withUnsafeBufferPointer { rb.write($0.baseAddress!, count: 2) }
        var out2 = [Float](repeating: 0, count: 2)
        _ = out2.withUnsafeMutableBufferPointer { rb.read($0.baseAddress!, count: 2) }
        // 再写超过尾端，触发环绕
        var b: [Float] = [30, 40, 50]
        let written = b.withUnsafeBufferPointer { rb.write($0.baseAddress!, count: 3) }
        XCTAssertEqual(written, 3)
        var out3 = [Float](repeating: 0, count: 3)
        let read = out3.withUnsafeMutableBufferPointer { rb.read($0.baseAddress!, count: 3) }
        XCTAssertEqual(read, 3)
        XCTAssertEqual(out3, [30, 40, 50])
    }
}
