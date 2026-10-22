# 松手出字：录音结束后的浮动条节奏重设计

> 文档类型：产品与开发设计（交互节奏专项）
> 文档状态：设计完成，已实现
> 适用平台：macOS 14+（Apple Silicon & Intel）
> 设计日期：2026-10-22
> 最后校验：2026-10-22
> 实现基线：`4422e95d`（main）
> 工作分支：`feat/release-to-text`
> 覆盖范围：录音结束（松手、点击完成、自动停止）到浮动条收起之间的全部状态与动画；所有处理模式。录音中与准备中的表现不在本文范围。

---

## 1. 背景

用户反馈：快速模式下松手后，浮动条仍会出现「校准中」。这个阶段的动画有时比识别完成还慢，文字已经上屏了，「校准中」才出现，带来明显的迟滞感。

目标体验是**松手出字**：松手后文字立刻上屏，浮动条随即消失，整个过程干脆利落，没有多余的状态提示。

### 1.1 日志证据

取 Dev 版 2026-10-22 13:38:47 的一次快速模式录音（云端流式 ASR，70 字）：

| 时间点（相对 `stop: audio stopped`） | 事件 |
|---|---|
| +0 ms | 松手，`appState.stopRecording()`，浮动条进入 `.processing`，文案「校准中」 |
| +75 ms | `stop: isFinal received` |
| +77 ms | `stop: injecting method=clipboard`，文字上屏 |
| 紧接着 | `finalized` → `showDone`，浮动条进入 `.done`（「已完成」） |
| +500 ms 后 | `autoHide` → `.hidden`，面板再用 0.25 s 淡出 |

同一时段内另外几次快速模式录音的 `isFinal` 在 +365–730 ms 之间，同样都没有经过 LLM。

结论：处理链路本身很快，迟滞感完全来自浮动条的展示。

## 2. 现状时序与根因

### 2.1 当前状态流转

```text
recording ──松手──▶ processing ──finalized──▶ done ──0.5 s──▶ hidden ──0.25 s 淡出──▶ 面板关闭
             「校准中」/「润色中」…      「已完成」
```

关键代码：

| 位置 | 行为 |
|---|---|
| `AppState.stopRecording()`（`Type4Me/UI/AppState.swift:1558`） | `.recording` 一律切到 `.processing`；快速模式（`ProcessingMode.directId`）无条件写入 `processingLabelOverride = 「校准中」` |
| `AppState.finalize(...)`（`AppState.swift:1649`） | 成功写入时调用 `showDone(message: 「已完成」)`，默认停留 0.5 s |
| `AppState.showDone` / `scheduleAutoHide`（`AppState.swift:1891`） | 到时切 `.hidden` 并调用 `onHidePanel` |
| `FloatingBarController.hide()`（`FloatingBarPanel.swift:295`） | 面板 alpha 0.25 s `easeIn` 淡出；`updatePanelLayout`（`FloatingBarPanel.swift:222`）在淡出期间保留面板 frame |
| `FloatingBarView.shouldRenderCapsule`（`FloatingBarView.swift:383`） | `barPhase == .hidden` 且未被拖动保留时返回 `false`，`capsuleAndHandle`（`FloatingBarView.swift:661`）随即移除胶囊；这次移除不在任何动画事务里 |
| `FloatingBarView.regularPhaseContent / compactPhaseContent` | 相位切换：录音内容淡出 0.18 s，处理/完成内容 `textSwap` 0.15 s |
| `FloatingBarView.capsuleWidth / compactCapsuleWidth` | 处理态与录音态宽度不同，宽度变化走 `recordingCapsuleSpringResponse = 0.3` 的弹簧动画 |
| `RecognitionSession`（`RecognitionSession.swift:1978 / 2131 / 2256`） | 短文本豁免跳过 LLM 时，把文案改写为「校准中」 |

### 2.2 根因

1. **「校准中」文案不准确。** `.processing` 阶段实际是在等 ASR 的最终结果（`endAudio` → `isFinal`）。只有本地 SenseVoice + Qwen3 混合模式会对整段音频做二次校准；云端流式 ASR 只是在等最后一个结果包，并不存在“校准”。
2. **过渡动画比它所表示的阶段还长。** 快速模式的 `.processing` 通常只存在约 80–700 ms，但进入它就要 0.15–0.18 s 的内容交叉淡入淡出，外加 0.3 s 的胶囊宽度弹簧。结果是文字已上屏，「校准中」的入场动画还没放完。
3. **「已完成」是额外的尾巴。** 文字上屏本身就是最直接的完成反馈。之后再停留 0.5 s 的「已完成」，松手到浮动条消失接近 0.6 s 以上。
4. **现有的“淡出”实际上看不到。** `AppState` 先把 `barPhase` 设为 `.hidden`，再调用 `onHidePanel`。SwiftUI 在下一次渲染时就移除了胶囊；所有 `.animation(..., value: state.barPhase)` 都挂在 `capsuleBar` 内部，父级没有动画，移除是瞬时的。`updatePanelLayout` 保住的只是 NSPanel 的 frame，0.25 s 的 alpha 动画作用在一个已经空了的面板上。「已完成」自动隐藏、`cancel()`、被抑制的取消等所有隐藏路径都是这样：浮动条直接消失，而不是淡出。

