# 设计文档：Mac 外接显示器（HDMI）音量控制软件

- **日期**：2026-07-06
- **状态**：已批准（设计评审通过），待实现
- **作者**：xiazhengchun + Claude（planner）
- **项目目录**：`/Users/xiazhengchun/work/screen-audio`

---

## 1. 背景与问题

### 现象
Mac mini（Apple M1，macOS 26.3 Tahoe）通过 **HDMI** 连接 **DELL S2725QS** 显示器（内置音响）。声音能正常输出，但 macOS 的键盘音量键无法控制其音量。

### 根因（已用诊断证据确认，非猜测）
1. macOS 不为 HDMI 数字音频（PCM 流）建立「软件音量控制端点」——`ioreg` 查 `IOAudioDevice` 无任何 volume/mute 端点为证。
2. macOS 的音量键不会通过 DDC/CI 协议向显示器下发音量指令。
3. **决定性证据**：用 `m1ddc` 实测，DDC/CI 在 M1 内置 HDMI 口上**走不通**：
   - `m1ddc display 1 get volume` → `110`
   - `m1ddc display 1 max volume` → `-128`（0x80，I2C 读取失败的标准哨兵值）
   - `m1ddc display 1 get luminance` → `110`（与音量同值，物理不可能，为失败固定返回）
   - m1ddc 官方文档明确：Apple Silicon 的 DDC/CI 仅支持 USB-C（DP Alt Mode），**M1 内置 HDMI 口不支持**。

### 结论
DDC/CI 这条路被 M1 内置 HDMI 控制器堵死，且无法绕过（任何软件，包括 MonitorControl / m1ddc / 自写，都受同一硬件限制）。可行方向只有：在 Mac 端对 PCM 流做**数字衰减**后再送 HDMI，由软件充当「音量旋钮」。

> 本文档描述「自己写这个软件」的方案。换 USB-C 线（根治，DDC/CI 可用 + MonitorControl）与装 SoundSource（付费、不换硬件）是备选，不在本 spec 范围内。

---

## 2. 目标与非目标

### 目标
- 菜单栏滑块控制 DELL S2725QS 的实际响度（0–100%）。
- 软件常驻、开机自启、崩溃自动重启。
- 音量变化无爆音、无明显延迟（< 50ms）。
- 核心音频算法单元测试覆盖率 ≥ 80%。

### 非目标（YAGNI）
- ❌ 接管键盘 F11/F12 媒体键（用户明确选择菜单栏滑块）。
- ❌ 多输出设备切换/同时发声（MVP/v1 只针对 DELL 单设备；智能切换为 v2 路线图项，见 §10；同时发声为 v2.2/v3，需重采样）。
- ❌ 重采样（MVP 强制设备采样率对齐；v1 再加）。
- ❌ 不控制显示器亮度/对比度（超出音量范围）。
- ❌ 暂不抽 Swift Package，MVP 用单一 Xcode 项目。

---

## 3. 方案选型

| 方案 | 原理 | 外部依赖 | 成熟度 | 工程量 | 选定 |
|------|------|----------|--------|--------|------|
| **A. BlackHole + 中转进程** | 虚拟声卡做中转站，进程衰减 PCM 后送 HDMI | BlackHole（开源） | 高 | 中 | ✅ |
| B. Core Audio Tap 原生 API | macOS 14.2+ `AudioHardwareCreateTap` 拦截流 | 无 | 低（文档少） | 中-高 | ❌ |
| C. 自写 AudioServerPlugin | HAL 驱动插件伪装设备 | 无 | 中 | 高 | ❌ |

**选 A 的理由**：确定性最高（BlackHole 十年成熟方案）、匹配需求、BlackHole 安全轻量（开源 HAL 插件，`brew install --cask blackhole-2ch` 一行装）。

**A 的两个代价与缓解**：
- 改默认输出为 BlackHole → 进程自动管理，退出时还原原默认设备。
- 进程崩了没声音 → launchd `KeepAlive` 自动重启。

---

## 4. 整体架构

```
[任意 App 播放音频]
        ▼
[系统默认输出 = BlackHole 2ch]（虚拟声卡）
        ▼  PCM (Float32, 48kHz, 2ch)
[★ 中转进程（单一菜单栏 App，LSUIElement）]
   · BlackHole 输入 IOProc → RingBuffer
   · DELL 输出 IOProc ← RingBuffer → × GainRamp(目标系数)
        ▼
[DELL S2725QS 扬声器]（物理音量固定 100%）

[菜单栏 NSStatusItem + SwiftUI popover]
   滑块 0–100 ─┐
   静音按钮   ├─→ VolumeController（不可变状态）→ 目标 gain
   设备显示   ─┘
```

