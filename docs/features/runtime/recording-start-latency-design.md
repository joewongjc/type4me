# 录音启动延迟优化（按键即录）与蓝牙开始提示音专项开发设计

> 文档类型：专项开发设计 / 运行时优化设计
> 文档状态：设计完成，待实现
> 适用平台：macOS 14+（Apple Silicon & Intel）
> 设计日期：2026-10-21
> 最后校验：2026-10-21
> 实现基线：`0d33f5b4`（main）
> 工作分支：`fix/356-recording-start-audio`
> 上游来源：[joewongjc/type4me#356](https://github.com/joewongjc/type4me/issues/356)、[joewongjc/type4me#355](https://github.com/joewongjc/type4me/issues/355)
> 覆盖范围：第 1–10 节覆盖 #356 的“解法一：麦克风先行”与“解法二：非蓝牙设备预建采集会话”；第 11 节覆盖 #355 的“蓝牙耳机开始提示音等待输出链路稳定”。可选的“内置麦克风常开预录（pre-roll）”不在本文范围，见第 10 节。

---

## 1. 背景

Issue #356 反馈：按下快捷键后立刻开口，第一个字经常丢失（“大家都是好朋友”被识别成“都是好朋友”或“是好朋友”）。

报告者的环境是 v2.10.0 云端版、macOS 15、MacBook Pro 内置麦克风。基于 185 次录音的 `debug.log`：

| 指标 | 中位数 | P90 | 最大 |
|---|---:|---:|---:|
| `requestToReady`（按键 → `audioEngine.start()` 返回） | 0.37 s | > 0.48 s | 0.90 s |
| `engineStart`（`audioEngine.start()` 自身） | 0.23–0.28 s | — | — |

`ASR pipeline live, flushed N buffered chunks` 中的 N 大多为 0，说明 ASR 握手期间的缓冲机制没有问题。丢失的是**麦克风开始采集之前**的那段语音。

本机复核（MacBook Pro 内置麦克风，117 次）：

| 指标 | 中位数 | P90 | 最大 |
|---|---:|---:|---:|
| `requestToReady` | 156 ms | 216 ms | 330 ms |
| `engineStart` | 55 ms | 77 ms | 97 ms |

两台机器的 `engineStart` 相差约 4–5 倍，但 `requestToReady − engineStart`（采集前的准备阶段）在两台机器上都稳定在约 100 ms。

“麦克风保活”对此无效：`AudioInputDevicePreferenceStore.keepAliveInputDevice` 只在设备类别为 `.bluetooth` 时返回设备（`Type4Me/Audio/AudioInputDevicePreference.swift:208`）。

## 2. 现状时序与根因

### 2.1 一次按键录音的串行路径

```text
T0  HotkeyManager → Type4MeApp.requestRecordingStart      recordingRequestedAt = now
    │  appState.startRecording()（UI 进入 preparing）
    │  await session.awaitIdle()                          正常为 0；上次未收尾时按 50 ms 轮询
    │  await MainActor.run { recordingStartGate.allowsStart }
    ▼
    RecognitionSession.startRecording                    RecognitionSession.swift:1019
    │  forceReset()（仅非 idle 时）
    │  await MainActor.run { CorrectionLearningCoordinator.finalizeBeforeNextRecording() }
    │  记录目标 App、解析模式、翻译/IntelliSense 上下文
    │    └─ IntelliSense 模式：await IntelliSenseSettingsStore.load()
    │  resetPromptContextCapture
    │  KeychainService.loadASRConfig(for:)               Keychain + credentials.json
    │  ASRProviderRegistry.createClient
    │  HotwordStorage.loadEffective / ASRBiasSettingsStorage.load
    │  await finishAudioChunkPipeline(timeout: 100 ms)   上一轮 sender 未退出时最多等 100 ms
    ▼
T1  audioEngine.start()                                  RecognitionSession.swift:1306
    │  AVCaptureSession()
    │  AVCaptureDevice.default / (uniqueID:)
    │  AVCaptureDeviceInput(device:)                     打开设备、协商格式
    │  addInput / addOutput / setSampleBufferDelegate
    │  startRunning()                                    同步阻塞
    ▼
T2  start() 返回 → state = .recording → markReadyIfNeeded() → .ready
    │                                    → Type4MeApp 播放提示音（Type4MeApp.swift:259）
T3  第一个 captureOutput 回调到达                          当前没有日志
```

结论：

1. **采集开始得太晚。** T0 → T1 之间的工作都不需要麦克风，却全部排在麦克风前面。
2. **每次都冷启动采集图。** `startWithAVCapture()` 每次新建 session 和 device input（`AudioCaptureEngine.swift:141`），`stop()` 又把 input/output 全部拆掉（`AudioCaptureEngine.swift:187`）。`warmUp()` 只建了一个 `AVAudioEngine`，没有接触 `AVCaptureSession` 链路，对这段延迟无效。
3. **度量不完整。** 日志只记录到 T2，真正决定是否丢字的是 T3（第一帧样本），目前没有记录。

### 2.2 为什么现在要拆图

`stop()` 的注释已经说明原因：对蓝牙耳机，一个已停止但仍持有 `AVCaptureDeviceInput` 的 session 可能让 CoreAudio 保持 HFP 输入路由，耳机停留在通话模式，播放音质下降。这个约束必须继续成立。本设计只在**非蓝牙设备**上放宽它。

## 3. 目标与非目标

### 3.1 目标

- G1：缩短按键到第一帧样本（T0 → T3）的时间，降低“按下就说”时的吞字概率。
- G2：蓝牙输入设备的行为（HFP 路由释放、保活语义）与现在完全一致。
- G3：用户可感知的“开始说话”信号（`.ready` 和提示音）不能比现在更晚。
- G4：补全分段计时，用户贴一份 `debug.log` 就能定位慢在哪一段。

### 3.2 非目标

- 不让麦克风在空闲时处于运行状态（菜单栏橙色指示灯不能常亮）。
- 不改 ASR 连接、缓冲、flush 流程（Phase 2/3 不变）。
- 不新增用户可见设置，没有新增文案。
- 不处理 SenseVoice 本地路径跳过开头 400 ms 的问题（见第 10 节）。

### 3.3 量化目标

| 指标（内置麦克风，空闲状态按键） | 现状（本机） | 目标（本机） | 报告者机器 |
|---|---:|---:|---|
| T0 → 采集开始（`captureStartedAt`） | ≈ 100 ms | ≤ 20 ms | 减少 ≈ 100 ms |
| `engineStart` | 55 ms | ≤ 20 ms（预建命中） | 以 Phase 0 数据为准，预期减半以上 |
| T0 → 第一帧（`requestToFirstSample`） | 未知 | Phase 0 测出基线后定稿 | 同左 |

目标值在 Phase 0 埋点落地、拿到真实分段数据后再确认一次（第 8 节）。

## 4. 解法一：麦克风先行（Capture-First）

### 4.1 思路

把 `audioEngine.start()` 从准备流程的末尾挪到**最前面**：会话状态切到 `.starting`、确认这是一次语音录音（非手动输入）之后立即开始采集，采集到的音频写进已有的 `AudioChunkBuffer`。凭证、client、热词、上下文这些准备工作在麦克风已经运行的情况下完成。

这一步**不追求并行**：`RecognitionSession` 是 actor，`audioEngine.start()` 仍在 actor 上同步执行。收益来自**重排**，采集起点提前了整个准备阶段（约 100 ms），而 `.ready` 的时间点不变或略早。

### 4.2 新的 `startRecording` 结构

```text
startRecording(purpose:requestedAt:isAutomation:manualInput:)
  1. 阻塞状态检查 / forceReset（不变）
  2. sessionGeneration += 1; state = .starting（不变）
  3. HAS_CLOUD_SUBSCRIPTION 额度检查（不变，保持在采集前）
  4. ★ if !manualInput: beginEarlyCapture(generation:)        ← 新位置
        - 新建 AudioChunkBuffer，挂 onAudioChunk / onAudioLevel
        - 解析输入设备（cachedCaptureResolution，纯内存读取）
        - try audioEngine.start()
        - 失败：沿用现有失败处理（playError、.error、.completed、idle），直接返回
  5. finalizeBeforeNextRecording、模式与上下文、resetPromptContextCapture
     ★ 其中 IntelliSenseSettingsStore.load() 恢复后新增代次校验（见 4.3.1）
  6. manualInput 分支（不变；此分支从未开启采集）
  7. 凭证加载、模型检查、createClient、热词（不变）
  8. finishAudioChunkPipeline(100 ms)（不变；它只处理上一轮的 continuation，
     与本轮 AudioChunkBuffer 无关。前提是执行到这里时本轮仍是当前代次，
     由 4.3.1 的校验保证）
  9. state = .recording; markReadyIfNeeded()               ← .ready 仍在这里发出
 10. Phase 2 connect / Phase 3 flush（不变，使用第 4 步建好的 buffer）
```

### 4.3 早启动后的统一清理

第 4 步之后到第 9 步之间有 8 个提前 `return` 的失败分支：翻译目标不支持、本地配置缺失、本地模型缺失、凭证缺失、无 client 实现，以及三处 generation 变化（zombie）检查（`finalizeBeforeNextRecording` 之后、4.3.1 新增的 `IntelliSenseSettingsStore.load()` 之后、`finishAudioChunkPipeline` 之后）。现在这些分支不用管音频，因为音频还没开。改造后每个分支都必须停止采集。

方案：在 `beginEarlyCapture` 成功后设置局部标记，用 `defer` 统一兜底：

```swift
var earlyCaptureOwned = false
defer {
    // Every early return between capture start and the hand-off below must
    // release the microphone; Bluetooth routes depend on it.
    if earlyCaptureOwned { releaseEarlyCapture() }
}
// ...beginEarlyCapture 成功后
earlyCaptureOwned = true
// ...第 9 步 state = .recording 之前
earlyCaptureOwned = false   // 所有权移交给 stopRecording / cancelRecording / forceReset
```

`releaseEarlyCapture()` 只做同步动作：`audioEngine.stop()`、清空 `onAudioChunk` / `onAudioLevel`。`defer` 不能 `await`，这里也不需要。

zombie 分支要特别注意：generation 已经变化，说明 `forceReset()` 已被其他调用方执行并停止了采集。此时再调用一次 `audioEngine.stop()` 是幂等的（`captureSession == nil` 时直接 `clearCaptureState()`），但**不能误停下一轮已开始的采集**。所以 `releaseEarlyCapture` 必须先检查 `sessionGeneration == myGeneration`，不一致时只清自己的引用，不调用 `audioEngine.stop()`。

#### 4.3.1 每个挂起点恢复后都要校验代次

`RecognitionSession` 是 actor，`startRecording` 在 `await` 处挂起期间，其他调用可以进入 actor。典型交错如下：

```text
旧调用 N   挂起在某个 await
           ← 用户松开热键：cancelRecording() → forceReset()
             sessionGeneration = N+1，state = .idle
           ← App 侧 awaitIdle() 立即放行，下一次按键开始第 N+2 轮
旧调用 N   恢复，若不校验就继续改写共享状态
```

旧调用恢复后、下一次校验之前，会改写以下共享状态：`state = .starting`（`RecognitionSession.swift:1165`，可能把新一轮的状态改回去）、IntelliSense / 翻译上下文、`self.asrClient`（:1246）、`currentTranscript`（:1259），以及 `finishAudioChunkPipeline()`（:1260）。最后这一项操作的是 `self.audioChunkContinuation`，如果新一轮已经进入 Phase 3，被结束的就是新一轮的音频发送管线，新一轮将无法再向 ASR 送音频。

`startRecording` 中全部挂起点的现状与要求：

| 行 | 挂起点 | 现状 | 要求 |
|---|---|---|---|
| 1035 | `forceReset()` | 之后才递增 generation，本身不涉及旧代次 | 不变 |
| 1042 | `MainActor.run { finalizeBeforeNextRecording }` | 1045 已校验 | 不变 |
| 1074 | `CloudQuotaManager.canUse()`（仅 `HAS_CLOUD_SUBSCRIPTION`） | **未校验** | 恢复后立即校验；该编译开关已归档，同步修正，避免将来重新启用时遗留 |
| 1135 | `IntelliSenseSettingsStore.shared.load()` | **未校验** | 恢复后、写入 `intelliSenseSettings` 等任何状态之前立即校验 |
| 1148 | `IntelliSenseContextCapturer.capture` | 位于独立 `Task` 内，不是本函数的挂起点 | 不变 |
| 1172–1173 | 手动输入分支的上下文解析 | 1174 已校验 | 不变 |
| 1260 | `finishAudioChunkPipeline` | 1261 已校验 | 不变 |

校验统一写成：

```swift
guard sessionGeneration == myGeneration else {
    DebugFileLogger.log("startRecording: zombie after <挂起点>, bailing")
    return
}
```

zombie 返回时 `earlyCaptureOwned` 仍为 `true`，由 4.3 的 `defer` 进入 `releaseEarlyCapture()`；该函数发现代次不一致，只清理本调用自己的引用，不会停掉新一轮的采集。

约束：今后在 `startRecording` 第 4 步到第 9 步之间新增任何 `await`，都必须在恢复后紧跟同样的校验。实现时在函数开头加注释说明这一点。

这是现有代码中就存在的竞态，与麦克风先行无关；但麦克风先行之后，失败分支还要负责释放麦克风，遗漏校验点的后果更重，因此在 Phase 1 中一并修复。

### 4.4 与已有路径的交互

| 场景 | 现状 | 改造后 | 处理 |
|---|---|---|---|
| 准备阶段松开热键（`barPhase == .preparing`） | `cancelRecording()` → `forceReset()`，音频未开 | 音频已开，`forceReset()` 第 3943 行停止采集 | 无需改动，`cancelRecording` 已接受 `.starting` |
| 准备阶段跨模式结束（`onCrossModeFinish`） | 无条件调用 `stopRecording()`，`.starting` 下被忽略；UI 已停止，session 仍进入录音，麦克风处于孤儿状态（现有 bug） | 与热键松开一致：`barPhase == .preparing` 时作废 start gate 并调用 `cancelRecording()` | 见 4.4.1，Phase 1 一并修复 |
| 凭证缺失 / 模型未下载 | 不开麦克风，播放错误音 | 麦克风短暂打开约 100 ms 后关闭 | 可接受，见 4.6 |
| 手动输入（`manualInput`） | 不开麦克风 | 不变（第 4 步跳过） | — |
| 改口（`.revise`） | 同语音录音 | 同样受益 | — |
| 批量识别 / 历史音频 `getRecordedAudio()` | 从 T1 开始累积 | 从更早的时间点开始累积，多约 100 ms 前导 | 有利于识别，无需处理 |

#### 4.4.1 `.starting` 期间的停止请求

`Type4MeApp` 中调用 `session.stopRecording()` 的位置共 5 处，逐一核对如下：

| 调用方 | `preparing` 阶段的处理 | 结论 |
|---|---|---|
| 热键松开（普通模式，`Type4MeApp.swift:970`） | 作废 start gate → `cancelRecording()` | 安全 |
| 热键松开（另一组绑定，`Type4MeApp.swift:1048`） | 同上 | 安全 |
| 改口热键松开（`Type4MeApp.swift:1120`） | 同上 | 安全 |
| `.completed` 事件（`Type4MeApp.swift:275`） | 只停 UI，不调用 session | 安全 |
| 跨模式结束 `onCrossModeFinish`（`Type4MeApp.swift:1228`） | **无条件** `stopRecording()` | **有缺陷** |

`barPhase` 只有在收到 `.ready` 后才会从 `.preparing` 切到 `.recording`，而 session 在发出 `.ready` 之前已经进入 `.recording`。因此“UI 已是 recording、session 仍是 starting”的组合不存在，按 `barPhase` 分流是可靠的。

决定：

1. 跨模式结束改为与热键松开一致：`barPhase == .preparing` 时作废 `recordingStartGate` / `selectionAskFollowUpStartGate`，调用 `cancelRecording()`，不做模式切换；
2. `stopRecording()` 在 `.starting` 下的行为保持不变（记录 warning 并返回），不引入“挂起的停止请求”。所有调用方都已按 `barPhase` 分流，再加一层状态只会让启动流程更复杂；
3. 新增测试：`preparing` 阶段触发跨模式结束后，采集被释放、session 回到 `.idle`。

### 4.5 speech grace 窗口必须改锚点

`speechGraceEnd` 目前在采集前计算（`RecognitionSession.swift:1275`），用来忽略提示音被麦克风收进去造成的“误判有语音”。提示音在 `.ready` 之后才播放，而现在 `.ready` 与采集开始只差 `engineStart`，所以以前问题不大。

采集提前约 100 ms 后，grace 窗口会提前结束，提示音尾部可能落在窗口之外，把 `speechDetected` 误判为 true。后果是“无语音快速退出”失效，只会多等一次 ASR 收尾，不会错误注入。但这是行为回退，必须修正。

改为一个线程安全的小类型 `SpeechGraceGate`：

- 采集开始时创建，处于未武装状态，此时任何超过阈值的电平都算真实语音（提示音还没播，用户抢先开口正是要保留的情况）；
- 由声音队列在 `player.play()` 之前同步调用 `arm(until: startedAt + startSoundDurationMs)`，`startedAt` 是实际发声时间。非蓝牙场景下这与 `.ready` 几乎同时；但开始音要经过 `soundQueue` 异步排队，蓝牙场景下还要等待输出链路稳定，所以触发点既不能放在 `markReadyIfNeeded()` 中，也不能放在入队时，详见 11.4.3、11.4.4；
- 窗口内的电平不触发 `markSpeechDetected()`，窗口结束后恢复。

电平回调运行在 `com.type4me.audiocapture` 队列，`arm` 在 actor 上调用，因此内部用 `NSLock` 或 `OSAllocatedUnfairLock`。这是纯逻辑，可以单测。

### 4.6 取舍

- **配置错误时麦克风会闪一下。** 未配置凭证或本地模型缺失时，橙色指示灯会出现约 100 ms，蓝牙设备会被短暂拉入 HFP 后立即释放。这类按键本来就会失败并提示错误，不在采集前增加任何预检。
- **actor 阻塞时间不变。** `start()` 仍同步阻塞 actor，总时长没有变化，只是顺序变了。把 `startRunning()` 放到独立队列、与准备阶段真正并行，可以再缩短 `.ready` 时间，但会引入跨线程的启动/停止竞态，收益不及解法二，暂不做（见第 7 节）。

## 5. 解法二：非蓝牙设备预建采集会话（Prepared Session）

### 5.1 思路

把冷启动拆成两段：

- **prepare**（空闲时做，慢）：创建 `AVCaptureSession`、`AVCaptureDeviceInput`、`AVCaptureAudioDataOutput`，完成 `addInput` / `addOutput`，**不调用 `startRunning()`**；
- **activate**（按键时做，快）：只调用 `startRunning()`。

停止时只调用 `stopRunning()`，保留采集图，供下次使用。

仅对**非蓝牙设备**启用。蓝牙设备维持现状：每次冷启动，停止时完全拆图。

### 5.2 适用范围

基于已有的 `AudioInputDeviceCategory`（`AudioInputDevicePreference.swift:6`）：

| 类别 | 预建 | 理由 |
|---|---|---|
| `.builtIn` | 是 | issue 的主要场景，不涉及 HFP |
| `.external`（USB / PCI / FireWire） | 是 | 无 HFP 路由问题 |
| `.bluetooth` | 否 | 2.2 节的 HFP 约束 |
| `.virtual`，纯虚拟设备（飞书 `ByteviewAudioDevice`、Loopback、BlackHole 等） | 是 | 没有物理链路，不涉及 HFP |
| `.virtual`，Aggregate 设备且活动子设备中**含蓝牙** | 否 | 底层蓝牙子设备同样受 2.2 节约束 |
| `.virtual`，Aggregate 设备且子设备**均非蓝牙** | 是 | 等价于非蓝牙设备的组合 |
| `.other`（含 Continuity iPhone 麦克风等） | 否 | 无线链路行为未知 |

Aggregate 设备的子设备通过 CoreAudio 的 `kAudioAggregateDevicePropertyActiveSubDeviceList` 读取，再对每个子设备读取 `kAudioDevicePropertyTransportType`。读取失败时按“含蓝牙”处理（保守降级为冷启动）。这部分查询放在 `AudioInputDeviceDiscovery` 中，与现有的 `transportType(device:)` 并列：

```swift
static func aggregateContainsBluetooth(uid: String) -> Bool
```

判定逻辑抽成纯函数，便于单测：

```swift
enum AudioCapturePreparationPolicy {
    static func allowsPreparedSession(
        for category: AudioInputDeviceCategory,
        isAggregateWithBluetooth: Bool
    ) -> Bool {
        switch category {
        case .builtIn, .external: return true
        case .virtual: return !isAggregateWithBluetooth
        case .bluetooth, .other: return false
        }
    }
}
```

`isAggregateWithBluetooth` 只在 `.virtual` 且传输类型为 `kAudioDeviceTransportTypeAggregate` 时才需要真正查询；其他情况直接传 `false`，避免多余的 CoreAudio 调用。

**Aggregate 的资格不是常量。** 同一个 UID 的 Aggregate 设备，活动子设备会变化：用户在“音频 MIDI 设置”中增删子设备，或者某个子设备（例如 AirPods）断开后重新连接。这些变化只体现在 Aggregate 对象自己的属性上，`AudioInputDeviceMonitor` 现有的两个监听（`kAudioHardwarePropertyDevices`、`kAudioHardwarePropertyDefaultInputDevice`，`AudioInputDevicePreference.swift:448`）都不保证会触发。如果预建资格只在 prepare 时判定一次，Aggregate 加入蓝牙子设备后，一个停止但持有输入的会话就会继续挂在蓝牙链路上，违反 2.2 节的约束。因此对 Aggregate 设备采用“监听 + 关键时刻重新判定”两层保护，见 5.5–5.7 节和 5.9 节。

### 5.3 `AudioCaptureEngine` 状态机

```text
            prepare(device) [eligible]
  ┌──────┐ ─────────────────────────► ┌──────────┐
  │ cold │                            │ prepared │
  └──────┘ ◄───────────────────────── └──────────┘
     │  ▲      invalidate()               │  ▲
     │  │      (设备变化/断开/运行错误/休眠)  │  │ stop() [prepared 设备]
     │  │                                activate │  │ stopRunning，保留图
     │  │  stop() [非预建设备]                ▼  │
     │  └──────────────────────────── ┌──────────┐
     └──────────────────────────────► │ running  │
           start() 冷启动              └──────────┘
```

内部保存：

```swift
private struct PreparedCapture {
    let session: AVCaptureSession
    let input: AVCaptureDeviceInput
    let output: AVCaptureAudioDataOutput
    let deviceUID: String
    let isAggregate: Bool                       // 传输类型为 Aggregate
    let topologyObserver: AggregateTopologyObserver?   // 仅 Aggregate 持有，见 5.9
}
private var prepared: PreparedCapture?   // 只在 configurationQueue 上读写
```

### 5.4 线程模型

Apple 建议在一个串行队列上执行所有 `AVCaptureSession` 配置和启停。新增 `configurationQueue`（串行，`.userInitiated`）：

- `prepare(deviceUID:)`、`invalidatePrepared(reason:)`：`configurationQueue.async`，不阻塞调用方；
- `start()` / `stop()`：`configurationQueue.sync`，保持现有的同步、可抛错 API，`RecognitionSession` 的调用方式不变；
- 由于串行化，按键时如果后台正在 prepare，`start()` 会等这次 prepare 完成后直接使用它，最坏情况等于冷启动，不会更慢。

`captureSession`、`activeOutput` 等现有状态也迁移到这个队列（`activeOutput` 继续用 `stateLock` 供采样回调读取）。`outputQueue`（采样回调）不变。

### 5.5 activate 前的校验

预建的 session 绑定在具体的设备 UID 上。按键时必须确认它仍是“本次应使用的设备”：

```text
start():
  target = resolveDevice()            // 现有逻辑：explicit UID 或 AVCaptureDevice.default
  if let p = prepared,
     p.deviceUID == target.uniqueID,
     target.isConnected,
     !p.isAggregate || !aggregateContainsBluetooth(uid: p.deviceUID):   // Aggregate 每次按键重新判定
       activeOutput = p.output; 重新 setSampleBufferDelegate
       p.session.startRunning()
       log "audio capture started prepared=hit"
  else:
       invalidatePrepared(reason: "mismatch" | "aggregate-bluetooth"); 冷启动（现有路径）
       log "audio capture started prepared=miss reason=…"
```

`AVCaptureDevice.default(for: .audio)` 和 `isConnected` 都是轻量调用。不依赖 `AudioInputDeviceMonitor` 的缓存快照，因为它是异步刷新的，可能比按键慢一步。

对 Aggregate 设备，按键时重新读取一次活动子设备列表及其传输类型（几个 CoreAudio 属性读取，亚毫秒级）。即使 5.9 的监听回调还没送达，也不会用一个已经挂上蓝牙子设备的预建会话启动。非 Aggregate 设备的类别不会在 UID 不变的情况下改变，不需要重新判定。

### 5.6 stop 的分支

```text
stop():
  session.stopRunning(); drainOutputQueue()
  activeOutput = nil; output.setSampleBufferDelegate(nil, queue: nil)
  eligible = 本次运行的设备类别允许预建
             && (!isAggregate || !aggregateContainsBluetooth(uid))   // Aggregate 停止时重新判定
  if eligible && !pendingInvalidate:
       保留图，prepared = PreparedCapture(...)       // 不 removeInput / removeOutput
       Aggregate 设备：确保 topologyObserver 已注册
       log "audio capture stopped; prepared session retained"
  else:
       现有的完全拆图逻辑（蓝牙、含蓝牙子设备的 Aggregate 等）
       注销 topologyObserver
  flushRemaining(); clearCaptureState()
```

`flushRemaining()` 和 `clearCaptureState()` 的顺序与现在保持一致，保证尾音仍然送出。

“是否保留采集图”是 HFP 约束真正生效的时刻，所以 Aggregate 在这里必须用实时查询的结果，不能沿用 prepare 或按键时的判定。

### 5.7 prepare 与 invalidate 的触发点

| 事件 | 动作 | 接入位置 |
|---|---|---|
| 启动且已有麦克风权限 | 替换 `warmUp()` 内部实现为 `prepareIfEligible()` | `Type4MeApp.swift:225` 现有 `session.warmUp()` |
| 一次录音结束（非预建设备或刚被 invalidate） | 停止后异步 `prepareIfEligible()` | `AudioCaptureEngine.stop()` 末尾 |
| `.audioInputDevicesDidChange` / `.audioInputDevicePreferenceDidChange` | 先 `invalidate`，再 `prepareIfEligible()` | `Type4MeApp.observeEffectiveInputDeviceChanges()`（与 `AudioKeepAliveManager.syncMicState()` 同一位置） |
| `AVCaptureDevice.wasDisconnectedNotification`（预建设备） | `invalidate` | 引擎内部订阅 |
| `AVCaptureSession.runtimeErrorNotification` | `invalidate`，下次按键走冷启动 | 引擎内部订阅 |
| `NSWorkspace.willSleepNotification` / `didWakeNotification` | 休眠时 `invalidate`，唤醒后延迟约 2 s 再 `prepareIfEligible()` | 引擎内部订阅 |
| 麦克风权限被撤销 | `prepareIfEligible()` 已有权限检查；`start()` 抛 `microphonePermissionDenied` 时 `invalidate` | 引擎内部 |
| 预建的 Aggregate 设备子设备拓扑变化 | 空闲时：`invalidate` 后 `prepareIfEligible()`（重新判定，含蓝牙则不再预建）；录音中：标记 `pendingInvalidate` | `AggregateTopologyObserver`，见 5.9 |

`prepareIfEligible()` 在 `configurationQueue` 上自己解析当前目标设备（逻辑与 `start()` 相同），不合格就确保 `prepared == nil`。

**录音进行中收到设备变化**（含 Aggregate 拓扑变化）：只标记 `pendingInvalidate = true`，不动正在运行的 session。`stop()` 看到标记后走完全拆图，之后再 prepare。录音中切换设备的行为与现在一致。

### 5.8 必须实测确认的平台行为

以下行为决定方案二能否成立，必须在实现初期用一个最小原型逐项确认：

1. **隐私指示。** 一个已 `addInput`、未 `startRunning` 的 session，菜单栏橙色麦克风指示灯和控制中心“正在使用麦克风”**不得出现**。
2. **设备占用。** 预建期间，其他 App（Zoom、语音备忘录、QuickTime 录音）可以正常独占或共享该设备，采样率不被锁定。
3. **能耗。** 预建期间没有 IO 线程活动；“活动监视器 → 能耗”中 Type4Me 的空闲能耗不明显上升。
4. **收益。** `activate` 耗时显著低于冷启动的 `engineStart`。如果 `startRunning()` 本身占了 `engineStart` 的大头（Phase 0 埋点能回答），方案二收益有限，应暂停并重新评估。
5. **Aggregate 拓扑通知。** 在“音频 MIDI 设置”中给 Aggregate 增删子设备、以及子设备 AirPods 断开再重连时，5.9 注册的属性监听确实会触发。若某种变化不触发通知，5.5、5.6 的实时重新判定仍然兜底；但空闲期间会有一个持有含蓝牙 Aggregate 输入的预建会话，此时需改为“Aggregate 不预建”，或在空闲期间定时（例如每 30 s）重新判定，二者择一后再上线。

第 1–4 项任一不满足，方案二不上线，只保留方案一。第 5 项不满足时，仅 Aggregate 的预建按上述方式降级。

### 5.9 Aggregate 子设备拓扑监听

新增 `AggregateTopologyObserver`（放在 `Type4Me/Audio/` 下，与采集引擎同目录）：

```swift
/// Watches one aggregate device's sub-device composition so a prepared
/// capture graph is dropped before a Bluetooth sub-device can pin HFP.
final class AggregateTopologyObserver {
    init?(aggregateUID: String, queue: DispatchQueue, onChange: @escaping () -> Void)
    func invalidate()   // 移除全部监听，可重复调用
}
```

- 在 Aggregate 设备对象上用 `AudioObjectAddPropertyListenerBlock` 监听三个属性：`kAudioAggregateDevicePropertyActiveSubDeviceList`、`kAudioAggregateDevicePropertyFullSubDeviceList`、`kAudioAggregateDevicePropertyComposition`。任何一个变化都调用 `onChange`，不在回调里区分具体变化。
- 回调队列直接使用采集引擎的 `configurationQueue`，`onChange` 中执行 5.7 表中的动作：空闲时 `invalidate` 后 `prepareIfEligible()`，录音中标记 `pendingInvalidate`。这样拓扑变化与 `start()` / `stop()` 天然串行，不会出现“回调正在拆图、同时按键启动”的竞态。
- 生命周期与 `PreparedCapture` 绑定：预建 Aggregate 时创建；`invalidatePrepared`、完全拆图、设备切换时调用 `invalidate()` 注销。录音中（`running`）保持注册，以便设置 `pendingInvalidate`。
- 设备对象 ID 由 UID 转换而来（复用 `AudioInputDeviceDiscovery.coreAudioDeviceID(forUID:)`，需要从 `private` 放宽为 `internal`）。转换失败或注册监听失败时返回 `nil`，调用方按“含蓝牙”处理，该 Aggregate 不预建。
- 回调触发与资格变化之间有极短的窗口（毫秒级）。窗口内若恰好按键，由 5.5 的实时重新判定兜底；若窗口内恰好停止录音，由 5.6 的实时重新判定兜底。

日志：拓扑变化时输出 `audio aggregate topology changed uid=… state=prepared|running eligible=true|false`。

## 6. 分段计时埋点（Phase 0）

在不改变行为的前提下，先补齐日志。所有时间点都相对 `recordingRequestedAt`（T0）：

| 日志字段 | 位置 | 含义 |
|---|---|---|
| `awaitIdle` | `Type4MeApp` 调用 `startRecording` 前 | 等待上一轮收尾 |
| `sessionEntry` | `startRecording` 入口 | 进入 actor 的时间 |
| `captureStartBegin` | `audioEngine.start()` 调用前 | 解法一要压缩的就是这一段 |
| `deviceInput` | `AVCaptureDeviceInput` 创建完成 | 冷启动设备打开耗时 |
| `startRunning` | `startRunning()` 返回 | 解法二收益上限 |
| `prepared` | `hit` / `miss(reason)` / `n/a(bluetooth…)` | 预建命中情况 |
| `firstSample` | 第一个 `captureOutput` 回调 | **核心指标** `requestToFirstSample` |
| `ready` | `.ready` 发出 | 用户听到提示音的时间 |

建议合并成一行，便于统计：

```text
audio start timing awaitIdle=3ms sessionEntry=5ms captureStartBegin=8ms deviceInput=- startRunning=19ms prepared=hit firstSample=31ms ready=118ms device=builtIn
```

`firstSample` 在采样回调里通过一次性原子标记记录，回调线程只写时间戳，日志在 actor 上输出，避免在音频回调里做文件 IO。

## 7. 被否决或延后的方案

| 方案 | 结论 | 原因 |
|---|---|---|
| `startRunning()` 放到后台队列，与准备阶段并行 | 延后 | 只能缩短 `.ready`，不能让采集更早；引入启动/停止竞态 |
| 用 `AVAudioEngine` 替换 `AVCaptureSession` | 否决 | 设备选择和蓝牙行为需要整体重新验证，风险远高于收益 |
| 所有设备预建（含蓝牙） | 否决 | 违反 2.2 节的 HFP 约束 |
| 内置麦克风常开 + pre-roll 环形缓冲 | 不在本文范围 | 需要常亮隐私指示和新的设置项，单独评审 |

## 8. 分阶段实施

#356 与 #355 统一在一个分支 `fix/356-recording-start-audio` 上实现，最终合并为一个 PR。各阶段作为分支内独立、可单独回退的提交，按以下顺序推进：

| 顺序 | 阶段 | 内容 | 进入下一阶段的条件 |
|---:|---|---|---|
| 1 | Phase 0 | 第 6 节埋点，无行为变化 | 本机和至少一台慢机器各采集 ≥ 30 次数据，确认第 3.3 节目标 |
| 2 | Phase 1 | 解法一（含 4.3 清理、4.4.1 跨模式结束分流、4.5 grace 改锚点） | 第 9 节相关测试通过；`captureStartBegin` 中位数 ≤ 20 ms |
| 3 | Phase 3 | #355 蓝牙开始提示音（第 11 节） | 见 11.8 |
| 4 | Phase 2 | 解法二（含 5.8 原型验证、5.9 Aggregate 拓扑监听） | 5.8 第 1–4 项全部满足，第 5 项满足或已按 5.8 降级；`prepared=hit` 时 `startRunning` 显著低于冷启动 |

Phase 3 排在 Phase 1 之后，这样 `StartSoundRouteGate.arm` 可以直接放在前移后的采集启动位置，speech grace 也只需改一次。Phase 2 放在最后，因为它是否落地取决于 5.8 的原型验证：验证不通过时，从分支中去掉 Phase 2 的提交，其余阶段照常合并。

PR 描述中同时关联 #356 与 #355，并附上 Phase 0 埋点的前后对比数据。

回滚：Phase 2 加一个隐藏开关 `tf_audioPreparedCaptureSession`，**默认开启**。理由如下：

- 是否上线已经由 5.8 的原型验证把关，验证不通过就不合并，不需要靠“默认关闭”再观察一轮；
- 默认关闭等于几乎没有用户启用，Beta 收集不到 `prepared=hit` 的数据；
- 新的 `prepared=…` 日志字段可以直接从用户反馈的 `debug.log` 中看出命中率和失败原因。

出问题时，用户可以执行 `defaults write com.type4me.app tf_audioPreparedCaptureSession -bool false` 临时关闭（下次按键生效，同时 invalidate 现有预建 session），不需要发版。Phase 1 是重排，不加开关，直接回滚提交即可。

## 9. 测试与验收

### 9.1 自动化测试

| 测试 | 类型 | 覆盖 |
|---|---|---|
| `AudioCapturePreparationPolicyTests` | 单元 | 5 个类别的预建判定，含 Aggregate 含蓝牙 / 不含蓝牙 / 子设备查询失败按含蓝牙处理 |
| `PreparedCaptureAggregateTests` | 单元 | 用假的拓扑查询与监听：空闲时拓扑变为含蓝牙 → 预建被丢弃且不再重建；录音中变化 → `pendingInvalidate`，停止后完全拆图；监听回调未送达时，按键（5.5）与停止（5.6）的实时判定仍拒绝复用；`invalidate()` 后不再回调 |
| `SpeechGraceGateTests` | 单元 | 未武装时放行；武装窗口内拦截；窗口后放行；并发 arm/check |
| `RecognitionSessionTests` 新增用例 | 单元 | 凭证缺失、翻译目标不支持、zombie 分支在早启动后都会释放采集；`.starting` 下 `cancelRecording()` 释放采集 |
| `RecognitionSessionTests` 挂起点代次用例 | 单元 | 见下方说明：IntelliSense 加载挂起期间取消，(a) 恢复后不改写任何共享状态；(b) 取消后立即开始新一轮，旧调用恢复后不影响新一轮 |
| 跨模式结束分流 | 单元 | `preparing` 阶段走 cancel，`recording` 阶段走 stop（把分流判断抽成纯函数后测试） |
| `AudioStartTimingTests` | 单元 | 计时行格式化与缺失字段 |

`RecognitionSession` 目前直接持有 `AudioCaptureEngine`，无法注入。为了覆盖 4.3 节的清理分支，需要抽一个最小协议 `AudioCapturing`（`start` / `stop` / `onAudioChunk` / `onAudioLevel` / `getRecordedAudio` / `selectedDeviceUID`），默认实现仍是 `AudioCaptureEngine`，测试中用记录调用次数的假实现。

为覆盖 4.3.1 的挂起点，`RecognitionSession` 还需要一个可注入的 IntelliSense 设置加载函数（默认 `{ await IntelliSenseSettingsStore.shared.load() }`）。测试中注入一个由 `CheckedContinuation` 控制、会一直挂起直到测试放行的实现：

- 用例 (a)：以 IntelliSense 模式开始第 N 轮，挂起在设置加载处 → `cancelRecording()` → 放行加载。断言：`state` 保持 `.idle`，`asrClient` 为 `nil`，没有创建 client，假采集的 `stop()` 只被 `forceReset()` 调用了一次，日志出现 `zombie after IntelliSense settings load`；
- 用例 (b)：同上挂起后取消，立即以普通模式开始新一轮，使其进入 `.starting` 并持有早启动采集 → 放行旧调用的加载。断言：新一轮的 `state`、`asrClient` 与音频回调不变，假采集没有被旧调用停止，新一轮的 `audioChunkContinuation` 未被结束。

这两处注入（`AudioCapturing` 与设置加载函数）是本设计仅有的测试性重构。

本改动没有新增用户可见文案，不涉及中英文切换测试。

### 9.2 手动验收矩阵（交给用户体验）

| # | 场景 | 预期 |
|---|---|---|
| 1 | 内置麦克风，按下立即说“大家都是好朋友”，重复 20 次 | 首字完整率明显提升；日志 `prepared=hit` |
| 2 | AirPods 为系统默认输入 | 日志 `prepared=n/a(bluetooth)`；录音结束后耳机恢复高音质播放（与现状一致） |
| 3 | 录音中途把系统输入从内置切到 AirPods | 当前录音不中断；下次录音走蓝牙冷启动 |
| 4 | 空闲时插拔 USB 麦克风（优先级模式） | 自动重新预建到新设备；第一次按键 `hit` 或安全 `miss` |
| 5 | 合盖休眠后唤醒立即按键 | 能正常录音（`miss` 冷启动可接受） |
| 6 | 未配置凭证时按键 | 播放错误音、提示未配置；指示灯最多闪一下 |
| 7 | 准备阶段快速点按（按下即松） | 无残留采集，指示灯熄灭 |
| 8 | 空闲 10 分钟 | 无橙色指示灯；活动监视器能耗无明显变化 |
| 9 | 预建期间用 QuickTime 录音 | 两边都正常 |
| 10 | 优先级模式指定虚拟设备（如 BlackHole / 飞书虚拟麦克风） | 日志 `prepared=hit` |
| 11 | 含 AirPods 的 Aggregate 设备作为输入 | 日志 `prepared=n/a(aggregate-bluetooth)`，行为与蓝牙一致 |
| 12 | 按住 A 模式热键、在提示音出现前按 B 模式热键 | 录音被取消，指示灯熄灭，不残留录音 |
| 13 | 不含蓝牙的 Aggregate 作为输入并已预建，空闲时在“音频 MIDI 设置”中加入 AirPods 子设备 | 日志出现 `aggregate topology changed … eligible=false`；之后按键为 `prepared=miss` 冷启动；录音结束后 AirPods 恢复高音质播放 |
| 14 | 同上，但在录音进行中加入 AirPods 子设备 | 当前录音不中断；停止后完全拆图，不保留预建会话 |
| 15 | IntelliSense 模式下按下后极快松开，再立即按下普通模式 | 第二次录音正常识别和输出，不出现无声或无结果 |

## 10. 相关但不在本文范围

- **SenseVoice 本地路径跳过开头 400 ms。** `SenseVoiceASRClient` 固定丢弃前 6400 个样本（`SenseVoiceASRClient.swift:61`），用来避开提示音。但提示音在 `.ready` 之后播放，而在解法一之后，采集开始与 `.ready` 之间还隔着整个准备阶段，所以被丢掉的很可能就是用户抢先说出的第一个字。local 版本应改为按“`.ready` 之后的提示音窗口”精确裁剪，而不是固定裁剪开头。建议在 Phase 1 合并后单独开 issue。
- **内置麦克风常开预录（pre-roll）。** 彻底解决“先开口、后按键”，但需要常亮隐私指示和新的设置项，单独评审。

## 11. 蓝牙耳机开始提示音间歇丢失（#355）

> 上游来源：[joewongjc/type4me#355](https://github.com/joewongjc/type4me/issues/355)

### 11.1 问题

报告者的环境是 AirPods Pro 3，同时作为 macOS 默认输入和输出设备，Type4Me 麦克风设为“跟随系统”，“麦克风保活”关闭。现象：

- 开始提示音间歇性缺失，有时连续几次都听不到；结束提示音始终正常；
- 日志显示录音已启动，`playStart` 和 `play()` 也都被调用了；
- 同一时段的 macOS 音频日志中出现 `Output stream format changed`；
- 打开“麦克风保活”，或把提示音输出改为 Mac mini 扬声器后，问题消失；直接指定 AirPods 作为提示音输出，问题依旧。

### 11.2 根因

报告者推测是“蓝牙麦克风启动时的模式切换”导致的，代码时序支持这一判断：

1. AirPods 的麦克风一旦被打开，就会从 A2DP（高音质、仅输出）切换到 HFP（通话模式，输入输出共用低采样率链路），输出流格式随之改变。这就是系统日志里 `Output stream format changed` 的来源。
2. `AVCaptureSession.startRunning()` 返回时，这次切换通常还没完成。会话随即进入 `.recording` 并发出 `.ready`，`Type4MeApp` 收到后**立刻**播放开始提示音（`Type4MeApp.swift:259`），开始音正好落在切换过程中。
3. 开始音使用的 `AVAudioPlayer` 是启动时预先创建并 `prepareToPlay()` 过的（`SoundFeedback.preparePlayers()`），绑定的是切换前的输出格式。切换期间播放可能被系统静默丢弃。
4. 开始音前面内置了 200 ms 静音（`buildToneBuffer` 中的 `leadInFrames`），原本用来唤醒蓝牙功放，但这个长度不足以覆盖 HFP 切换（常见为数百毫秒），所以表现为“时有时无”。

四个现象都能解释：

| 现象 | 解释 |
|---|---|
| 结束音正常 | `stopRecording()` 先 `playStop()` 再 `audioEngine.stop()`（`RecognitionSession.swift:1779`），播放时 HFP 已稳定，不发生切换 |
| 开启保活后正常 | 保活让 AirPods 一直处于 HFP，按键时不再切换 |
| 输出改为扬声器后正常 | 提示音不经过蓝牙链路 |
| 指定 AirPods 为输出仍会丢 | 切换的是同一个设备，指定与否没有区别 |

代码里还有两个旁证：

- `SoundFeedback.playBTPrimer(durationMs:)` 是专门用于唤醒蓝牙输出的静音前导，目前没有任何调用方，是废弃代码，说明之前遇到过类似问题，后来改成了 200 ms 内置前导；
- `player.play()` 的返回值没有检查（`SoundFeedback.swift:307`），日志无法区分“播放成功但被系统丢弃”和“播放直接失败”。

### 11.3 目标与非目标

- 目标：蓝牙耳机同时作为输入和输出时，开始提示音稳定可闻，且不需要开启“麦克风保活”。
- 目标：内置麦克风、外接麦克风、提示音走扬声器等场景，开始音的播放时机与现在完全一致。
- 非目标：不提前或推迟采集。录音在等待期间照常进行，不丢音频（与第 4、5 节的设计正交）。
- 非目标：不改变 `.ready` 的发出时机和录音指示条的状态切换（符合 G3）。等待只影响开始音本身。

### 11.4 方案：开始提示音等待输出链路稳定（Start Sound Route Gate）

#### 11.4.1 何时需要等待

只有同时满足以下三个条件时才启用等待，其他情况立即播放（与现在一致）：

1. 开始音没有关闭（`tf_startSound != off`）；
2. 本次采集设备的类别为 `.bluetooth`；
3. 提示音的实际输出设备与采集设备是**同一个物理蓝牙设备**。

“实际输出设备”的取法与 `SoundFeedback.applyOutputDevice` 保持一致：`tf_selectedSpeakerUID` 非空且设备可用时用它，否则用系统默认输出（`kAudioHardwarePropertyDefaultOutputDevice`）。

“同一个设备”的判定：先比较 CoreAudio UID（`AVCaptureDevice.uniqueID` 与输出设备的 `kAudioDevicePropertyDeviceUID`）。macOS 上部分蓝牙耳机的输入端和输出端暴露为两个 UID 不同的 CoreAudio 设备，因此 UID 不同时再退一步：输出设备的传输类型也是蓝牙，且两者的 `kAudioObjectPropertyName` 相同，也视为同一设备。这一点必须在实现时用 AirPods 实测确认（见 11.7）。

判定逻辑抽成纯函数，便于单测：

```swift
enum StartSoundRoutePolicy {
    static func requiresRouteSettle(
        startSoundEnabled: Bool,
        inputCategory: AudioInputDeviceCategory,
        input: (uid: String, name: String),
        output: (uid: String, name: String, isBluetooth: Bool)?
    ) -> Bool
}
```

#### 11.4.2 如何判断“已经稳定”

HFP 链路的采样率很低（通常为 16 kHz 或 24 kHz），A2DP 一般为 44.1 kHz 或 48 kHz。利用这一特征，在**开始采集之前**对输出设备做一次快照：

| 快照时的输出 nominal sample rate | 含义 | 处理 |
|---|---|---|
| ≤ 24 kHz | 已处于 HFP（保活开启，或上一次录音刚结束、尚未切回 A2DP） | 不会再发生切换，不等待 |
| > 24 kHz | 处于 A2DP，打开麦克风后将切到 HFP | 等待切换完成 |
| 读取失败 | 未知 | 保守按“将切换”处理，进入等待（受超时约束） |

等待的结束条件（先到者为准）：

1. 输出设备的 `kAudioDevicePropertyNominalSampleRate` 或输出流格式（`kAudioDevicePropertyStreamFormat`，输出 scope）变化通知到达，且新采样率 ≤ 24 kHz。之后再额外等待 **100 ms** 的稳定期，避开格式切换后的首批缓冲；
2. 达到 **800 ms** 超时，此时照常播放，并在日志中记录 `timeout`。

通知用 `AudioObjectAddPropertyListenerBlock` 注册。快照必须在 `audioEngine.start()` **之前**完成，否则可能错过切换通知。注册在会话一侧完成，播放在 `Type4MeApp` 一侧等待，两边通过一个按 `sessionGeneration` 区分的门对象交接。

> 800 ms 和 100 ms 是初始值，依据是 AirPods 常见的切换耗时。Phase 3 的日志会记录每次实际等待时长，上线后按真实分布调整。

#### 11.4.3 组件与改动点

新增 `Type4Me/Audio/StartSoundRouteGate.swift`：

```swift
/// Arms before capture starts so a Bluetooth A2DP→HFP switch is observed,
/// and lets the start sound wait until the shared output route has settled.
final class StartSoundRouteGate: @unchecked Sendable {
    enum Outcome: String { case notRequired, alreadySettled, switched, timeout, cancelled }

    static let shared = StartSoundRouteGate()

    /// Called by RecognitionSession before audioEngine.start().
    func arm(generation: UInt64, inputDevice: AVCaptureDevice?)

    /// Awaited by Type4MeApp before SoundFeedback.playStart().
    func waitUntilSettled(generation: UInt64) async -> Outcome

    /// Called on stop / cancel / forceReset; removes listeners and resumes waiters.
    func disarm(generation: UInt64)

    /// Thread-safe; true only while `generation` is the armed, not-yet-disarmed round.
    /// Read by the sound queue right before AVAudioPlayer.play().
    func isCurrent(generation: UInt64) -> Bool
}
```

门的代次语义（`cancelled` 的来源）：

| 情况 | `waitUntilSettled(generation: N)` 的结果 |
|---|---|
| 第 N 轮已 `arm`，链路判定为无需等待 / 已稳定 / 切换完成 / 超时 | `notRequired` / `alreadySettled` / `switched` / `timeout` |
| 等待期间第 N 轮被 `disarm(N)`（停止、取消、`forceReset`） | 立即返回 `cancelled` |
| 等待期间第 N+1 轮 `arm`（被新一轮取代） | 立即返回 `cancelled`，第 N 轮的监听同时注销 |
| 调用时第 N 轮从未 `arm` 或已经 `disarm` | 立即返回 `cancelled` |
| 超时计时器触发时第 N 轮已不是当前代次 | `cancelled`（超时只对当前代次产出 `timeout`） |

约束：

- 门内部只保存“当前代次”的一份状态，所有读写在一个串行队列上完成；`arm(N+1)` 先把第 N 轮的等待方以 `cancelled` 恢复，再建立新状态；
- `disarm(M)` 中 M 与当前代次不一致时不做任何事，不能误伤新一轮；
- 每个等待方的 continuation 只恢复一次（恢复后从等待表移除，重复恢复在实现中是断言失败）；
- “当前代次 + 是否已 disarm”另用一把锁保护，供 `isCurrent(generation:)` 从任意线程（包括声音队列）同步读取。`arm` / `disarm` 在门的串行队列上执行，但修改这两个字段时同时持锁；声音队列只读不写，不会反向等待门的队列，没有死锁风险；
- 每一次语音录音都调用 `arm`，包括判定为 `notRequired` 的非蓝牙场景。这样 `isCurrent` 对所有设备都能回答“这一轮是否仍有效”，播放队列的校验（见下文）不需要区分蓝牙与否。

| 位置 | 改动 |
|---|---|
| `RecognitionSession.beginEarlyCapture`（第 4 节新增的位置） | `audioEngine.start()` 之前调用 `StartSoundRouteGate.shared.arm(generation:inputDevice:)`；采集失败时 `disarm` |
| `RecognitionEvent` / `RecognitionSession.markReadyIfNeeded()` | 新增 `case sessionReady(generation: UInt64)`，由 `markReadyIfNeeded()`（`RecognitionSession.swift:3185`）代替 `.ready` 发给 App。各 ASR client 内部仍用 `.ready`，会话本来就会吞掉 client 的 `.ready`（:2976），因此不需要改动任何 client；只需更新 `RecognitionEvent` 的穷举 `switch` |
| `AppState` | 新增 `recordingReadyGeneration: UInt64?`：`markRecordingReady(generation:)` 时写入，`stopRecording()` 与进入 `preparing` 时清空 |
| `Type4MeApp` 的就绪事件处理（`Type4MeApp.swift:246` 起） | 见下方“播放前校验” |
| `stopRecording` / `cancelRecording` / `forceReset` | 调用 `disarm`，确保监听器被移除、等待方立刻返回。`stopRecording` 中 `disarm` 必须放在 `SoundFeedback.playStop()` **之前**（即 `state = .finishing` 之后的第一步），保证任何已入队、尚未执行的开始音在结束音之前就已失效 |
| `SoundFeedback.playStart` | 改为 `playStart(_ request: StartSoundRequest) async -> StartSoundPlayback`，见下方“播放队列内校验”。`request.rebuildPlayer` 为 `true`（门的结果为 `switched` 或 `timeout`）时，从缓存的 WAV 数据重新创建 `AVAudioPlayer` 再播放，不复用旧格式下 `prepareToPlay()` 过的实例。重建只涉及一段 200–400 ms 的内存 WAV，耗时可忽略 |
| `SoundFeedback.playSound` | 记录 `player.play()` 的返回值；返回 `false` 时重建播放器并重试一次。结束音、错误音、试听仍走原有的无令牌路径，行为不变 |
| `SoundFeedback.playBTPrimer` | 删除（无调用方的废弃代码） |

`.ready` 发出时机、录音指示条状态切换不受影响，等待只发生在 `Type4MeApp` 播放开始音的那个 `Task` 内部。

**两道校验。** 开始音从“决定播放”到“真正发声”跨两个执行上下文：`Type4MeApp` 的 `@MainActor` 任务做决定，`SoundFeedback` 的串行队列 `soundQueue` 用 `async` 异步执行 `player.play()`（`SoundFeedback.swift:292`）。第 N 轮在 MainActor 上通过校验并入队之后，队列中可能还有排在前面的工作（例如上一次的结束音、播放器重建），等到真正执行时，第 N 轮可能已经被取消、第 N+1 轮可能已经开始。因此校验必须做两次：

1. **MainActor 上的提前过滤**（便宜，挡掉大多数无效请求）：

```swift
let outcome = await StartSoundRouteGate.shared.waitUntilSettled(generation: N)
guard outcome != .cancelled,
      appState.barPhase == .recording,
      appState.recordingReadyGeneration == N else {
    DebugFileLogger.log("playStart aborted stage=main gen=\(N) outcome=\(outcome) barPhase=\(appState.barPhase)")
    return
}
let graceArmer = await session.speechGraceArmer(generation: N)   // 可能为 nil：开始音关闭或代次已变
let playback = await SoundFeedback.playStart(StartSoundRequest(
    generation: N,
    isStillValid: { StartSoundRouteGate.shared.isCurrent(generation: N) },
    rebuildPlayer: outcome == .switched || outcome == .timeout,
    willPlay: graceArmer
))
```

2. **播放队列内的最终校验**（权威，决定是否发声）：

```swift
struct StartSoundRequest: Sendable {
    let generation: UInt64
    let isStillValid: @Sendable () -> Bool                       // 代次令牌，可随时失效
    let rebuildPlayer: Bool
    let willPlay: (@Sendable (ContinuousClock.Instant) -> Void)?   // 发声前同步回调
}

enum StartSoundPlayback: Sendable {
    enum SkipReason: String, Sendable { case invalidated, noPlayer, playFailed }

    case played(startedAt: ContinuousClock.Instant)
    case disabled                      // 开始音关闭：不入队、不发声
    case skipped(SkipReason)
}
```

开始音关闭（`tf_startSound == off`）时，`playStart` 在调用方线程直接返回 `.disabled`，不进入 `soundQueue`，也不调用 `willPlay`。

`soundQueue` 上的执行顺序固定为：

```text
soundQueue.async {
  ① guard request.isStillValid() else { resume(.skipped("invalidated")); return }
     —— 失效时直接返回：不停止其他播放器（不打断正在播放的结束音），不改输出设备
  ② 需要时重建播放器；applyOutputDevice；停止其他播放器（沿用现有逻辑）
  ③ guard request.isStillValid() else { resume(.skipped("invalidated")); return }
     —— 重建可能耗时数毫秒，重建后再校验一次
  ④ let startedAt = ContinuousClock.now
     request.willPlay?(startedAt)          // 同步武装 speech grace，发声前完成
  ⑤ let ok = player.play()；失败则重建重试一次（重试前再执行一次 ③④）
  ⑥ resume(ok ? .played(startedAt) : .skipped("playFailed"))
}
```

关键点：

- 令牌就是 `StartSoundRouteGate.isCurrent(generation:)`，不新增独立的失效表。`disarm(N)`（停止、取消、`forceReset`）和 `arm(N+1)`（新一轮开始）都会让它立即变为 `false`，覆盖“已入队未执行”的全部失效来源；
- ① 和 ④ 之间只有本队列上的同步代码。`isCurrent` 在 ③ 之后、`play()` 之前仍可能被另一个线程翻转，这个窗口只有几行同步代码（微秒级）。窗口内发生的取消，效果等同于“开始音已经开始播放后才取消”，与现状一致，可以接受；
- `playStart` 是 `async`，通过 `withCheckedContinuation` 在队列任务末尾恢复，每条路径恰好恢复一次；
- `.played` / `.skipped` 都写日志：`start sound queue gen=N result=played|skipped(invalidated) waitedInQueue=…ms`。

**后续动作。** speech grace 只在真正发声时武装；“录音时降低系统音量”是独立设置，只要本轮仍有效就要执行，开始音只影响它的**时机**：

- **speech grace：** 不再由 MainActor 任务在入队后调用 `armSpeechGrace`。`session.speechGraceArmer(generation:)` 在会话内校验代次后，返回一个捕获本轮 `SpeechGraceGate` 的闭包，由声音队列在第 ④ 步、`play()` 之前同步调用 `arm(until: startedAt + startSoundDurationMs)`。`SpeechGraceGate` 本身是加锁的线程安全类型（4.5 节），可以从声音队列直接调用。这样队列排队期间不会提前消耗窗口，也不存在“已发声但 grace 还没武装”的空档。闭包捕获的是第 N 轮自己的门，即使晚到也只影响已经废弃的第 N 轮，不会作用到第 N+1 轮；
- **降低系统音量：** 仅当 `SystemVolumeManager.configuredReductionPercent() >= 0`（用户启用了录音降音量）时考虑，按播放结果决定时机：

| `playback` | speech grace | 降低系统音量 | 理由 |
|---|---|---|---|
| `.played(startedAt)` | 已在第 ④ 步武装 | `startedAt + startSoundDurationMs()` 之后 | 不在开始音播放途中压低音量 |
| `.disabled`（开始音关闭） | 不武装 | **立即** | 与现状一致：提示音时长为 0 时立即降音量（`Type4MeApp.swift:261` 起），两项设置互相独立 |
| `.skipped(.noPlayer)` / `.skipped(.playFailed)` | 不武装 | **立即** | 本轮有效，只是没有声音需要避让 |
| `.skipped(.invalidated)` | 不武装 | **不降** | 本轮已被取消或取代 |
| MainActor 提前过滤未通过（`cancelled`、`barPhase` 不符、代次不符） | 不武装 | **不降** | 本轮已无效，不会调用 `playStart` |

  执行降音量前（包括睡眠醒来后）统一再校验一次 `barPhase == .recording && recordingReadyGeneration == N && StartSoundRouteGate.shared.isCurrent(generation: N)`，任一不满足就不降。时机判断抽成纯函数，便于单测：

```swift
enum StartSoundVolumeSchedule: Equatable { case afterSound(ContinuousClock.Instant), immediately, none }

static func volumeSchedule(for playback: StartSoundPlayback,
                           soundDuration: Duration) -> StartSoundVolumeSchedule
```

  不降音量时直接不调用 `SystemVolumeManager.lower(to:token:)` 即可。`reserveAttenuation()` 得到的令牌没有单独的释放接口，也不需要：未使用的令牌不会产生副作用，下一次 `reserveAttenuation()` 或 `restore()` 会让它自然失效。

#### 11.4.4 与其他逻辑的联动

- **speech grace（4.5 节）。** grace 窗口以开始音**实际发声时间**为锚点：由声音队列在 `player.play()` 之前同步武装（见上文第 ④ 步），而不是在 `.ready`、MainActor 决定播放或入队时武装。开始音关闭、或播放被跳过时不武装。
- **录音时降低系统音量。** 与开始音设置相互独立：开始音实际播放时，从发声时间 `startedAt` 起算 `startSoundDurationMs()` 后再降低，避免队列排队导致音量在开始音播放途中被压低；开始音关闭或播放失败时立即降低；本轮已失效时不降低（见 11.4.3 的时机表）。
- **快速松开。** 等待期间用户松开热键，`stopRecording` / `cancelRecording` 会 `disarm`，等待方立即以 `cancelled` 返回，开始音不再播放。这与现在“播放前已停止就放弃”的行为一致。
- **跨轮。** 第 N 轮的等待在第 N+1 轮开始后才恢复时，结果为 `cancelled`（被 `arm(N+1)` 取代）；即使由于实现缺陷得到了其他结果，`recordingReadyGeneration == N` 的校验也会拦下，不会把第 N 轮的开始音播到第 N+1 轮。
- **SenseVoice 跳过开头 400 ms（第 10 节）。** 开始音在蓝牙场景下延后，进一步说明固定裁剪开头的做法不可靠。第 10 节建议改为按“开始音实际播放时间”裁剪，届时可以直接复用本节的播放时间点。

#### 11.4.5 日志

每次开始音播放前输出一行：

```text
start sound gate outcome=switched wait=412ms input=bluetooth sameDevice=uid outputRate=48000→24000 rebuild=true play=true
```

`outcome`、`wait`、`outputRate` 用于调整超时和稳定期；`sameDevice` 记录判定依据（`uid` / `name` / `no`）；`play` 是 `play()` 的返回值。

### 11.5 被否决的方案

| 方案 | 结论 | 原因 |
|---|---|---|
| 把内置静音前导从 200 ms 加长到 800 ms | 否决 | 对所有设备都推迟开始音，内置麦克风用户也要多等 600 ms；而且对蓝牙仍然是猜测时长 |
| 推迟 `.ready`，等链路稳定后再进入录音状态 | 否决 | 违反 G3，指示条变慢；录音其实早已开始，没有必要让 UI 等 |
| 蓝牙场景默认开启麦克风保活 | 否决 | 耳机长期停在通话模式，音乐和视频音质下降，正是保活默认关闭的原因 |
| 在打开麦克风之前先播放开始音 | 否决 | 播放完成前不能开麦克风，采集更晚，与第 4 节的目标冲突 |
| 恢复使用 `playBTPrimer` | 否决 | 它只唤醒输出功放，解决不了 A2DP→HFP 的格式切换 |

### 11.6 测试

自动化测试：

| 测试 | 覆盖 |
|---|---|
| `StartSoundRoutePolicyTests` | 开始音关闭、非蓝牙输入、输出为扬声器、UID 相同、UID 不同但同名且均为蓝牙、UID 不同且不同名 |
| `StartSoundRouteGateTests` | 快照为 HFP 采样率时立即返回 `alreadySettled`；模拟采样率变化后返回 `switched` 且包含稳定期；无变化时在超时后返回 `timeout`；`disarm(N)` 使第 N 轮等待方立即返回 `cancelled`；`arm(N+1)` 使第 N 轮等待方返回 `cancelled` 且第 N+1 轮正常；`disarm(N)` 不影响已 `arm` 的第 N+1 轮；对未 `arm` 的代次等待立即返回 `cancelled`；超时晚于代次切换时不产出 `timeout`；每个等待方只恢复一次 |
| `StartSoundQueueTests` | 用注入的串行队列与假播放器，先向队列放一个由信号量阻塞的任务，制造“已入队未执行”：(a) 第 N 轮开始音入队 → `disarm(N)` → `arm(N+1)` → 放行：第 N 轮返回 `.skipped(invalidated)`，假播放器 `play()` 未被调用，`willPlay` 未被调用，其他播放器未被停止；随后第 N+1 轮的开始音正常播放且只播放一次；(b) 第 N 轮入队 → 结束音入队 → `disarm(N)` → 放行：开始音被跳过，结束音正常播放且未被打断；(c) 重建播放器期间令牌失效（在假重建中翻转）：第 ③ 步拦下；(d) 有效时 `willPlay` 恰好在 `play()` 之前调用一次，传入的时间不早于入队后的放行时间；(e) `play()` 返回 `false`：重建重试一次，重试前再次校验令牌 |
| `StartSoundVolumeScheduleTests` | `.played` → `afterSound(startedAt + duration)`；`.disabled` → `immediately`；`.skipped(.noPlayer)` / `.skipped(.playFailed)` → `immediately`；`.skipped(.invalidated)` → `none`；另测“提示音关闭 + 启用录音降音量”的完整就绪处理：`playStart` 返回 `.disabled`、未进入声音队列、`willPlay` 未调用、grace 未武装，假 `SystemVolumeManager` 立即收到一次 `lower`；同一场景下若在降音量前取消本轮（代次失效），`lower` 不被调用 |
| `SpeechGraceGateTests` 补充（播放排队） | 入队后排队 300 ms 才发声时，窗口从发声时间起算，不在排队期间消耗；播放被跳过时窗口保持未武装 |
| `StartSoundPlaybackDecisionTests` | 把“播放前校验”抽成纯函数 `shouldPlayStartSound(outcome:barPhase:readyGeneration:expected:)` 后测试：`cancelled` 不播；`barPhase` 非 recording 不播；`barPhase == .recording` 但代次为 N+1 时不播（旧等待在新一轮开始后恢复的场景）；三者都满足才播 |
| `SpeechGraceGateTests` 补充 | grace 由实际播放时间触发，而不是 `.ready` |

`StartSoundRouteGate` 对 CoreAudio 的读取和监听抽成一个小协议（读取采样率、注册/移除监听），测试中用可手动触发变化的假实现。

手动验收（交给用户体验，需要 AirPods）：

| # | 场景 | 预期 |
|---|---|---|
| 1 | AirPods 为默认输入输出，保活关闭，连续开始/结束录音 30 次 | 开始音每次都能听到；日志多数为 `outcome=switched` |
| 2 | 同上，开启保活 | 日志为 `alreadySettled`，开始音不延后 |
| 3 | 上一次录音结束后 1 秒内再次按键 | 日志多为 `alreadySettled`；开始音可闻 |
| 4 | AirPods 为输入，提示音输出指定为扬声器 | 日志为 `notRequired`，行为与现在一致 |
| 5 | 内置麦克风 | 日志为 `notRequired`，开始音时机与现在一致 |
| 6 | AirPods 场景下按下立刻说话 | 首字不丢（采集未被推迟）；开始音晚于开口也属正常 |
| 7 | AirPods 场景下在开始音出现前松开热键 | 录音取消，不再补播开始音 |
| 8 | AirPods 场景下按下后立刻松开，紧接着再次按下并保持 | 只听到第二次录音的一次开始音，不出现两声；日志中第一轮为 `playStart aborted stage=main … outcome=cancelled` 或 `start sound queue … skipped(invalidated)` |
| 9 | 内置麦克风，连续快速“按下—松开—按下”10 次 | 每次有效录音只有一声开始音；结束音不被开始音打断；日志中没有同一代次的 `played` 出现在下一代次的 `sessionReady` 之后 |
| 10 | 开始音设为“关闭”，启用“录音时降低音量”，播放音乐时按下录音 | 不播放开始音；音乐音量在按下后立即降低（与现有版本一致）；松开后恢复 |

### 11.7 实现前必须实测确认

1. AirPods 的输入和输出在 CoreAudio 中是同一个 UID，还是两个 UID（决定 11.4.1 中同名兜底是否必要）；
2. HFP 切换时，输出设备是否确实会发出 `kAudioDevicePropertyNominalSampleRate` 或输出流格式的变化通知，采样率是否确实降到 24 kHz 以下（AirPods Pro 3 可能使用更高采样率的语音编码，若高于 24 kHz，需要改为“快照前后采样率发生变化”作为判据）；
3. 实际切换耗时的分布，用于确认 800 ms 超时是否合理。

### 11.8 实施

Phase 3 与其他阶段在同一分支 `fix/356-recording-start-audio` 上实现，排在 Phase 1 之后（见第 8 节）：

| 阶段 | 内容 | 完成条件 |
|---|---|---|
| Phase 3 | 本节全部内容 | 11.7 三项确认完成；11.6 自动化测试通过；手动验收 1–10 由用户确认 |

`StartSoundRouteGate.arm` 放在 Phase 1 前移后的 `beginEarlyCapture` 中、`audioEngine.start()` 之前。speech grace 在 Phase 1 中先改为可外部触发的 `SpeechGraceGate`，Phase 3 再把触发点从 `.ready` 移到“开始音实际播放时间”。