## 3. 设计目标与原则

| 目标 | 衡量方式 |
|---|---|
| 松手即有反馈 | 松手的同一帧，浮动条从“活的录音”变成“已结束”的定格状态（提示音保持不变） |
| 出字即收 | 文字上屏后，浮动条立即开始淡出，不再展示「已完成」 |
| 只为真实的等待显示状态 | 预计很快的收尾不显示任何处理文案；只有等待超过阈值，或预先知道会慢（LLM、批量识别）时，才显示处理文案 |
| 文案名副其实 | 「校准中」只用于真正发生二次校准的引擎；其余情况用「识别中」 |
| 异常与非常规结果仍有提示 | 没写进输入框、复制到剪贴板、处理失败、取消、改口、恢复、Mac Action 等结果继续显示完成态提示 |

原则：**动画时长不得超过它所表示的阶段。** 一个可能只存在 100 ms 的状态，不应配一个 300 ms 的入场动画。

## 4. 交互规范

### 4.1 新的状态流转

```text
                        ┌──────── 预计快（流式 ASR、无 LLM）────────┐
                        │                                           ▼
recording ──松手──▶ finishing（定格录音条，无文案）──400 ms 仍未出字──▶ processing「识别中」/「校准中」
                        │                                           │
                        └──── 出字 ──▶ hidden（0.15 s 淡出）◀──── 出字 ┘

recording ──松手──▶ processing「润色中」等 ── 出字 ──▶ hidden（0.15 s 淡出）
             （预计慢：需要 LLM、批量识别、仅 Qwen3）

任一阶段 ── 非常规结果 ──▶ done（保留现有提示与停留时长）──▶ hidden
任一阶段 ── 错误 ─────────▶ error（不变）
```

### 4.2 三条规则

**规则 1：松手定格。**
预计很快的收尾，松手后进入新的 `finishing` 相位。浮动条保持录音时的形状与宽度，不换内容、不变形：

- 音量波形立即归零并停止跟随音频；视觉风格自带的环境动效暂停，画面定格。
- 录音计时停止。
- 完成 / 取消按钮锁定（沿用 `recordingActionLocked`），不响应点击，也不再显示悬停提示。
- 实时识别文本（如开启）保持显示，并更新为最终文本。
- 结束提示音照常播放，作为松手的听觉确认。

**规则 2：出字即收。**
所有模式下，结果成功写入（`InjectionOutcome.inserted` 且 `llmFailed == false`）时，浮动条不再进入 `.done`，而是直接切到 `.hidden`，面板用 0.15 s `easeOut` 淡出。这一条对 `finishing` 和 `processing` 都适用。

淡出期间，浮动条保持出字那一刻的样子：同样的内容、文本和尺寸，整体变透明直至消失，不先清空再淡出。这条要求对所有隐藏路径都成立（见 5.8）。

**规则 3：只为真实的等待显示状态。**

- `finishing` 持续超过 **400 ms** 仍未出字（网络慢、二次校准耗时等），升级为 `processing` 并显示文案。此时才发生宽度变化等过渡动画；既然等待已经真实存在，提示是有意义的。
- 预先知道会慢的情况（见 4.3），松手直接进入 `processing` 并显示文案，与现状一致，不插入定格期。
- 升级后不设最短展示时长。处理文案刚出现就出字时，直接收起，不为了让动画放完而推迟。

选 400 ms 的理由：大多数流式 ASR 收尾落在这个阈值以内（见 1.1 节），不会触发提示；超过它，用户开始察觉“没反应”，这时需要告诉用户系统还在工作。实现时把阈值做成常量，便于根据日志再调。

### 4.3 各种情况的表现

| 情况 | 松手后 | 出字后 |
|---|---|---|
| 快速模式 + 云端流式 ASR | `finishing`；超过 400 ms 才显示「识别中」 | 直接收起 |
| 快速模式 + SenseVoice/Qwen3 混合（会二次校准） | `finishing`；超过 400 ms 才显示「校准中」 | 直接收起 |
| 快速模式 + 批量识别（OpenAI、Groq、批量模式等） | 直接 `processing`「识别中」 | 直接收起 |
| 快速模式 + 仅 Qwen3 | 直接 `processing`「识别中」 | 直接收起 |
| LLM 模式（智能感知、语音润色、翻译、自定义 LLM 模式） | 直接 `processing`，文案沿用模式自身的 `processingLabel` / 翻译文案 | 直接收起 |
| LLM 模式 + 预计命中短文本豁免（流式文本字数低于阈值） | 按快速模式处理 | 直接收起 |
| LLM 模式 + 收尾时才判定短文本豁免 | 保持 `processing`，文案改为「识别中」/「校准中」 | 直接收起 |
| 达到最大时长自动停止 | 直接 `processing`，文案「已达最大时长」（用户没有松手，必须告诉用户为什么停了） | 直接收起 |
| 写入失败、复制到剪贴板、粘贴未确认 | 同上 | **保留** `done` 提示（现有文案），停留时长见 4.4 |
| LLM 处理失败（`llmFailed`） | 同上 | **保留** 警告提示，2.0 s |
| 结果为空 | 同上 | 直接收起（现状即如此） |
| 取消、改口、恢复、Mac Action、临时通知 | 不变 | 不变 |

