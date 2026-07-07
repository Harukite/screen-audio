# Monitor Volume Control — MVP Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 一个常驻菜单栏 App，让 Mac mini（M1, HDMI 接 DELL S2725QS）能用菜单栏垂直滑块控制显示器音量——通过 BlackHole 虚拟声卡中转、对 PCM 做软件衰减后送 HDMI。

**Architecture:** 系统默认输出设为 BlackHole 2ch → 中转进程从 BlackHole 读 PCM → 经感知曲线 + ramp 平滑衰减 → 写到 DELL HDMI。菜单栏滑块控制衰减系数。退出时还原原默认输出。

**Tech Stack:** Swift 6.2 / SwiftPM / Core Audio（C API）/ SwiftUI / `Synchronization.Atomic`（Swift 6 无锁）。部署目标 macOS 15。

**Spec:** `docs/superpowers/specs/2026-07-06-monitor-volume-design.md`

**测试策略：** 算法层（Task 1–6）严格 TDD（先红后绿）。Core Audio / UI 层（Task 7–12）难单测，用依赖注入隔离可测部分 + 手动集成验证。验证三闸：`swift build` / `swift test` / `swift run` 实测。

---

## Task 0：项目脚手架

**Files:**
- Create: `Package.swift`
- Create: `Sources/ScreenAudioCore/.keep`、`Sources/ScreenAudio/.keep`、`Tests/ScreenAudioTests/.keep`

- [ ] **Step 1：写 `Package.swift`**

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "screen-audio",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "ScreenAudio", targets: ["ScreenAudio"]),
    ],
    targets: [
        .target(name: "ScreenAudioCore", path: "Sources/ScreenAudioCore"),
        .executableTarget(
            name: "ScreenAudio",
            dependencies: ["ScreenAudioCore"],
            path: "Sources/ScreenAudio"
        ),
        .testTarget(
            name: "ScreenAudioTests",
            dependencies: ["ScreenAudioCore"],
            path: "Tests/ScreenAudioTests"
        ),
    ]
)
```

- [ ] **Step 2：建占位文件让目录非空**

各 `.keep` 放一行注释即可，确保 SwiftPM 能解析空目录。

- [ ] **Step 3：验证脚手架**

Run: `cd /Users/xiazhengchun/work/screen-audio && swift build`
Expected: `Build complete!`（空 target 也应成功）

Run: `swift test`
Expected: `Executed 0 tests`（无测试，不报错）

- [ ] **Step 4：Commit**

```bash
git init && git add -A
git commit -m "chore: scaffold SwiftPM project (core/exe/tests)"
```

> 注：若用户暂未决定 git，此步可跳过；后续 commit 同理。后续 commit 命令仍写出供参考。

---

## Task 1：PerceivedVolume（感知曲线，TDD）

**Files:**
- Create: `Sources/ScreenAudioCore/PerceivedVolume.swift`
- Test: `Tests/ScreenAudioTests/PerceivedVolumeTests.swift`

- [ ] **Step 1：写失败测试**

```swift
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
```

- [ ] **Step 2：跑测试，确认失败**

Run: `swift test --filter PerceivedVolumeTests`
Expected: FAIL（`cannot find 'PerceivedVolume' in scope`）

- [ ] **Step 3：写实现**

```swift
import Foundation

/// 0–100 滑块值 ↔ 0.0–1.0 线性 gain 的感知曲线映射。
/// 人耳对音量是对数感知，用 (v/100)^exponent 指数曲线。
public enum PerceivedVolume {
    /// 曲线指数。MVP 固定 2.5；v2 可调。
    public static let exponent: Double = 2.5

    /// 滑块值（0–100，自动 clamp）→ 线性 gain（0.0–1.0）
    public static func toGain(_ value: Int) -> Double {
        let clamped = max(0, min(100, value))
        return pow(Double(clamped) / 100.0, exponent)
    }