**音量系数用感知曲线**（人耳对数感知）：`gain = (v/100)^2.5`，v 为 0–100 滑块值。MVP 固定指数 2.5，v2 可选可调。

---

## 5. 进程形态与技术栈

- **形态**：单一菜单栏 App（`LSUIElement = YES`，无 Dock 图标），一个进程同时承担 UI 与音频中转。不拆独立守护进程（KISS）。
- **崩溃保障**：`~/Library/LaunchAgents/com.xzc.screenaudio.plist`，`RunAtLoad=true` + `KeepAlive=true`。
- **技术栈**：Swift 6.2（Xcode 26.2）、macOS 26.0 SDK 部署目标、Core Audio（C API 直调）、SwiftUI（popover）。
- **工程结构**：单一 Xcode 项目，含 `ScreenAudio`（App target）+ `ScreenAudioTests`（单元测试 target）。核心算法层保持纯函数、无 App 依赖，便于单测。

---

## 6. 组件拆分（高内聚低耦合，每文件 < 400 行）

| 层 | 文件 | 职责 |
|----|------|------|
| **App** | `AppDelegate.swift` | 入口，装配依赖、生命周期 |
| | `StatusItemController.swift` | 菜单栏图标 + popover 生命周期、状态图标（正常/感叹号） |
| **Audio** | `AudioEngine.swift` | 中转引擎：注册/注销 BlackHole 输入 IOProc 与 DELL 输出 IOProc，串联 RingBuffer |
| | `AudioDeviceResolver.swift` | 按名称/Vendor 定位 BlackHole 与 DELL 设备 ID |
| | `AudioDeviceWatcher.swift` | 监听设备增删、默认设备变化（`kAudioHardwarePropertyDevices` 等 notification） |
| | `VolumeController.swift` | 音量状态机（值类型 + 不可变更新）：setVolume / mute / 目标 gain |
| **算法（纯函数）** | `RingBuffer.swift` | lock-free SPSC 环形缓冲（无锁，适配 real-time 音频线程） |
| | `GainRamp.swift` | 每帧从当前 gain 向目标 gain 线性靠近（时间常数 50ms，防爆音） |
| | `PerceivedVolume.swift` | 0–100 ↔ 0.0–1.0 感知曲线映射（`(v/100)^2.5`） |
| **UI** | `VolumeSlider.swift` | SwiftUI 滑块 |
| | `PopoverRoot.swift` | popover 根视图（滑块 + 静音 + 设备信息 + 安装引导） |
| **Support** | `VolumeStore.swift` | 音量/静音持久化（UserDefaults） |
| | `BlackHoleInstaller.swift` | 检测 BlackHole 是否存在；缺失时引导 `brew install --cask blackhole-2ch` |
| | `LaunchAgentManager.swift` | 安装/卸载开机自启 plist |
| | `DefaultDeviceGuard.swift` | 启动时设默认输出=BlackHole（记录原值），退出时还原 |

> 算法层（`RingBuffer` / `GainRamp` / `PerceivedVolume`）刻意纯函数、无 Foundation 之外的依赖——这是 ≥80% 覆盖率的主战场，也满足「不变性」硬规。

### 6.1 UI 设计细节

**菜单栏图标（`NSStatusItem`，常驻，图标 + 音量数字）**：

| 状态 | 图标 | 数字 |
|------|------|------|
| 正常 | `speaker.wave.2.fill` 🔊 | 显示当前音量（如 "45"），小字号紧贴图标 |
| 静音 | `speaker.slash.fill` 🔇 | 数字灰显 |
| 异常 | `exclamationmark.triangle.fill` ⚠️（黄） | 不显示数字 |

**Popover（点击图标弹出，仿 macOS 系统音量风格，垂直滑块，宽 ≈ 220pt）**：

```
┌────────────────────┐
│        🔊          │   ← 顶部大喇叭图标 + 当前数字 "45"
│        45          │
│                    │
│   ▲                │
│   │                │
│   │                │
│   │  ◄ 当前位置     │   ← 垂直滑块（0–100），仿系统音量 popover
│   │                │
│   │                │
│   │                │
│   ▼                │
│                    │
│  ● 中转正常         │   ← BlackHole → DELL 状态
│    DELL S2725QS     │
│  ───────────────── │
│  🔇静音  ✅自启  退出 │   ← 底部按钮行
└────────────────────┘
```