“预计慢”的判断依据都在会话开始时就能确定，详见 5.2 节。

### 4.4 保留的完成态提示

去掉的只有成功写入时的「已完成」。以下提示继续存在，因为用户需要据此采取行动：

| 结果 | 文案 | 停留时长 |
|---|---|---|
| `.copiedToClipboard` | 已粘贴到剪贴板 | 由 0.5 s 调为 **1.5 s** |
| `.pasteAttemptedClipboardRetained` | 已尝试输入，文本已保留到剪贴板 | 由 0.5 s 调为 **1.5 s** |
| `.notInserted` | 未找到可输入的位置 | 由 0.5 s 调为 **1.5 s** |
| `.discarded` | 已取消 | 0.5 s（不变） |
| `llmFailed` 各分支 | 处理失败，… | 2.0 s（不变） |

调长前三项的理由：「已完成」去掉后，完成态只在“需要用户注意”时出现。0.5 s 不足以读完一句提示，这些结果又恰恰要求用户去剪贴板或别处找文字。

### 4.5 文案

| 键 | 中文 | 英文 | 使用场景 |
|---|---|---|---|
| `recognizing` | 识别中 | Recognizing | 等待 ASR 最终结果（流式超时、批量识别、仅 Qwen3） |
| `calibrating` | 校准中 | Calibrating | 只用于 SenseVoice + Qwen3 混合模式等待 Qwen3 最终校准 |

两条文案都要以语义值保存，在显示时按 `tf_language` 渲染（见 5.6 节），录音过程中切换语言也要立即生效。

## 5. 开发设计

### 5.1 新增相位 `FloatingBarPhase.finishing`

在 `FloatingBarPhase`（`AppState.swift:7`）中新增 `finishing`，语义是：录音已结束，正在等预计很快的最终结果，界面定格、不显示文案。

选择新增相位，而不是在 `.processing` 上加 `isRevealed` 之类的标志，原因是：

- `.processing` 的所有消费者（宽度、边框、图标、悬停、处理开始时间）都隐含“显示处理文案”的语义。加一个标志就要逐处判断，容易漏。
- 新增 case 后，所有对 `FloatingBarPhase` 的穷举 `switch` 都会编译报错，可以逐个明确处理，不会漏网。

`finishing` 在各处的处理：

| 消费点 | `finishing` 的行为 |
|---|---|
| `FloatingBarView.regularPhaseContent` | 与 `.preparing, .recording` 同一分支，渲染 `recordingContent`，并传入冻结标记；**不触发相位过渡**（同一视图 identity 保持，避免淡入淡出） |
| `FloatingBarView.compactPhaseContent` | 同上，渲染冻结的 `compactRecordingContent` |
| `capsuleWidth` / `compactCapsuleWidth` / `capsuleHeight` | 沿用 `.recording` 的宽高（`recordingPeakWidth`），不发生宽度弹簧 |
| `capsuleBorder` | 同 `.recording` |
| `showTranscriptPopup` | 不因悬停弹出；`pinsTranscriptPopup` 的现有行为保留 |
| `activeTopOverlay` | 不显示动作提示、模式提示 |
| `handlePhaseChange` | 调用 `dismissModeHint()`，`recordingActionLocked = true` |
| `AudioVisualizer` / `CompactAudioIndicator` / `LiquidGlass*` | 接收冻结标记，电平固定为 0，暂停环境动画；逐个视觉风格核对（含 11 种 Liquid Glass 预设） |
| `MenuBarIcon.label(isRecording:)`（`Type4MeApp.swift:16`） | 视为非录音 |
| `StartSoundRoutePolicy`（`StartSoundRoutePolicy.swift:58`） | 视为非录音，保持现有 `barPhase == .recording` 判断即可 |
| 浮动条录音控制 `performRecordingControlAction` | `finishing` 下忽略（现有 `phase == .preparing || .recording` 的守卫已满足） |
| `DemoState`、`AppearancePreviewStage` | 演示循环改为 `recording → finishing → hidden`；外观预览的“处理中”仍预览 `.processing` |

冻结标记建议由视图从 `state.barPhase == .finishing` 派生，不额外存状态。

### 5.2 收尾提示：会话开始时确定“预计快 / 预计慢”

`AppState.stopRecording()` 在 `RecognitionSession.stopRecording()` 之前、在主线程同步调用，当时拿不到会话里的 `providerIsStreaming` 等信息。因此由会话在开始时把判断依据告诉 `AppState`：

```swift
/// Decided once per recording, when the session's provider config is resolved.
struct RecordingFinishHint: Equatable, Sendable {
    /// Whether the end of recording waits on a batch upload or a Qwen3-only final pass.
    var waitsForFullAudioRecognition: Bool
    /// SenseVoice streaming + Qwen3 final calibration.
    var performsCalibration: Bool
    /// The mode will call an LLM unless short-text exemption applies.
    var runsLLM: Bool
    /// `ProcessingMode.shortTextExemption`; 0 means disabled.
    var shortTextExemption: Int
}
```

