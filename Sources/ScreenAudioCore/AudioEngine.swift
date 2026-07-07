import CoreAudio
import AudioToolbox
import Foundation
import Synchronization

/// 音频中转引擎：BlackHole（输入）→ RingBuffer → 衰减 → DELL（输出）。
public final class AudioEngine: @unchecked Sendable {
    public enum EngineError: Error, CustomStringConvertible {
        case cannotCreateIO(String)
        case cannotStart(String)
        public var description: String {
            switch self {
            case .cannotCreateIO(let s): return "cannot create IOProc: \(s)"
            case .cannotStart(let s): return "cannot start device: \(s)"
            }
        }
    }

    private let inputDevice: AudioDeviceID
    private var outputDevice: AudioDeviceID
    private let ringBuffer: RingBuffer
    private let sampleRate: Double = 48000
    private let channels: UInt32 = 2
    private let framesPerBuffer: Int = 512
    private let rampCoefficient: Double

    private var inputProcID: AudioDeviceIOProcID?
    private var outputProcID: AudioDeviceIOProcID?

    /// UI 线程写 target；音频输出回调读。
    private let targetGain = Atomic<Double>(0.0)
    /// 仅输出回调线程访问（单线程，无需原子）。
    private var currentGain: Double = 0.0

    /// 最近一次输出帧的 RMS 电平（0.0–1.0，已归一化/放大）。
    /// 输出回调写、UI 状态栏读，故用原子。
    private let currentLevel = Atomic<Float>(0.0)

    /// 预分配输出临时缓冲（避免回调内堆分配）。
    private let tempFrames = 4096
    private let tempBuffer: UnsafeMutablePointer<Float>

    public init(input: AudioDeviceID, output: AudioDeviceID) {
        self.inputDevice = input
        self.outputDevice = output
        let cap = Int(sampleRate * 0.1) * Int(channels)   // 100ms
        self.ringBuffer = RingBuffer(capacitySamples: cap)
        self.rampCoefficient = GainRamp.coefficient(
            sampleRate: sampleRate, framesPerBuffer: framesPerBuffer)
        self.tempBuffer = .allocate(capacity: tempFrames)
        self.tempBuffer.initialize(repeating: 0, count: tempFrames)
    }

    deinit {
        stop()
        tempBuffer.deallocate()
    }

    /// UI 调用：设目标 gain（0.0–1.0）。
    public func setTargetGain(_ gain: Double) {
        targetGain.store(max(0.0, min(1.0, gain)), ordering: .releasing)
    }

    /// 当前输出电平（0.0–1.0，RMS，已放大归一化）。供状态栏音波读取。
    public func currentLevelValue() -> Float {
        currentLevel.load(ordering: .acquiring)
    }

    public func start() throws {
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        // AudioDeviceIOProc 是 7 参数：device, now, inputData, inputTime,
        // outputData, outputTime, clientData（见编译器给出的 @convention(c) 签名）。
        let inputProc: AudioDeviceIOProc = { _, _, inInputData, _, _, _, clientData in
            guard let clientData = clientData else { return noErr }
            let engine = Unmanaged<AudioEngine>.fromOpaque(clientData).takeUnretainedValue()
            engine.handleInput(inInputData)
            return noErr
        }
        var inID: AudioDeviceIOProcID?
        var status = AudioDeviceCreateIOProcID(inputDevice, inputProc, selfPtr, &inID)
        guard status == noErr, let inID else {
            throw EngineError.cannotCreateIO("input status=\(status)")
        }
        self.inputProcID = inID

        let outputProc: AudioDeviceIOProc = { _, _, _, _, outOutputData, _, clientData in
            guard let clientData = clientData else { return noErr }
            let engine = Unmanaged<AudioEngine>.fromOpaque(clientData).takeUnretainedValue()
            engine.handleOutput(outOutputData)
            return noErr
        }
        var outID: AudioDeviceIOProcID?
        status = AudioDeviceCreateIOProcID(outputDevice, outputProc, selfPtr, &outID)
        guard status == noErr, let outID else {
            AudioDeviceDestroyIOProcID(inputDevice, inID)
            self.inputProcID = nil
            throw EngineError.cannotCreateIO("output status=\(status)")
        }
        self.outputProcID = outID

        status = AudioDeviceStart(inputDevice, inID)
        guard status == noErr else { throw EngineError.cannotStart("input status=\(status)") }
        status = AudioDeviceStart(outputDevice, outID)
        guard status == noErr else {
            AudioDeviceStop(inputDevice, inID)
            throw EngineError.cannotStart("output status=\(status)")
        }
    }

