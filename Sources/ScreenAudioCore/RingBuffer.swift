import Foundation
import Synchronization

/// 单生产者单消费者（SPSC）无锁环形缓冲，存 Float32 样本。
/// 生产者 = BlackHole 输入回调；消费者 = DELL 输出回调。
/// 索引单调递增，访问时对 capacity 取模。
public final class RingBuffer: @unchecked Sendable {
    public let capacity: Int
    private let buffer: UnsafeMutablePointer<Float>
    private let writeIndex: Atomic<Int> = Atomic(0)
    private let readIndex: Atomic<Int> = Atomic(0)

    public init(capacitySamples: Int) {
        precondition(capacitySamples > 0)
        self.capacity = capacitySamples
        self.buffer = .allocate(capacity: capacitySamples)
        self.buffer.initialize(repeating: 0, count: capacitySamples)
    }
    deinit { buffer.deallocate() }

    /// 生产者写。返回实际写入数（满则部分写，丢弃多余新样本）。
    public func write(_ src: UnsafePointer<Float>, count: Int) -> Int {
        let w = writeIndex.load(ordering: .relaxed)
        let r = readIndex.load(ordering: .acquiring)
        let free = capacity - (w - r)
        let toWrite = Swift.min(count, free)
        for i in 0..<toWrite {
            buffer[(w + i) % capacity] = src[i]
        }
        writeIndex.store(w + toWrite, ordering: .releasing)
        return toWrite
    }

    /// 消费者读。返回实际读取数（空则返回 0，调用方补零）。
    public func read(_ dst: UnsafeMutablePointer<Float>, count: Int) -> Int {
        let r = readIndex.load(ordering: .relaxed)
        let w = writeIndex.load(ordering: .acquiring)
        let available = w - r
        let toRead = Swift.min(count, available)
        for i in 0..<toRead {
            dst[i] = buffer[(r + i) % capacity]
        }
        readIndex.store(r + toRead, ordering: .releasing)
        return toRead
    }
}