**异常态 Popover**：
- BlackHole 未装：`⚠️ 缺少音频中转组件` + `[一键安装]`（调 `brew install --cask blackhole-2ch`）+ 「安装后自动继续」
- DELL 断开：`⚠️ 未检测到 DELL 显示器，请检查 HDMI 连接，恢复后自动继续`

**交互**：
- 点菜单栏图标 → 弹出/收起 popover
- 拖垂直滑块 → 实时调音量（50ms ramp 防爆音），持久化做 300ms 去抖
- 键盘 `↑/↓` 微调 ±1，`Shift+↑/↓` 跳 ±10
- 静音按钮 → 切换静音，保留原音量值（再按恢复）
- popover 失焦自动关闭

**视觉风格**：跟随系统明暗模式；全部 SwiftUI 原生控件 + SF Symbols，不引入第三方 UI 库。

**v2 可选增强（先不做）**：音量变化动画、均衡器可视化、自定义快捷键、菜单栏数字可隐藏开关。

---

## 7. 数据流

### 7.1 启动
1. `AudioDeviceResolver` 查找 BlackHole 与 DELL。
2. BlackHole 缺失 → `BlackHoleInstaller` 引导安装（菜单栏图标显示感叹号，阻塞中转）。
3. `DefaultDeviceGuard` 记录原默认输出，设为 BlackHole 2ch。
4. `AudioEngine` 注册 BlackHole 输入 IOProc 与 DELL 输出 IOProc，启动 RingBuffer。
5. `VolumeController` 从 `VolumeStore` 读取上次音量，计算目标 gain。
6. `StatusItemController` 显示菜单栏图标。

### 7.2 实时音频（real-time 线程，禁止阻塞/加锁）
- **BlackHole 输入回调**：拿到 PCM（`inInputData`）→ 写入 `RingBuffer`（生产者）。
- **DELL 输出回调**：从 `RingBuffer` 读（消费者）→ 乘 `GainRamp.currentGain`（原子读）→ 写 `outOutputData`。
- RingBuffer 容量 ≈ 100ms 音频（48kHz × 2ch × Float32 × 0.1s ≈ 38 KB）。

### 7.3 音量调节
1. 用户拖滑块 → `VolumeSlider` 调 `VolumeController.setVolume(v)`。
2. `VolumeController` **不可变更新**：构造新状态，目标 gain = `PerceivedVolume.toGain(v)`。
3. 音频线程下一帧起，`GainRamp` 从当前 gain 线性过渡到目标 gain（50ms 时间常数）。
4. `VolumeStore` 异步持久化 v（去抖，避免频繁写）。

### 7.4 退出
1. 停止两个 IOProc。
2. `DefaultDeviceGuard` 还原原默认输出设备。
3. 退出。

---

## 8. 错误处理

| 场景 | 检测 | 处理 |
|------|------|------|
| BlackHole 未安装 | `AudioDeviceResolver` 找不到 | 菜单栏图标感叹号；popover 给一键安装按钮（调用 brew） |
| DELL 拔出 / HDMI 断开 | `AudioDeviceWatcher` 设备移除通知 | 暂停输出 IOProc；监听回归后恢复；图标提示 |
| 采样率不匹配 | 启动时比对 BlackHole 与 DELL 的 nominal sample rate | MVP：强制 BlackHole 对齐到 DELL 的 48kHz；不一致则告警并尝试设置 |
| RingBuffer underrun（输出快于输入） | RingBuffer 读空 | 输出静音帧（零填充），不崩，计数记日志 |
| RingBuffer overrun（输入快于输出） | RingBuffer 满 | 丢弃最旧帧（覆盖写），计数记日志 |
| 进程崩溃 | launchd | `KeepAlive=true` 自动重启 |
| TCC 音频权限（若触发） | 系统弹窗 | 引导用户在「系统设置 > 隐私 > 麦克风/音频」授权（BlackHole 作 HAL 设备通常无需麦克风权限，标为开放问题，需实测） |

---

## 9. 测试策略（目标 ≥ 80%）

### 9.1 纯函数层（单测主战场，全覆盖）
- `PerceivedVolume`：0/50/100 → gain 端点与中点；幂等性；往返一致性（toValue(toGain(v)) ≈ v）。
- `GainRamp`：从 0→1、1→0、目标已达时无抖动；50ms 时间常数下的逐帧步进值。
- `RingBuffer`：读写指针推进、满/空边界、SPSC 并发（生产者消费者线程）、overrun/underrun 计数。

