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

    /// 最近一次输入帧的源 RMS 电平（0.0–1.0，已放大归一化）。
    /// 采源（BlackHole 输入）而非衰减后输出——音波反映"系统在播放音频"，
    /// 不受音量/gain 影响（低音量也跳）。输入回调写、UI 状态栏读，故用原子。
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

    /// 当前源电平（0.0–1.0，RMS，已放大归一化）。供状态栏音波读取。
    public func currentLevelValue() -> Float {
        currentLevel.load(ordering: .acquiring)
    }

    public func start() throws {
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

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
        print("[Engine] started: input=\(AudioDeviceResolver.deviceName(inputDevice)), output=\(AudioDeviceResolver.deviceName(outputDevice))")
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
    public func switchOutput(to newOutput: AudioDeviceID) throws {
        if let p = outputProcID {
            AudioDeviceStop(outputDevice, p)
            AudioDeviceDestroyIOProcID(outputDevice, p)
            outputProcID = nil
        }
        outputDevice = newOutput
        currentGain = 0   // 重置 ramp，防爆音

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
        let buffers = Self.buffersPtr(ioData)
        var sumSq: Float = 0
        var total: Int = 0
        for i in 0..<nBuffers {
            let b = buffers[i]
            let frames = Int(b.mDataByteSize) / MemoryLayout<Float>.size
            if let data = b.mData?.assumingMemoryBound(to: Float.self), frames > 0 {
                // 算源电平（BlackHole 输入，不受 gain）——音波反映"系统在播放音频"，
                // 即使音量低/即将静音也能看到活动跳动。
                for j in 0..<frames {
                    sumSq += data[j] * data[j]
                }
                total += frames
                _ = ringBuffer.write(data, count: frames)
            }
        }
        if total > 0 {
            let rms = sqrt(sumSq / Float(total))
            // 源 RMS 通常 0.05–0.3，放大 *4 让正常音频下音波明显跳动；clamp 0–1。
            currentLevel.store(min(1.0, rms * 30.0), ordering: .releasing)
        }
    }

    private func handleOutput(_ ioData: UnsafeMutablePointer<AudioBufferList>) {
        let target = targetGain.load(ordering: .acquiring)
        currentGain = GainRamp.step(current: currentGain, target: target, coefficient: rampCoefficient)
        let g = Float(currentGain)

        let nBuffers = Int(ioData.pointee.mNumberBuffers)
        let buffers = Self.buffersPtr(ioData)
        for i in 0..<nBuffers {
            let b = buffers[i]
            let frames = Int(b.mDataByteSize) / MemoryLayout<Float>.size
            guard let data = b.mData?.assumingMemoryBound(to: Float.self), frames > 0 else { continue }
            let n = Swift.min(frames, tempFrames)
            let read = ringBuffer.read(tempBuffer, count: n)
            for j in 0..<n {
                let s: Float = j < read ? tempBuffer[j] : 0   // underrun 补零
                data[j] = s * g
            }
        }
    }

    /// 取 AudioBufferList 中 mBuffers 数组首元素指针（real-time 安全，无分配）。
    private static func buffersPtr(_ listPtr: UnsafePointer<AudioBufferList>) -> UnsafePointer<AudioBuffer> {
        let offset = MemoryLayout<AudioBufferList>.offset(of: \AudioBufferList.mBuffers)!
        return (UnsafeRawPointer(listPtr) + offset).assumingMemoryBound(to: AudioBuffer.self)
    }
}