    /// 线性 gain（0.0–1.0，自动 clamp）→ 滑块值（0–100）
    public static func toValue(_ gain: Double) -> Int {
        let clamped = max(0.0, min(1.0, gain))
        return Int((pow(clamped, 1.0 / exponent) * 100.0).rounded())
    }
}
```

- [ ] **Step 4：跑测试，确认通过**

Run: `swift test --filter PerceivedVolumeTests`
Expected: PASS（4 个测试全绿）

- [ ] **Step 5：Commit**

```bash
git add Sources/ScreenAudioCore/PerceivedVolume.swift Tests/ScreenAudioTests/PerceivedVolumeTests.swift
git commit -m "feat: add PerceivedVolume perceptual curve mapping"
```

---

## Task 2：GainRamp（gain 平滑，TDD）

**Files:**
- Create: `Sources/ScreenAudioCore/GainRamp.swift`
- Test: `Tests/ScreenAudioTests/GainRampTests.swift`

- [ ] **Step 1：写失败测试**

```swift
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
```

- [ ] **Step 2：跑测试，确认失败**

Run: `swift test --filter GainRampTests`
Expected: FAIL（`cannot find 'GainRamp' in scope`）

- [ ] **Step 3：写实现**

```swift
import Foundation

/// gain 平滑过渡的纯函数集，防止音量跳变爆音。
/// 音频输出回调每帧调用 step()，把 current 向 target 按 50ms 时间常数靠近。
public enum GainRamp {
    /// 计算每帧步进系数。tau = 时间常数（秒），默认 50ms。
    public static func coefficient(sampleRate: Double, framesPerBuffer: Int, tau: Double = 0.05) -> Double {
        let frameDuration = Double(framesPerBuffer) / sampleRate
        return 1.0 - exp(-frameDuration / tau)
    }

    /// 单步 lerp。返回新的 current（向 target 靠近）。
    public static func step(current: Double, target: Double, coefficient: Double) -> Double {
        return current + (target - current) * coefficient
    }
}
```

- [ ] **Step 4：跑测试，确认通过**

Run: `swift test --filter GainRampTests`
Expected: PASS（3 个测试全绿）

- [ ] **Step 5：Commit**

```bash
git add Sources/ScreenAudioCore/GainRamp.swift Tests/ScreenAudioTests/GainRampTests.swift
git commit -m "feat: add GainRamp smoothing"
```

---

## Task 3：RingBuffer（SPSC 无锁环形缓冲，TDD）

**Files:**
- Create: `Sources/ScreenAudioCore/RingBuffer.swift`
- Test: `Tests/ScreenAudioTests/RingBufferTests.swift`

- [ ] **Step 1：写失败测试**

```swift
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
```

- [ ] **Step 2：跑测试，确认失败**

Run: `swift test --filter RingBufferTests`
Expected: FAIL（`cannot find 'RingBuffer' in scope`）

- [ ] **Step 3：写实现**

```swift
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
```

- [ ] **Step 4：跑测试，确认通过**

Run: `swift test --filter RingBufferTests`
Expected: PASS（4 个测试全绿）

- [ ] **Step 5：Commit**

```bash
git add Sources/ScreenAudioCore/RingBuffer.swift Tests/ScreenAudioTests/RingBufferTests.swift
git commit -m "feat: add lock-free SPSC RingBuffer"
```

---

## Task 4：VolumeState（不可变状态机，TDD）

**Files:**
- Create: `Sources/ScreenAudioCore/VolumeState.swift`
- Test: `Tests/ScreenAudioTests/VolumeStateTests.swift`

- [ ] **Step 1：写失败测试**

```swift
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
```

- [ ] **Step 2：跑测试，确认失败**

Run: `swift test --filter VolumeStateTests`
Expected: FAIL（`cannot find 'VolumeState' in scope`）

- [ ] **Step 3：写实现**

```swift
import Foundation

/// 音量状态（值类型 + 不可变更新）。UI 线程持有；effectiveGain 由音频线程消费。
public struct VolumeState: Equatable, Codable, Sendable {
    public let value: Int       // 0–100，已 clamp
    public let muted: Bool

    public init(value: Int = 50, muted: Bool = false) {
        self.value = max(0, min(100, value))
        self.muted = muted
    }

    /// 当前实际生效的线性 gain（静音时为 0）。
    public var effectiveGain: Double {
        muted ? 0.0 : PerceivedVolume.toGain(value)
    }