### 9.2 状态机
- `VolumeController`：setVolume → 目标 gain 正确；mute → gain=0 且保留原值；不可变性（旧实例不变）。

### 9.3 设备匹配
- `AudioDeviceResolver`：注入 mock 设备列表，验证按名称匹配 BlackHole、按 Vendor+Transport 匹配 DELL。

### 9.4 难测部分（手动 + 集成）
- Core Audio IOProc 真实回调、SwiftUI popover：手动验证 + 集成测试（装 BlackHole 实跑，拖滑块观察 DELL 响度变化、拔线恢复、崩溃重启）。

---

## 10. 分阶段交付

### MVP（端到端跑通）
- BlackHole 检测 + 安装引导。
- `AudioEngine` 中转（线性衰减即可，暂用 `PerceivedVolume` 也行）。
- 菜单栏滑块 + 设默认输出 + 还原。
- 实测 DELL 响度随滑块变化。

### v1（产品化）
- 感知曲线 + `GainRamp` 防爆音 + 静音 + 音量持久化。
- `AudioDeviceWatcher` 热插拔。
- `LaunchAgentManager` 开机自启 + 崩溃重启。
- underrun/overrun 处理与日志。

### v2：多输出设备智能切换（路线图，不阻塞 MVP）

**核心：智能路由**——并非所有设备都需要中转：

| 设备类型 | macOS 支持软件音量 | 处理 |
|----------|:---:|------|
| HDMI/DP 设备（DELL S2725QS） | ❌ | **中转模式**：BlackHole → 衰减 → 该设备 |
| 内置扬声器 / AirPods / USB 音箱 | ✅ | **直通模式**：切系统默认输出到该设备，停用中转，滑块控系统原生音量 |

判断依据：Core Audio `kAudioDevicePropertyVolumeScalar` 查设备是否暴露音量控制端点（诊断阶段已验证 DELL 为空、内置/AirPods 非空）。

- **UI**：popover 加「输出设备」列表（仿系统「声音」偏好设置），当前设备高亮，点击即切。
- **体验**：无论切到哪个设备，菜单栏滑块始终有效（中转控衰减 / 直通控系统音量）。
- **新增组件**：`OutputRouter.swift`（当前设备 + 模式管理 + 切换逻辑）、`OutputDevicePicker.swift`（UI）；`AudioEngine` 扩展支持动态切换 sink + 启停；`AudioDeviceResolver` 扩展为列出所有输出设备 + 判断每个是否支持软件音量。

**v2 不含**：多设备同时发声（需多 sink 并发 + 重采样，标为 v2.2/v3）。

**其他 v2 小项**：感知曲线指数可调。

---

## 11. 验证套件（写码风格 + 工程总则）

- 编译：`xcodebuild -scheme ScreenAudio -configuration Debug build`
- 单测：`xcodebuild -scheme ScreenAudio -destination 'platform=macOS' test`
- Lint（如配）：`swiftlint`
- 实测清单：见 9.4。
- 自动修复条款（SKILL.md 硬规）：三闸（build/test/lint）未过时，自动修复并重跑至多三轮；三轮未果、回环、或触及公共 API/数据契约则止，报错待人工裁定。

---

## 12. 风险与开放问题

| # | 项 | 状态 | 缓解 |
|---|----|------|------|
| R1 | 新版 macOS（26.3）下 BlackHole 是否需特殊权限 | 开放，需实测 | 实测；必要时引导授权 |
| R2 | BlackHole 与 DELL 采样率/缓冲对齐稳定性 | 开放 | MVP 强制 48kHz 对齐；v1 加重采样 |
| R3 | RingBuffer 延迟与 underrun 权衡 | 设计已定 100ms | 实测调参 |
| R4 | 中转进程崩溃导致短暂无声 | 已缓解 | launchd KeepAlive |
| R5 | 改默认输出对其他音频软件的副作用 | 已缓解 | 退出严格还原；记录原值持久化 |

---

## 13. 不变性约定（写码风格硬规）

- `VolumeController` 状态用 Swift `struct`（值类型），所有变更返回新实例，禁止 `inout` 突变共享状态。
- 音频线程读 gain 用原子（`OSAllocatedUnfairLock` 或 `Atomic`），**绝不加锁阻塞** real-time 线程。
- `RingBuffer` 为值语义封装但内部持有 `UnsafeMutablePointer` 缓冲，SPSC 无锁。
- 纯算法层禁止依赖 UIKit/AppKit/SwiftUI。