- 新增 `RecognitionEvent.finishHint(RecordingFinishHint)`，在 `RecognitionSession.startRecording` 解析完 provider 配置后发出（与 `sessionReady` 同时机或紧随其后）。`waitsForFullAudioRecognition` 取自 `ASRProviderRegistry.capabilities(for:config:).isStreaming` 以及 Qwen3-only 判断；`runsLLM` 取自 `Self.shouldRunInputModeLLM(recordingPurpose:mode:)`。
- `Type4MeApp` 收到后写入 `appState.recordingFinishHint`；`AppState.startRecording()` / `startReviseRecording()` 将其重置为 `nil`。
- `AppState.stopRecording()` 的判定：

```swift
let expectsQuickFinish: Bool = {
    guard let hint = recordingFinishHint else { return true }
    if hint.waitsForFullAudioRecognition { return false }
    guard hint.runsLLM else { return true }
    let text = transcriptionText.trimmingCharacters(in: .whitespacesAndNewlines)
    return hint.shortTextExemption > 0 && text.count < hint.shortTextExemption
}()
```

`hint == nil`（极短录音，事件还没到）按“预计快”处理。如果最后其实要走 LLM 或批量识别，最多 400 ms 后会自动升级为 `processing`，代价有限。

### 5.3 `AppState.stopRecording()` 改造

```swift
case .recording:
    recordingReadyGeneration = nil
    processingFinishTime = nil
    audioLevel.current = 0
    recordingStartDate = nil
    if expectsQuickFinish {
        processingLabelOverride = nil
        finishingLabel = hint.performsCalibration ? .calibrating : .recognizing
        barPhase = .finishing
        scheduleFinishingReveal()
    } else {
        processingLabelOverride = nil   // 走模式自身 processingLabel
        barPhase = .processing
    }
    onShowPanel?()
```

- 删除 `currentMode.id == ProcessingMode.directId` 时写入「校准中」的分支。
- `stopRecording(suppressProcessingUI: true)` 的守卫扩展为 `.recording || .finishing || .processing`。
- `.preparing` 的取消逻辑不变。

新增参数或独立方法区分“达到最大时长”的停止：`Type4MeApp` 的 `.completed` 分支目前先调用 `stopRecording()`，再写入「已达最大时长」。改为 `stopRecording(reason: .maxDuration)`，直接进入 `.processing` 并显示该文案，不经过 `finishing`。

### 5.4 定格超时升级

```swift
static let finishingRevealDelay: Duration = .milliseconds(400)

private var finishingGeneration = 0

private func scheduleFinishingReveal() {
    finishingGeneration += 1
    let myGeneration = finishingGeneration
    Task { @MainActor in
        try? await Task.sleep(for: Self.finishingRevealDelay)
        guard barPhase == .finishing, finishingGeneration == myGeneration else { return }
        DebugFileLogger.log("finishing: revealed processing after 400ms")
        barPhase = .processing
    }
}
```

- `startRecording`、`cancel`、`finalize`、`showError`、`showRecovery` 等离开 `finishing` 的入口都让 `finishingGeneration += 1`，旧定时器即使醒来也不会误升级。
- 升级时显示的文案来自 `finishingLabel`（见 5.6）。
- 为了测试，延迟时长允许通过 `AppState.init` 注入，测试中可设为 0 或很短。

### 5.5 `finalize` 改造：出字即收

```swift
func finalize(text: String, outcome: InjectionOutcome, llmFailed: Bool = false) {
    let shouldRevealSuppressedFinalization = ...
    guard barPhase == .processing || barPhase == .finishing || shouldRevealSuppressedFinalization else { ... }
    finishingGeneration += 1
    ...
    if llmFailed {
        // 不变：警告提示 2.0 s
    } else if outcome == .inserted {
        dismissAfterOutput()
    } else {
        feedbackKind = .standard
        showDone(message: outcome.completionMessage, delay: outcome.completionHoldDuration)
    }
}

private func dismissAfterOutput() {
    DebugFileLogger.log("dismissAfterOutput: barPhase \(barPhase) → .hidden")
    hideGeneration += 1          // 让任何待执行的 autoHide 失效
    if let message = takePendingTransientNotification() {
        presentTransientNotification(message, delay: .seconds(2))
        return
    }
    hidePanel(style: .output) {
        barPhase = .hidden
        pinsTranscriptPopup = false
        // 不清空 segments：退场快照需要它，下一次 startRecording() 会重置。
    }
}
```

`hidePanel(style:_:)` 是所有隐藏路径共用的入口，保证“先截取退场快照，再改状态”的顺序，详见 5.8。

- `InjectionOutcome` 增加 `completionHoldDuration`：`.copiedToClipboard`、`.pasteAttemptedClipboardRetained`、`.notInserted` 为 1.5 s，`.discarded` 为 0.5 s，`.inserted` 不使用。
- `InjectionOutcome.inserted.completionMessage`（「已完成」）不再用于浮动条。是否保留取决于其他调用方：实现时 `grep` 确认，无人使用就删除这条文案。
- 被抑制的取消（`awaitsSuppressedCancellationFinalization`）路径行为不变：它的结果从来不是 `.inserted`，仍按现有逻辑显示短提示。
- `finalizeRevise`、`showRecoveryResult`、`showMacActionResult`、`showCancelled` 不变。