    /// 不可变更新：返回改了 value 的新状态。
    public func settingValue(_ newValue: Int) -> VolumeState {
        VolumeState(value: newValue, muted: self.muted)
    }
    /// 不可变更新：返回改了 muted 的新状态。
    public func settingMuted(_ flag: Bool) -> VolumeState {
        VolumeState(value: self.value, muted: flag)
    }
}
```

- [ ] **Step 4：跑测试，确认通过**

Run: `swift test --filter VolumeStateTests`
Expected: PASS（4 个测试全绿）

- [ ] **Step 5：Commit**

```bash
git add Sources/ScreenAudioCore/VolumeState.swift Tests/ScreenAudioTests/VolumeStateTests.swift
git commit -m "feat: add immutable VolumeState"
```

---

## Task 5：VolumeStore（UserDefaults 持久化，TDD）

**Files:**
- Create: `Sources/ScreenAudioCore/VolumeStore.swift`
- Test: `Tests/ScreenAudioTests/VolumeStoreTests.swift`

- [ ] **Step 1：写失败测试**

```swift
import XCTest
@testable import ScreenAudioCore

final class VolumeStoreTests: XCTestCase {
    func testSaveAndLoad() {
        // 用独立 suite 避免污染全局 UserDefaults
        let defaults = UserDefaults(suiteName: "screenaudio-test")!
        defaults.removePersistentDomain(forName: "screenaudio-test")
        let store = VolumeStore(defaults: defaults)
        XCTAssertNil(store.load())   // 初始无记录
        store.save(VolumeState(value: 73, muted: true))
        let loaded = store.load()
        XCTAssertEqual(loaded?.value, 73)
        XCTAssertEqual(loaded?.muted, true)
    }
}
```

- [ ] **Step 2：跑测试，确认失败**

Run: `swift test --filter VolumeStoreTests`
Expected: FAIL（`cannot find 'VolumeStore' in scope`）

- [ ] **Step 3：写实现**

```swift
import Foundation

/// 音量状态持久化。注入 defaults 便于测试。
public final class VolumeStore {
    private let defaults: UserDefaults
    private let key = "screenaudio.volumeState.v1"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }
    public func save(_ state: VolumeState) {
        if let data = try? JSONEncoder().encode(state) {
            defaults.set(data, forKey: key)
        }
    }
    public func load() -> VolumeState? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(VolumeState.self, from: data)
    }
}
```

- [ ] **Step 4：跑测试，确认通过**

Run: `swift test --filter VolumeStoreTests`
Expected: PASS

- [ ] **Step 5：Commit**

```bash
git add Sources/ScreenAudioCore/VolumeStore.swift Tests/ScreenAudioTests/VolumeStoreTests.swift
git commit -m "feat: add VolumeStore persistence"
```

---

## Task 6：AudioDeviceResolver（设备查找，TDD with 注入）

**Files:**
- Create: `Sources/ScreenAudioCore/AudioDeviceResolver.swift`
- Test: `Tests/ScreenAudioTests/AudioDeviceResolverTests.swift`

- [ ] **Step 1：写失败测试**

```swift
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
```

- [ ] **Step 2：跑测试，确认失败**

Run: `swift test --filter AudioDeviceResolverTests`
Expected: FAIL（`cannot find 'AudioDeviceResolver' in scope`）

- [ ] **Step 3：写实现**

```swift
import CoreAudio
import Foundation

/// 定位 BlackHole 与 HDMI 输出设备。匹配逻辑接受注入的设备列表便于测试；
/// listDevices() / deviceName(:) 走真实 Core Audio。
public enum AudioDeviceResolver {
    public typealias DeviceList = [(id: AudioDeviceID, name: String)]

    /// 名称完全匹配。
    public static func findDevice(named name: String, in devices: DeviceList) -> AudioDeviceID? {
        devices.first { $0.name == name }?.id
    }
    /// BlackHole 2ch 虚拟声卡。
    public static func blackHole(devices: DeviceList) -> AudioDeviceID? {
        findDevice(named: "BlackHole 2ch", in: devices)
    }
    /// DELL 优先；否则回退到名字含 HDMI 的设备。
    public static func hdmiOutput(devices: DeviceList) -> AudioDeviceID? {
        if let dell = findDevice(named: "DELL S2725QS", in: devices) { return dell }
        return devices.first { $0.name.localizedCaseInsensitiveContains("HDMI") }?.id
    }

    /// 真实查询：列出所有音频设备 (id, name)。
    public static func listDevices() -> DeviceList {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr
        else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr
        else { return [] }
        return ids.map { ($0, deviceName($0)) }
    }