    public func stop() {
        if let p = inputProcID {
            AudioDeviceStop(inputDevice, p)
            AudioDeviceDestroyIOProcID(inputDevice, p)
            inputProcID = nil
        }
        if let p = outputProcID {
            AudioDeviceStop(outputDevice, p)
            AudioDeviceDestroyIOProcID(outputDevice, p)
            outputProcID = nil
        }
    }

    /// 切换输出 sink（中转模式换 HDMI 设备时用）。停旧 output IOProc → 换设备 → 重建。
    /// output IOProc 闭包须在方法内重新声明（@convention(c) 闭包不能存为实例属性）。
    public func switchOutput(to newOutput: AudioDeviceID) throws {
        // 停旧 output
        if let p = outputProcID {
            AudioDeviceStop(outputDevice, p)
            AudioDeviceDestroyIOProcID(outputDevice, p)
            outputProcID = nil
        }
        outputDevice = newOutput
        currentGain = 0   // 重置 ramp，防爆音

        // 重建 output IOProc（闭包声明复用 start() 的形式）
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let outputProc: AudioDeviceIOProc = { _, _, _, _, outOutputData, _, clientData in
            guard let clientData = clientData else { return noErr }
            let engine = Unmanaged<AudioEngine>.fromOpaque(clientData).takeUnretainedValue()
            engine.handleOutput(outOutputData)
            return noErr
        }
        var outID: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcID(outputDevice, outputProc, selfPtr, &outID)
        guard status == noErr, let outID else {
            throw EngineError.cannotCreateIO("switchOutput status=\(status)")
        }
        self.outputProcID = outID

        let startStatus = AudioDeviceStart(outputDevice, outID)
        guard startStatus == noErr else {
            AudioDeviceDestroyIOProcID(outputDevice, outID)
            self.outputProcID = nil
            throw EngineError.cannotStart("switchOutput status=\(startStatus)")
        }
    }

    // MARK: - 回调（real-time 线程，禁止阻塞/堆分配）

    private func handleInput(_ ioData: UnsafePointer<AudioBufferList>) {
        let nBuffers = Int(ioData.pointee.mNumberBuffers)
        // mBuffers 是 C 中的 trailing array (AudioBuffer mBuffers[1])；Swift 导入为单个
        // AudioBuffer，无法下标。按字段偏移取首元素指针，逐个读取（无堆分配）。
        let buffers = Self.buffersPtr(ioData)
        for i in 0..<nBuffers {
            let b = buffers[i]
            let frames = Int(b.mDataByteSize) / MemoryLayout<Float>.size
            if let data = b.mData?.assumingMemoryBound(to: Float.self), frames > 0 {
                _ = ringBuffer.write(data, count: frames)
            }
        }
    }

    private func handleOutput(_ ioData: UnsafeMutablePointer<AudioBufferList>) {
        let target = targetGain.load(ordering: .acquiring)
        currentGain = GainRamp.step(current: currentGain, target: target, coefficient: rampCoefficient)
        let g = Float(currentGain)

        let nBuffers = Int(ioData.pointee.mNumberBuffers)
        let buffers = Self.buffersPtr(ioData)
        // MVP：取第一个有 frames 的 buffer 算 RMS（多 buffer 时取主通道即可）。
        var didSample = false
        for i in 0..<nBuffers {
            let b = buffers[i]
            let frames = Int(b.mDataByteSize) / MemoryLayout<Float>.size
            guard let data = b.mData?.assumingMemoryBound(to: Float.self), frames > 0 else { continue }
            let n = Swift.min(frames, tempFrames)
            let read = ringBuffer.read(tempBuffer, count: n)
            let shouldSample = !didSample
            var sumSq: Float = 0
            for j in 0..<n {
                let s: Float = j < read ? tempBuffer[j] : 0   // underrun 补零
                let out = s * g
                data[j] = out
                if shouldSample { sumSq += out * out }
            }
            if shouldSample {
                // RMS 通常很小（0.0x），放大 *2.0 并 clamp 到 0–1，让正常音量下音波明显跳动。
                let rms = sqrt(sumSq / Float(n))
                currentLevel.store(min(1.0, rms * 2.0), ordering: .releasing)
                didSample = true
            }
        }
    }

    /// 取 AudioBufferList 中 mBuffers 数组首元素指针（real-time 安全，无分配）。
    private static func buffersPtr(_ listPtr: UnsafePointer<AudioBufferList>) -> UnsafePointer<AudioBuffer> {
        let offset = MemoryLayout<AudioBufferList>.offset(of: \AudioBufferList.mBuffers)!
        return (UnsafeRawPointer(listPtr) + offset).assumingMemoryBound(to: AudioBuffer.self)
    }
}