### 5.6 文案以语义值保存

现有 `processingLabelOverride` 存的是 `L(...)` 渲染后的字符串，录音中切换语言不会更新。新增内容不沿用这个做法：

```swift
enum FinishingLabel: Equatable, Sendable {
    case recognizing
    case calibrating

    var localized: String {
        switch self {
        case .recognizing: L("识别中", "Recognizing")
        case .calibrating: L("校准中", "Calibrating")
        }
    }
}

var finishingLabel: FinishingLabel = .recognizing

var effectiveProcessingLabel: String {
    processingLabelOverride ?? (usesFinishingLabel ? finishingLabel.localized : currentMode.processingLabel)
}
```

`usesFinishingLabel` 在从 `finishing` 升级、批量识别直接进入 `processing`、以及收尾时才判定短文本豁免这三种情况下为 `true`。`FloatingBarView` 已通过 `@AppStorage("tf_language")` 或等效机制随语言刷新；实现时确认处理态文案在语言切换后会重绘。

### 5.7 `RecognitionSession` 中「校准中」的改写

三处 `onASREvent?(.processingLabelOverride(L("校准中", "Calibrating")))` 都是“短文本豁免跳过 LLM”的场景：

| 位置 | 现状 | 改为 |
|---|---|---|
| `RecognitionSession.swift:1978`（stop 前用流式文本预判） | 提前改文案，避免「润色中」闪成「校准中」 | 删除。预判已经前移到 `AppState.stopRecording()`（5.2），浮动条一开始就处于 `finishing` |
| `RecognitionSession.swift:2131`（流式路径，收尾后判定） | 改文案为「校准中」 | 发出新事件 `.useFinishingLabel`，`AppState` 将 `usesFinishingLabel` 置为 `true` |
| `RecognitionSession.swift:2256`（非流式同步路径） | 同上 | 同上 |

### 5.8 面板退场：保留内容直到淡出结束

#### 5.8.1 问题

见 2.2 节第 4 条：`barPhase` 一变成 `.hidden`，`FloatingBarView` 就移除胶囊，面板的 alpha 动画只作用在空面板上。仅仅缩短淡出时长、改用 `easeOut` 没有意义，必须先让内容在退场期间留在画面上。

#### 5.8.2 思路

逻辑状态与展示状态分开：

- **逻辑状态立即结束。** `AppState.barPhase` 照常立即变为 `.hidden`，会话就此结束。新录音、临时通知、快捷键、`StartSoundRoutePolicy` 等依赖 `barPhase` 的判断都不受退场动画影响。
- **展示状态由退场快照维持。** 面板开始淡出时，由 `FloatingBarController` 截取一份退场快照，写入 `FloatingBarChromeModel`。`FloatingBarView` 在 `barPhase == .hidden` 且快照存在时，按快照渲染。淡出完成后清除快照。

这与现有的 `isRetainedForDrag`（逻辑上已经 hidden，视觉上为拖动保留胶囊）是同一类机制，放在同一个 chrome 模型里。

#### 5.8.3 退场快照

```swift
/// What the floating bar looked like when its exit fade began.
struct FloatingBarExitSnapshot: Equatable {
    /// `FloatingBarController.panelGeneration` at capture time.
    let generation: Int
    let phase: FloatingBarPhase
    let segments: [TranscriptionSegment]
    let processingLabel: String
    let feedbackMessage: String
    let feedbackKind: FeedbackKind
    let activityKind: RecordingActivityKind
    let showsReviseUndo: Bool
    let pinsTranscriptPopup: Bool
}

// FloatingBarChromeModel
@Published private(set) var exitSnapshot: FloatingBarExitSnapshot?
```

胶囊宽度不需要放进快照：`capsuleWidth` 由 `phase` 与文本算出；`.recording` / `.finishing` 用的 `recordingPeakWidth` 是视图的 `@State`，只在 `.preparing` 时重置，退场期间不会变。

#### 5.8.4 截取顺序

快照必须取自隐藏前的状态。`AppState` 新增统一入口，所有隐藏路径都经过它：

```swift
/// Starts the panel exit while the bar still shows its final content, then
/// ends the logical session. The controller snapshots the current state in
/// `onHidePanel`, so the order of these two steps matters.
private func hidePanel(style: FloatingBarHideStyle, then endSession: () -> Void) {
    onHidePanel?(style)
    endSession()
}
```

- 两步在同一个主线程同步调用里完成。SwiftUI 在两步都做完后才渲染，所以视图第一次看到 `.hidden` 时快照已经就位，不会闪一帧空白。
- 现有隐藏路径全部改走 `hidePanel`：`scheduleAutoHide`（`.done` / `.error` 自动隐藏）、`cancel()`、`stopRecording(suppressProcessingUI: true)`、`dismissAfterOutput()`。各路径原有的状态清理（例如 `cancel()` 清空 `segments`）放进 `endSession` 闭包，快照不受影响。
- 需要先展示临时通知的路径（`takePendingTransientNotification()` 非空）不隐藏面板，也就不截取快照，与现状一致。