    public static func deviceName(_ id: AudioDeviceID) -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name = [CChar](repeating: 0, count: 256)
        var size = UInt32(256)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &name) == noErr else { return "" }
        return String(cString: name)
    }
}
```

- [ ] **Step 4：跑测试，确认通过**

Run: `swift test --filter AudioDeviceResolverTests`
Expected: PASS（4 个测试全绿）

- [ ] **Step 5：Commit**

```bash
git add Sources/ScreenAudioCore/AudioDeviceResolver.swift Tests/ScreenAudioTests/AudioDeviceResolverTests.swift
git commit -m "feat: add AudioDeviceResolver with injectable matching"
```

---

## Task 7：DefaultDeviceGuard（设/还原默认输出）

**Files:**
- Create: `Sources/ScreenAudioCore/DefaultDeviceGuard.swift`

> 难单测（依赖系统音频状态），写实现 + 手动验证。

- [ ] **Step 1：写实现**

```swift
import CoreAudio
import Foundation

/// 启动时把默认输出设为 BlackHole（记下原值），退出时还原。
public final class DefaultDeviceGuard {
    private var original: AudioDeviceID?

    public init() {}

    /// 记录当前默认输出，并切到 device。
    public func captureAndSet(to device: AudioDeviceID) {
        original = Self.currentDefault()
        Self.set(device)
    }
    /// 还原到启动前的默认输出。
    public func restore() {
        if let orig = original { Self.set(orig) }
        original = nil
    }

    public static func currentDefault() -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        _ = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        return id
    }
    private static func set(_ id: AudioDeviceID) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var did = id
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        _ = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, size, &did)
    }
}
```

- [ ] **Step 2：验证编译**

Run: `swift build`
Expected: `Build complete!`

- [ ] **Step 3：Commit**

```bash
git add Sources/ScreenAudioCore/DefaultDeviceGuard.swift
git commit -m "feat: add DefaultDeviceGuard for default output swap"
```

> 手动验证留到 Task 12 端到端时一起做。

---

## Task 8：AudioEngine（Core Audio 中转 — 最复杂）

**Files:**
- Create: `Sources/ScreenAudioCore/AudioEngine.swift`

> ⚠️ **这是全项目最难、最可能需要调试的部分。** Core Audio IOProc 对 API 细节、线程安全、缓冲格式敏感。计划给出基于文档的实现，**预期需要 1–2 轮实测调通**（自动修复模式：最多三轮，触达「需求理解偏差」或「涟漪」即止并报告）。假设：BlackHole 2ch 与 DELL HDMI 均为 **interleaved Float32**（常见情况）；v1 加格式协商。

- [ ] **Step 1：写实现**

```swift
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
    private let outputDevice: AudioDeviceID
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
        self.tempBuffer.initialize(repeating: 0)
    }
    deinit {
        stop()
        tempBuffer.deallocate()
    }

    /// UI 调用：设目标 gain（0.0–1.0）。
    public func setTargetGain(_ gain: Double) {
        targetGain.store(max(0.0, min(1.0, gain)), ordering: .releasing)
    }

    public func start() throws {
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        let inputProc: AudioDeviceIOProc = { _, _, inInputData, _, _, clientData in
            guard let clientData = clientData,
                  let inInputData = inInputData else { return noErr }
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

        let outputProc: AudioDeviceIOProc = { _, _, _, _, outOutputData, clientData in
            guard let clientData = clientData,
                  let outOutputData = outOutputData else { return noErr }
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

    // MARK: - 回调（real-time 线程，禁止阻塞/堆分配）

    private func handleInput(_ ioData: UnsafePointer<AudioBufferList>) {
        let list = ioData.pointee
        for i in 0..<Int(list.mNumberBuffers) {
            let b = list.mBuffers[i]
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

        let list = ioData.pointee
        for i in 0..<Int(list.mNumberBuffers) {
            let b = list.mBuffers[i]
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
}
```

- [ ] **Step 2：验证编译**

Run: `swift build`
Expected: `Build complete!`
> 若报 `withUnsafePointer` 或 IOProc 类型不匹配，修正闭包到 `@convention(c)` 的签名（最常见坑点）。

- [ ] **Step 3：Commit**

```bash
git add Sources/ScreenAudioCore/AudioEngine.swift
git commit -m "feat: add AudioEngine BlackHole→DELL transfer with gain ramp"
```

> 集成验证留到 Task 12。

---

## Task 9：BlackHoleInstaller（检测 + 安装引导）

**Files:**
- Create: `Sources/ScreenAudioCore/BlackHoleInstaller.swift`

- [ ] **Step 1：写实现**

```swift
import Foundation

/// 检测 BlackHole 是否已装；缺失时提供 brew 安装命令。
public enum BlackHoleInstaller {
    public static let cask = "blackhole-2ch"
    public static let deviceName = "BlackHole 2ch"

    /// 是否已安装（按设备名出现在系统设备列表判断）。
    public static var isInstalled: Bool {
        let devices = AudioDeviceResolver.listDevices()
        return devices.contains { $0.name == deviceName }
    }

    /// 返回安装命令字符串（UI 展示用）。
    public static var installCommand: String {
        "brew install --cask \(cask)"
    }
}
```

- [ ] **Step 2：验证编译**

Run: `swift build`
Expected: `Build complete!`

- [ ] **Step 3：Commit**

```bash
git add Sources/ScreenAudioCore/BlackHoleInstaller.swift
git commit -m "feat: add BlackHoleInstaller detection"
```

---

## Task 10：菜单栏 App 骨架（NSStatusItem + 退出还原）

**Files:**
- Delete: `Sources/ScreenAudio/main.swift`
- Create: `Sources/ScreenAudio/ScreenAudioApp.swift`

> ⚠️ **先删 `main.swift`**：Swift 一个 executable target 只能有一个 entry point。脚手架的 `main.swift`（隐式入口）与本 task 的 `@main struct ScreenAudioApp` 冲突，共存会编译报错。先删它再写 App。
> 这一步先建能跑的最小菜单栏 App（图标 + 菜单 + accessory policy），确认 SwiftPM 能跑 GUI。下一步加 popover + 滑块。

- [ ] **Step 1：删除 main.swift，写最小 App**

先删脚手架入口（与下面 `@main` 冲突，不删会编译报错）：

```bash
rm Sources/ScreenAudio/main.swift
```

然后写 App：

```swift
import AppKit
import ScreenAudioCore

@main
struct ScreenAudioApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)   // 无 Dock 图标（不需 Info.plist）
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var engine: AudioEngine?
    private var guard_ = DefaultDeviceGuard()
    private var state = VolumeState()
    private let store = VolumeStore()

    func applicationDidFinishLaunching(_ note: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        rebuildMenu()

        // 若 BlackHole 未装，菜单显示安装指引；否则尝试启动中转。
        if !BlackHoleInstaller.isInstalled {
            state = VolumeState(value: 50)
            rebuildMenu()
            return
        }
        startEngineIfPossible()
    }

    private func startEngineIfPossible() {
        let devices = AudioDeviceResolver.listDevices()
        guard let bh = AudioDeviceResolver.blackHole(devices: devices),
              let dell = AudioDeviceResolver.hdmiOutput(devices: devices) else {
            rebuildMenu()
            return
        }
        do {
            engine = AudioEngine(input: bh, output: dell)
            guard_.captureAndSet(to: bh)
            try engine?.start()
            if let saved = store.load() { state = saved }
            engine?.setTargetGain(state.effectiveGain)
            rebuildMenu()
        } catch {
            statusItem.button?.title = "⚠️"
            print("AudioEngine start failed: \(error)")
        }
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        let title = state.muted ? "🔇 \(state.value)" : "🔊 \(state.value)"
        statusItem.button?.title = title
        menu.addItem(withTitle: "ScreenAudio", action: nil, keyEquivalent: "")
        menu.addItem(.separator())

        let less = NSMenuItem(title: "− 10", action: #selector(dec), keyEquivalent: "")
        less.target = self
        let more = NSMenuItem(title: "+ 10", action: #selector(inc), keyEquivalent: "")
        more.target = self
        let mute = NSMenuItem(title: state.muted ? "取消静音" : "静音", action: #selector(toggleMute), keyEquivalent: "")
        mute.target = self
        menu.addItem(less)
        menu.addItem(more)
        menu.addItem(mute)
        menu.addItem(.separator())

        let quit = NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu
    }

    @objc private func inc() { apply(state.settingValue(state.value + 10)) }
    @objc private func dec() { apply(state.settingValue(state.value - 10)) }
    @objc private func toggleMute() { apply(state.settingMuted(!state.muted)) }

    private func apply(_ next: VolumeState) {
        state = next
        engine?.setTargetGain(next.effectiveGain)
        store.save(next)
        rebuildMenu()
    }

    @objc private func quit() {
        engine?.stop()
        engine = nil
        guard_.restore()
        NSApp.terminate(nil)
    }
}
```

- [ ] **Step 2：验证编译**

Run: `swift build`
Expected: `Build complete!`

- [ ] **Step 3：Commit**

```bash
git add Sources/ScreenAudio/ScreenAudioApp.swift
git commit -m "feat: minimal menu bar app with volume menu + accessory policy"
```

---

## Task 11：菜单栏 App — 垂直滑块 popover（替换菜单）

**Files:**
- Modify: `Sources/ScreenAudio/ScreenAudioApp.swift`
- Create: `Sources/ScreenAudio/Popover/VolumePopoverView.swift`

> 把 Task 10 的 `statusItem.menu`（下拉菜单）换成点击图标弹出的 SwiftUI popover，含垂直滑块（仿系统）、静音、设备显示。

- [ ] **Step 1：写 SwiftUI popover 视图**

```swift
import SwiftUI
import ScreenAudioCore

struct VolumePopoverView: View {
    @ObservedObject var model: VolumeViewModel
    var onQuit: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Text(model.statusIcon)
                .font(.system(size: 28))
            Text("\(model.value)")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(model.muted ? .secondary : .primary)

            // 垂直滑块（仿系统音量 popover）
            Slider(value: Binding(
                get: { Double(model.value) },
                set: { model.setValue(Int($0.rounded())) }
            ), in: 0...100) {
                Text("音量")
            } minimumValueLabel: {
                Image(systemName: "speaker.fill")
            } maximumValueLabel: {
                Image(systemName: "speaker.wave.3.fill")
            }
            .sliderStyle(.vertical)
            .frame(height: 160)
            .disabled(model.muted)

            Divider()
            Button(model.muted ? "取消静音" : "静音") { model.toggleMute() }
            Divider()
            HStack {
                Text(model.deviceSummary).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("退出") { onQuit() }
            }
        }
        .padding(12)
        .frame(width: 220)
    }
}

import Combine

final class VolumeViewModel: ObservableObject {
    @Published var value: Int
    @Published var muted: Bool
    @Published var deviceSummary: String
    var onApply: ((VolumeState) -> Void)?

    init(state: VolumeState, deviceSummary: String) {
        self.value = state.value
        self.muted = state.muted
        self.deviceSummary = deviceSummary
    }
    var statusIcon: String { muted ? "🔇" : "🔊" }
    func setValue(_ v: Int) {
        value = max(0, min(100, v))
        onApply?(VolumeState(value: value, muted: muted))
    }
    func toggleMute() {
        muted.toggle()
        onApply?(VolumeState(value: value, muted: muted))
    }
}
```

- [ ] **Step 2：改 AppDelegate 用 popover 代替 menu**

在 `ScreenAudioApp.swift` 的 `AppDelegate` 里：
- 删除 `rebuildMenu` 与所有 `@objc` 菜单动作
- 点击图标时 toggle popover

```swift
// 替换 statusItem 配置（applicationDidFinishLaunching 内）：
statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
statusItem.button?.title = "🔊 \(state.value)"
statusItem.button?.action = #selector(togglePopover(_:))
statusItem.button?.target = self

// 新增 popover 与 viewModel 字段：
private var popover: NSPopover!
private var viewModel: VolumeViewModel!

// 启动后构造 viewModel：
viewModel = VolumeViewModel(state: state, deviceSummary: deviceSummaryText())
viewModel.onApply = { [weak self] next in self?.apply(next) }

// popover 构造：
popover = NSPopover()
popover.behavior = .transient            // 失焦自动关
popover.contentViewController = NSHostingController(
    rootView: VolumePopoverView(model: viewModel, onQuit: { [weak self] in self?.quit() }))
```

新增方法：
```swift
@objc private func togglePopover(_ sender: Any?) {
    guard let button = statusItem.button else { return }
    if popover.isShown { popover.performClose(nil) }
    else { popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY) }
}

private func deviceSummaryText() -> String {
    let devices = AudioDeviceResolver.listDevices()
    let dell = AudioDeviceResolver.hdmiOutput(devices: devices).map { AudioDeviceResolver.deviceName($0) }
    if !BlackHoleInstaller.isInstalled { return "未装 BlackHole" }
    return dell.map { "● \($0)" } ?? "未找到 HDMI 设备"
}
```

`apply(_:)` 同步更新图标文字：
```swift
private func apply(_ next: VolumeState) {
    state = next
    engine?.setTargetGain(next.effectiveGain)
    store.save(next)
    viewModel.value = next.value
    viewModel.muted = next.muted
    statusItem.button?.title = next.muted ? "🔇 \(next.value)" : "🔊 \(next.value)"
}
```

- [ ] **Step 3：验证编译**

Run: `swift build`
Expected: `Build complete!`
> 若 `sliderStyle(.vertical)` 在当前 SDK 不可用，回退用 `Slider` + `.rotationEffect(.degrees(-90))` 实现垂直效果，或先用水平滑块（标注 v1 改垂直）。

- [ ] **Step 4：Commit**

```bash
git add Sources/ScreenAudio/
git commit -m "feat: SwiftUI popover with vertical volume slider"
```

---

## Task 12：端到端手动验证

> 这是 MVP 的验收闸。**三闸 + 实测全过才算 MVP 完成。**

- [ ] **Step 1：跑测试三闸**

Run: `swift build` → `Build complete!`
Run: `swift test` → 所有测试 PASS

- [ ] **Step 2：装 BlackHole（如未装）**

Run: `brew install --cask blackhole-2ch`
装后在「系统设置 > 声音」应能看到「BlackHole 2ch」输出设备。

- [ ] **Step 3：跑 App**

Run: `swift run`
- 菜单栏出现 🔊 图标 + 数字
- 点击弹出垂直滑块 popover
- **预期**：系统默认输出自动切到 BlackHole；声音仍从 DELL 出来（经中转）

- [ ] **Step 4：验证音量控制**

- 拖滑块从 100 → 0：DELL 响度应明显减小到无声
- 拖回 100：响度恢复
- 点静音：无声；再点恢复
- 拖动时无爆音（ramp 生效）

- [ ] **Step 5：验证退出还原**

- 点「退出」
- **预期**：系统默认输出自动还原为启动前的设备（DELL）
- DELL 物理音量键……仍不可控（预期，因为又回到 HDMI 直出）——这是设计如此

- [ ] **Step 6：验证崩溃还原（可选）**

- `swift run` 启动后，`kill -9` 杀进程
- **预期**：默认输出可能停在 BlackHole（崩溃未还原）→ 手动切回 DELL 即可
- v1 用 launchd KeepAlive 解决自动重启

- [ ] **Step 7：Commit 验证记录**

```bash
git add -A
git commit -m "test: MVP end-to-end verified on DELL S2725QS"
```

---

## 后续（v1 / v2，本计划不展开）

**v1（产品化）— 各自独立小计划：**
- `AudioDeviceWatcher`：监听设备热插拔（`kAudioHardwarePropertyDevices` notification），DELL 断开暂停、回归恢复。
- `LaunchAgentManager`：`~/Library/LaunchAgents/com.xzc.screenaudio.plist`（RunAtLoad + KeepAlive），开机自启 + 崩溃重启。
- RingBuffer overrun 策略 + underrun 统计日志。
- 音频格式协商（非 interleaved / 非 Float32 / 非 48kHz 的设备适配）。
- 垂直滑块打磨（若 Task 11 用了回退方案）。

**v2（多输出智能切换）— 独立 spec/计划：**
- `OutputRouter` + `OutputDevicePicker`：popover 加设备列表；HDMI 走中转、原生设备走直通（用 `kAudioDevicePropertyVolumeScalar` 判断）。

---

## 自动修复条款（写码风格 + 工程总则）

验证三闸（`swift build` / `swift test` / 实测）未过时，自动修复并重跑，至多三轮；三轮未果、出现回环（同一错反复）、或触及公共 API/数据契约/需求理解偏差则止，附完整错误与已试之法待人工裁定。可自动续修者限于：类型/import/语法、既有测试因己改而败、lint/格式违。