#### 5.8.5 `FloatingBarController`

```swift
enum FloatingBarHideStyle { case standard, output }

func hide(style: FloatingBarHideStyle = .standard) {
    let action = dragLifecycle.hideRequested()
    chrome.isRetainedForDrag = dragLifecycle.isRetainedForDrag
    if action == .retainForDrag { return }          // 拖动保留：不截取快照
    chrome.resetHover()
    guard panel.isVisible else { return }
    if chrome.exitSnapshot == nil, state.barPhase != .hidden {
        chrome.setExitSnapshot(.capture(from: state, generation: panelGeneration))
    }
    cancelPendingPanelShrink()
    panel.ignoresMouseEvents = true
    isHiding = true

    let expectedGeneration = panelGeneration
    NSAnimationContext.runAnimationGroup({ ctx in
        ctx.duration = style == .output ? 0.15 : 0.25
        ctx.timingFunction = CAMediaTimingFunction(name: style == .output ? .easeOut : .easeIn)
        panelRef.animator().alphaValue = 0
    }, completionHandler: { [weak self] in
        MainActor.assumeIsolated { self?.finishHide(generation: expectedGeneration) }
    })
}

/// Internal so tests can complete the exit without waiting for AppKit.
func finishHide(generation: Int) {
    guard panelGeneration == generation else { return }   // 已被新的 show() 接管
    isHiding = false
    panel.orderOut(nil)
    anchorDisplayID = nil
    chrome.setExitSnapshot(nil)
}

func show() {
    ...
    panelGeneration &+= 1
    chrome.setExitSnapshot(nil)      // 新内容立即接管，旧快照作废
    ...
}
```

- **防止旧退场影响新录音。** 退场中途开始新录音时，`show()` 先让 `panelGeneration` 加一并清除快照。旧动画的 completion 带着旧 generation 回来，`finishHide` 直接返回，既不会 `orderOut` 新面板，也不会清掉新录音的状态。现有 completion 已有同样的 generation 守卫，这里只是把清除快照放进同一个守卫之后。
- **重复隐藏不覆盖快照。** 退场中途再次调用 `hide()`（例如 `.done` 自动隐藏与 `cancel()` 先后到达）时，`exitSnapshot` 已存在或 `barPhase` 已是 `.hidden`，不会重新截取。
- `updatePanelLayout`（`FloatingBarPanel.swift:222`）在退场期间保留面板尺寸的守卫不变。视图按快照渲染时，算出的布局与淡出前相同，本来也不会触发尺寸变化。
- `AppState.onHidePanel` 的类型改为 `((FloatingBarHideStyle) -> Void)?`，只有 `dismissAfterOutput()` 传 `.output`。

#### 5.8.6 `FloatingBarView`

视图里所有**展示相关**的读取改为经过一层“展示值”，快照存在时优先使用快照：

```swift
private var exitSnapshot: FloatingBarExitSnapshot? {
    state.barPhase == .hidden ? chrome?.exitSnapshot : nil
}
private var presentedPhase: FloatingBarPhase { exitSnapshot?.phase ?? state.barPhase }
private var presentedSegments: [TranscriptionSegment] { exitSnapshot?.segments ?? state.segments }
// 同理：presentedProcessingLabel、presentedFeedbackMessage、presentedFeedbackKind、
// presentedActivityKind、presentedShowsReviseUndo、presentedPinsTranscriptPopup

private var shouldRenderCapsule: Bool {
    presentedPhase != .hidden || isRetainedForDrag
}
```

| 读取 | 改为 |
|---|---|
| `shouldRenderCapsule`、`regularPhaseContent`、`compactPhaseContent`、`capsuleWidth`、`compactCapsuleWidth`、`capsuleHeight`、`capsuleBorder`、`compactStatusIntrinsicWidth`、`doneContent` / `compactDoneContent`、`showTranscriptPopup` | 读 `presented*` |
| `.onChange(of: state.barPhase)` → `handlePhaseChange`、动作回调、`audioLevel` | 继续读真实 `state`；`handlePhaseChange(.hidden)` 的悬停重置照常执行 |

- 快照渲染期间，胶囊不响应交互：`hide()` 已设置 `panel.ignoresMouseEvents = true`。改口的「撤销」按钮按 `showsReviseUndo` 保持原样显示，但不可点击。
- 只保留胶囊和固定显示的转写气泡（`pinsTranscriptPopup`）。依赖悬停的提示（动作提示、模式提示、拖动手柄）在 `.hidden` 时照常立即移除。这些提示只在 `.preparing` / `.recording` 期间出现，退场时本来就很少可见。
- 外观预览（`AppearancePreviewStage`）没有 chrome 模型，`exitSnapshot` 恒为 `nil`，行为不变。

#### 5.8.7 淡出曲线

- `.output`：0.15 s `easeOut`。`easeOut` 一开始就明显变淡，用户在出字的同时就能看到浮动条在离开；`easeIn` 前段几乎不动，会被感知为“还挂着”。
- `.standard`：保持 0.25 s `easeIn`。

注意：有了退场快照之后，现有的「已完成」自动隐藏、错误自动隐藏、`cancel()` 等路径**第一次真正出现淡出**，不再是瞬间消失。这是这项改动顺带修复的问题，需要在体验验证时一并留意这些路径的观感。如果 0.25 s `easeIn` 在真实可见后显得拖沓，再统一调整 `.standard`。

### 5.9 日志

为后续根据真实数据调整阈值，补充两条带毫秒的日志：

```text
floating bar: release → hidden 92ms (path=finishing, revealed=false, outcome=inserted)
floating bar: release → hidden 1430ms (path=processing, revealed=n/a, outcome=inserted)
```

在 `stopRecording` 记录 `ContinuousClock.now`，在 `dismissAfterOutput` / `showDone` / `showError` 中计算差值。

## 6. 边界情况

| 场景 | 预期 |
|---|---|
| 升级为 `processing` 后几十毫秒就出字 | 直接收起，不补足动画时长 |
| `finishing` 期间发生错误 | 进入 `.error`，现有错误展示不变；升级定时器失效 |
| `finishing` 期间进入恢复流程（`recoveryStarted`） | 进入 `.recovering`，不变 |
| `finishing` 期间再次按下快捷键 | 与现状在 `.processing` 时一致（`hotkeyManager.isProcessing` 控制）；`RecognitionSession` 自身的状态守卫不变 |
| `finishing` 期间用户想取消 | 浮动条按钮已锁定；快捷键取消路径沿用现有 `cancellationHidesProcessingUI` 逻辑，守卫需包含 `.finishing` |
| 出字的同时有一条待显示的临时通知 | `dismissAfterOutput` 先取出待显示通知并展示，与 `cancel()` 一致 |
| 正在拖动浮动条时出字 | 沿用 `dragLifecycle.hideRequested()` 的保留逻辑 |
| 极短录音、没有流式文本（现有 “fast exit” 路径） | 结果为空则 `cancel()` 收起；有结果则出字即收 |
| 改口（Revise） | 不经过 `stopRecording()` 的 `finishing` 分支：改口有独立的 `showReviseProcessing` 与「已改好 + 撤销」完成态，全部保留 |
| 淡出中途立刻开始下一次录音 | `startRecording()` → `onShowPanel` → `show()`：`panelGeneration` 加一、清除快照，面板 alpha 从当前值回到 1（`show()` 现有的 `wasHiding` 分支），直接显示新的 `.preparing`。旧 completion 因 generation 不符而忽略 |
| 淡出中途收到临时通知 | `presentTransientNotification` 调用 `onShowPanel`，同上：快照清除，显示通知 |
| 淡出中途再次触发隐藏 | 不重新截取快照，沿用第一次的快照与动画 |
| 淡出中途开始拖动 | 退场期间 `ignoresMouseEvents = true`，拖动无法开始；不需要额外处理 |
| 面板本来就不可见时隐藏 | `hide()` 的 `panel.isVisible` 守卫直接返回，不截取快照 |
| 屏幕参数变化、面板被移到其他显示器 | 快照不含位置信息；退场期间位置按现有逻辑处理 |

## 7. 本地化

- 新增文案「识别中 / Recognizing」，沿用「校准中 / Calibrating」，均通过 `FinishingLabel.localized` 在显示时渲染。
- 「已完成 / Done」从成功写入路径移除；`AppState.feedbackMessage` 的默认值、`DemoState` 中的演示文案同步调整。
- 中英文各走查一遍：快速模式流式、混合校准、批量识别、LLM 模式、剪贴板回退、未找到输入位置；并在 `processing` 显示期间切换 `tf_language`，确认文案立即更新。

## 8. 测试计划

`Type4MeTests/AppStateTests.swift`：

| 用例 | 断言 |
|---|---|
| 修改 `testStopRecordingTransitionsDirectModeToProcessing` → `testStopRecordingEntersFinishingWhenQuickFinishExpected` | 快速模式 + 无提示 / 流式提示：`barPhase == .finishing`，`processingLabelOverride == nil` |
| 修改 `testStopRecordingTransitionsToProcessingWhenRecording` | `runsLLM == true`：`barPhase == .processing`，文案为模式自身 `processingLabel` |
| 新增：批量识别直接进入处理态 | `waitsForFullAudioRecognition == true`：`.processing`，文案「识别中」 |
| 新增：短文本预判走快速路径 | `runsLLM == true`、流式文本短于阈值：`.finishing` |
| 新增：定格超时升级 | 注入短延迟，等待后 `barPhase == .processing`；`performsCalibration` 决定「校准中」或「识别中」 |
| 新增：旧定时器不误升级 | 升级前 `finalize` 或开始新录音，等待后相位不被改写 |
| 新增：`finishing` 出字即收 | `finalize(.inserted)` 后 `barPhase == .hidden`，`onHidePanel` 收到 `.output`，`segments` 未被清空 |
| 新增：`processing` 出字即收 | 同上 |
| 新增：隐藏顺序 | 在 `onHidePanel` 闭包里读取 `appState.barPhase`，断言仍是隐藏前的相位（覆盖 `dismissAfterOutput`、`.done` 自动隐藏、`cancel()`、被抑制的取消四条路径） |
| 修改 `testFinalizeSuccessResetsFeedbackKindToStandard` | 成功写入不再进入 `.done` |
| 保持：`testFinalizeShowsClipboardFallbackMessage`、`testFinalizeShowsNoDestinationMessage`、`testFinalizeShowsCancelledMessageWhenResultIsNotRetained`、`testFinalizeWithLLMFailure*` | 仍进入 `.done` 并显示原文案；补充停留时长断言 |
| 保持：`testSuppressedCancellationHidesProcessingUntilItFinalizes` | `.finishing` 下抑制也生效 |
| 新增：达到最大时长 | `stopRecording(reason: .maxDuration)` 直接 `.processing`，文案「已达最大时长」 |
| 新增：语言切换 | `.processing` + `usesFinishingLabel` 时切换 `tf_language`，`effectiveProcessingLabel` 随之变化 |
| 新增：待显示通知 | 出字即收时有挂起的临时通知，则展示该通知而非直接隐藏 |

`FloatingBarController`（参照现有 `testFloatingPanelControllerEnablesMouseOnlyForVisibleContent` 的构造方式）：

| 用例 | 断言 |
|---|---|
| 隐藏时截取快照 | 面板可见、`barPhase == .finishing` 且有文本时调用 `hide(style: .output)`：`chrome.exitSnapshot` 的相位、文本、generation 与隐藏前一致 |
| 淡出完成清除快照 | `finishHide(generation:)` 传入当前 generation：快照为 `nil`、面板 `orderOut` |
| 退场中途开始新录音 | `hide()` 后调用 `show()`：快照立即为 `nil`；再用旧 generation 调用 `finishHide`：面板仍可见，快照仍为 `nil`，新状态不受影响 |
| 重复隐藏不覆盖快照 | `hide()` 后把 `barPhase` 设为 `.hidden` 再次 `hide()`：快照仍是第一次的内容 |
| 拖动保留不截取快照 | `dragLifecycle` 要求保留时调用 `hide()`：快照为 `nil` |

视图层：

- 为 `FloatingBarView` 的宽度计算补充断言：`.finishing` 的 `capsuleWidth` 与 `.recording` 相同（常规与精简两种样式）。
- `barPhase == .hidden` 且存在快照时，`shouldRenderCapsule == true`，宽度等于快照相位对应的宽度，`panelLayout` 与隐藏前相同；快照清除后 `panelLayout == .hidden`。这些计算属性目前是 `private`，实现时可抽到可测试的纯函数（与 `FloatingBarPlacementGeometry` 的做法一致）。

按项目约定，实现完成后的体验验证交给用户；开发侧完成编译、上述单测与安装完整性检查。

## 9. 改动文件清单

| 文件 | 改动 |
|---|---|
| `Type4Me/UI/AppState.swift` | `FloatingBarPhase.finishing`；`RecordingFinishHint` 存储与判定；`stopRecording` 改造；升级定时器；`finalize` / `dismissAfterOutput`；`FinishingLabel`；统一隐藏入口 `hidePanel(style:then:)`，所有隐藏路径改走它；`onHidePanel` 接收 `FloatingBarHideStyle` |
| `Type4Me/ASR/SpeechRecognizer.swift` | `RecognitionEvent.finishHint`、`.useFinishingLabel`；`InjectionOutcome.completionHoldDuration` |
| `Type4Me/Session/RecognitionSession.swift` | 会话开始时发出 `finishHint`；三处「校准中」改写 |
| `Type4Me/Type4MeApp.swift` | 处理新事件；最大时长停止改用 `stopRecording(reason:)`；`MenuBarIcon` 等对相位的判断 |
| `Type4Me/UI/FloatingBar/FloatingBarView.swift` | `.finishing` 的内容、宽高、边框、悬停、冻结标记；展示相关读取改走 `presented*`，退场期间按快照渲染 |
| `Type4Me/UI/FloatingBar/FloatingBarPanel.swift` | `hide(style:)` 截取退场快照；`finishHide(generation:)`；`show()` 清除快照 |
| `Type4Me/UI/FloatingBar/FloatingBarChromeModel.swift` | `FloatingBarExitSnapshot` 与 `exitSnapshot` |
| `Type4Me/UI/FloatingBar/AudioVisualizer.swift`、`CompactAudioIndicator.swift`、`LiquidGlass/*` | 支持冻结 |
| `Type4Me/UI/Setup/DemoState.swift` | 演示循环更新 |
| `Type4MeTests/AppStateTests.swift` | 见第 8 节（含 `FloatingBarController` 退场用例） |

## 10. 不在本文范围

- 录音开始阶段（`preparing`）的节奏，见 [录音启动延迟优化](../runtime/recording-start-latency-design.md)。
- 结束提示音的音色与时机。
- 改口、Mac Action、恢复流程的完成态设计。
- 把“定格超时”阈值做成用户设置。先用常量，根据 5.9 节的日志再决定是否需要。
