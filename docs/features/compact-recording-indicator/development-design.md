# Type4Me 紧凑型录音指示条开发设计

> 分支：`feat/compact-recording-indicator`
> 文档类型：开发设计
> 文档状态：设计中
> 设计日期：2026-08-25
> 对应产品设计：`docs/features/compact-recording-indicator/product-design.md`

## 1. 设计摘要

本功能在现有 Floating Bar presentation 上增加独立的录音指示条外观维度：`Regular` 与 `Compact`。

现有 `RecordingVisualStyle` 保持职责不变，只描述 Regular 内部的 Lines / Particles / Levels / No Effects / None。Compact 不加入该 enum，而由新的持久化 preference 控制。

Compact 在整个可见 Floating Bar 生命周期中保持 24pt 高的 Compact chrome，但宽度采用 phase-aware 策略。`.preparing` / `.recording` 固定为 180 × 24，左右为 15 × 15 Finish / Cancel 视觉按钮，中间由独立 `CompactAudioIndicator` 使用现有 `AudioLevelMeter` 驱动 2pt 宽、2–18pt 高的动态声纹柱；`.processing` / `.recovering` / `.done` / `.error` 则由 Compact 专属 status content 按 `icon + text + optional action + insets` 的 intrinsic content width 自适应，不以 180pt 为最小宽度。

Compact 不进入 Regular transcript、Transcript hover popup、`AudioRipple`、`ProcessingProgress` 或 55pt feedback 路径。录音阶段继续支持模式提示气泡与按钮悬停操作气泡（对齐 15×15 按钮中心）。选择 Compact 后，phase transition 只能改变 compact content，不能切回 Regular renderer。

## 2. 核心工程原则

1. Compact 是 layout/presentation preference，不是新的 `RecordingVisualStyle`；
2. 老用户缺少新 key 时必须回退 Regular；
3. Compact 只屏蔽 Regular-only 能力，不修改这些能力的保存值；
4. 复用现有 `RecordingControlAction` 与 AppKit first-click interaction；
5. 复用 `AudioLevelMeter`，不新增麦克风读取或 ASR 依赖；
6. Compact renderer 使用轻量声纹柱，不复用现有高成本背景动效；
7. Settings Preview 继续运行真实 `FloatingBarView`；
8. 用户指定颜色通过 Design Token 表达，不在组件写 raw RGB；
9. 第一版保持 `FloatingBarPanel` host 尺寸不变；Compact 高度始终为 24pt，录音态固定 180pt 宽，提示态按内容自适应宽度；
10. Compact 必须覆盖 preparing / recording / processing / recovering / done / error 全部可见 phase；
11. 所有新增用户可见文案继续提供中英文并跟随当前语言即时刷新。

## 3. 已验证的当前实现

### 3.1 RecordingVisualStyle

当前 `Sources/Type4Me/UI/AppState.swift`：

```swift
enum RecordingVisualStyle: String, CaseIterable {
    static let storageKey = "tf_visualStyle"
    static let defaultValue = Self.timeline.rawValue

    case classic
    case dual
    case timeline
    case effectless
    case hidden
}
```

这组值只描述 Regular 的视觉效果，因此不增加 `.compact`。

### 3.2 FloatingBarPresentation

当前：

```swift
struct FloatingBarPresentation: Equatable {
    var visualStyle: RecordingVisualStyle
    var showsLiveTranscript: Bool
    var enablesHoverTranscriptPreview: Bool
}
```

已有 production AppStorage + preview override seam，可以直接扩展。

### 3.3 FloatingBarView

当前实现已具备：

- `.preparing` / `.recording` → `recordingContent`；
- 中间 `recordingText`；
- 35pt Regular 控件；
- 55pt capsule 高度；
- transcript / action / mode top overlay；
- `AudioRipple` recording background；
- `FloatingBarButtonInteraction` 的 non-activating panel first click；
- 统一 `triggerRecordingAction` 与 accessibility action。

Compact 应复用 action/interaction 基础设施，但使用单独布局。

### 3.4 FloatingBarPanel

当前 Panel 是足够容纳最大 Regular bar、Transcript Popup 和 action tooltip overhang 的透明固定 host。

第一版只改变 SwiftUI 可见 capsule，不根据 Compact 动态 resize NSPanel，可以避免录音中切换 preference 时出现 panel resize/reposition flicker。

### 3.5 Design Token

当前 `Sources/Type4Me/UI/DesignSystem.swift` 已有：

```swift
TF.floatingControlLight   // 对应 #FBFBFB
TF.recordingTooltipBadge // 对应 #8A8A8A
TF.floatingBackground
TF.barWidthCompact       // 180
```

Compact 组件不再定义相同 RGB。

## 4. 新增 RecordingIndicatorStyle

建议在 Recording preferences 相邻位置新增：

```swift
enum RecordingIndicatorStyle: String, CaseIterable {
    static let storageKey = "tf_recordingIndicatorStyle"
    static let defaultValue = Self.regular.rawValue

    case regular
    case compact

    var displayName: String {
        switch self {
        case .regular:
            return L("常规", "Regular")
        case .compact:
            return L("紧凑型", "Compact")
        }
    }

    static func current(userDefaults: UserDefaults = .standard) -> Self {
        guard let raw = userDefaults.string(forKey: storageKey),
              let style = Self(rawValue: raw)
        else { return .regular }
        return style
    }
}
```

不做 migration。旧用户缺少 `tf_recordingIndicatorStyle` 时自然回退 `.regular`。

不要重写：

```text
tf_visualStyle
tf_showLiveTranscript
tf_hoverTranscriptPreview
```

## 5. FloatingBarPresentation 扩展

修改为：

```swift
struct FloatingBarPresentation: Equatable {
    var indicatorStyle: RecordingIndicatorStyle
    var visualStyle: RecordingVisualStyle
    var showsLiveTranscript: Bool
    var enablesHoverTranscriptPreview: Bool
}
```

`FloatingBarView` 增加：

```swift
@AppStorage(RecordingIndicatorStyle.storageKey)
private var indicatorStyle = RecordingIndicatorStyle.defaultValue
```

并统一解析：

```swift
private var effectiveIndicatorStyle: RecordingIndicatorStyle {
    presentationOverride?.indicatorStyle
        ?? RecordingIndicatorStyle(rawValue: indicatorStyle)
        ?? .regular
}
```

## 6. Capability Resolution

Compact 不能通过修改 stored settings 实现。

建议：

```swift
private var usesCompactPresentation: Bool {
    effectiveIndicatorStyle == .compact
        && state.barPhase != .hidden
}
```

Regular-only capability：

```swift
private var effectiveShowsLiveTranscript: Bool {
    guard effectiveIndicatorStyle == .regular else { return false }
    return presentationOverride?.showsLiveTranscript ?? showLiveTranscript
}

private var effectiveHoverTranscriptPreview: Bool {
    guard effectiveIndicatorStyle == .regular else { return false }
    return presentationOverride?.enablesHoverTranscriptPreview ?? hoverTranscriptPreview
}
```

`effectiveRecordingVisualStyle` 仍解析 stored / override style，但只有 Regular recording path 使用。

## 7. Render Visibility

当前 `shouldRenderCapsule` 依赖 `recordingVisualStyle.showsRecordingPanel`。如果 Regular 保存为 `.hidden`，直接沿用会错误隐藏 Compact。

建议：

```swift
private var shouldRenderCapsule: Bool {
    guard state.barPhase != .hidden else { return false }

    if usesCompactPresentation {
        return true
    }

    return recordingVisualStyle.showsRecordingPanel
}
```

实现阶段需要补充 post-recording feedback 的回归，确保 `.hidden` 只影响 Regular recording presentation，不吞掉必要的 Done / Error 反馈。

## 8. Capsule Geometry

当前 capsule 固定使用 `TF.barHeight`。Compact 高度统一为 24pt：

```swift
private var capsuleHeight: CGFloat {
    usesCompactPresentation ? TF.compactIndicatorHeight : TF.barHeight
}
```

宽度需要按 phase 分流，而不是 Compact 一律返回 180：

```swift
private var compactCapsuleWidth: CGFloat {
    switch state.barPhase {
    case .preparing, .recording:
        return TF.compactIndicatorWidth
    case .processing, .recovering, .done, .error:
        return min(compactStatusIntrinsicWidth, TF.compactStatusMaxWidth)
    case .hidden:
        return 0
    }
}
```

其中：

```text
compactStatusIntrinsicWidth =
    semanticGlyphWidth
  + glyphTextSpacing
  + measuredStatusTextWidth
  + optionalActionWidth
  + optionalActionSpacing
  + horizontalInsets × 2
```

提示态**不设置 180pt 最小宽度**，也不使用 high-water mark；文案从长变短时 capsule 必须能够同步收窄。只有自然宽度超过 `TF.compactStatusMaxWidth` 时才 clamp 并对文字做 tail truncation。

建议 `TF.compactStatusMaxWidth` 直接复用现有最大 Floating Bar 宽度能力（例如以 `TF.barWidth` 为上限或建立其语义别名），避免引入新的随意硬编码值。

Compact 仍不使用 Regular transcript width measurement，也不参与 `recordingPeakWidth`、Regular processing width 或 Regular feedback width 计算；提示态使用独立的 status-content measurement。

## 9. Design Token 扩展

建议在 `TF` 增加：

```swift
static let compactIndicatorWidth: CGFloat = barWidthCompact
static let compactIndicatorHeight: CGFloat = 24
static let compactIndicatorControlVisualSize: CGFloat = 15
static let compactIndicatorWaveBarWidth: CGFloat = 2
static let compactIndicatorWaveMinHeight: CGFloat = 2
static let compactIndicatorWaveMaxHeight: CGFloat = 18
static let compactStatusMaxWidth: CGFloat = barWidth
```

颜色用语义别名，而不是重写 RGB：

```swift
static let compactIndicatorActive = floatingControlLight
static let compactIndicatorInactive = recordingTooltipBadge
```

这样 Compact View 只引用语义 token。

## 10. Compact Content Router

不要缩放或复用 Regular `recordingContent` / `processingContent` / `doneContent` / `errorContent`。Compact 需要一个覆盖全部 phase 的内容路由：

```swift
@ViewBuilder
private var phaseContent: some View {
    if usesCompactPresentation {
        compactPhaseContent
    } else {
        regularPhaseContent
    }
}

@ViewBuilder
private var compactPhaseContent: some View {
    switch state.barPhase {
    case .preparing, .recording:
        compactRecordingContent
    case .processing:
        compactStatusContent(.processing, text: state.effectiveProcessingLabel)
    case .recovering:
        compactStatusContent(.recovering, text: state.effectiveProcessingLabel)
    case .done:
        compactDoneContent
    case .error:
        compactStatusContent(.error, text: state.feedbackMessage)
    case .hidden:
        EmptyView()
    }
}
```

录音布局：

```swift
private var compactRecordingContent: some View {
    HStack(spacing: 0) {
        compactRecordingButton(.finish)

        CompactAudioIndicator(meter: state.audioLevel)
            .frame(maxWidth: .infinity)

        compactRecordingButton(.cancel)
    }
}
```

左右 edge cell 可以大于 15pt，但内部视觉控件必须为 15 × 15。Processing / Recovery / Done / Error 不显示录音按钮，而是使用 Compact status content。

## 11. Compact Button

复用：

```swift
triggerRecordingAction(_ action: RecordingControlAction)
FloatingBarButtonInteraction
```

不要创建第二套 action callback。

视觉建议：

- Finish：`TF.compactIndicatorActive` 控制面 + `TF.floatingBackground` stop glyph；
- Cancel：`TF.compactIndicatorActive` 控制面 + `TF.floatingBackground` xmark；
- 视觉 frame 15 × 15；
- interaction overlay 覆盖分配到的 edge cell，而不是只覆盖 15 × 15；
- 保留现有 accessibility label / action；
- Compact 在 hover 时正常更新 `hoveredAction`，并在按钮正上方展示操作提示气泡（完成录制、取消录制 esc）。

## 12. CompactAudioIndicator

建议新增：

```text
Sources/Type4Me/UI/FloatingBar/CompactAudioIndicator.swift
```

API：

```swift
struct CompactAudioIndicator: View {
    let meter: AudioLevelMeter
}
```

### 12.1 几何约束

```text
bar width:   2 pt
min height:  2 pt
max height: 18 pt
```

18pt 最大高度在 24pt capsule 中留下上下安全空间。

柱数量与柱间距根据 center lane 可用宽度计算，不作为持久化设置。

### 12.2 数据源

直接读取：

```swift
meter.current
```

并 clamp 到 `0...1`。

不要读取 transcript / segment，不新增 microphone capture，不依赖 `RecordingVisualStyle`。

### 12.3 动画模型

推荐 `TimelineView(.animation(...))` + `Canvas`：

```text
AudioLevelMeter.current
    ↓ clamp
lightweight smoothing
    ↓
recent level history / phased columns
    ↓
map to 2...18pt
    ↓
active / inactive token
```

静音阈值以下主要使用 inactive token，超过阈值的柱使用 active token。

阈值、平滑参数和柱间距属于实现调校参数，不暴露为 UserDefaults。

### 12.4 性能

Compact renderer 应比现有 particle style 更轻：

- 只画简单 rounded rect；
- 约 30fps 即可；
- 不把 mic level 放入 SwiftUI Observable state；
- 继续利用 `AudioLevelMeter` 高频读取不触发整棵 View invalidation 的现有设计。

## 13. Compact Top Overlay 与 Status Content

Compact 在录音阶段保留气泡提示支持：

- **模式提示**：录音准备/开始阶段（`preparing` / `recording`），在 180pt 胶囊正上方居中展示当前模式名称气泡（如 `快速模式`），2 秒后自动淡出；
- **按钮悬停提示**：鼠标悬停在左侧 Finish 按钮上方时展示 `完成录制`，悬停在右侧 Cancel 按钮上方时展示 `取消录制 esc`，提示气泡中心水平偏移精准对齐两侧按钮（偏移量为 `±(capsuleWidth / 2 - 16)`）；
- **Transcript 隔离**：Compact 不支持实时文字测量与 Transcript Popup，因此 `showTranscriptPopup` 在 Compact 阶段恒为 `false`；
- **后处理阶段无气泡**：`processing` / `recovering` / `done` / `error` 阶段无悬停气泡，纯靠 24pt 胶囊内部的紧凑状态呈现。

Compact status 建议统一为一行：

```text
[semantic glyph] [single-line status text] [optional compact action]
```

- Processing：轻量动画 glyph + `state.effectiveProcessingLabel`；
- Recovering：recovery glyph + `state.effectiveProcessingLabel`；
- Done：success / `feedbackKind` glyph + `state.feedbackMessage`；
- Error：error glyph + `state.feedbackMessage`；
- Revise Done 且存在 `latestReviseUndoTicketID`：尾部保留 compact Undo hit target；
- Mac Action success / failure / unsure：沿用 `feedbackKind` 的语义 icon/color，但使用 Compact geometry。

状态内容优先按 intrinsic width 单行完整展示；只有计算后的自然宽度超过 `TF.compactStatusMaxWidth` 时，文本才使用 `.lineLimit(1)` + tail truncation。完整状态文本写入 accessibility label。不能因为文本过长而走 Regular feedback width/height。

## 14. Background Effect 隔离

Compact 所有 phase 的基础背景都使用 `TF.floatingBackground`，通过小型 semantic glyph / tint 表达 processing、success、error 等状态，不使用 Regular 大面积背景动画。

Regular AudioRipple 条件增加 indicator style 限制：

```swift
if state.barPhase == .recording,
   effectiveIndicatorStyle == .regular,
   recordingVisualStyle.showsBackgroundEffect {
    AudioRipple(...)
}
```

Regular 的 Processing / Done 等阶段维持当前 feedback 逻辑；Compact 则不得渲染 `ProcessingProgress`、Regular error gradient 或 Regular 55pt status content。

## 15. Width Measurement 隔离

Compact 的录音态固定 180pt，因此 Regular transcript 的以下逻辑仍只在 Regular 执行：

- segment change 后 transcript `measureText`；
- `recordingPeakWidth` high-water mark；
- live transcript preference change 后重算 width；
- transcript overflow mask。

Compact 提示态另外维护**无历史峰值**的 status-content measurement：Processing / Recovering 使用 `effectiveProcessingLabel`，Done / Error 使用 `feedbackMessage`，并把 semantic glyph、可选 Undo/action 与水平内边距计入本次宽度。状态文本或 action 改变时直接重新计算当前 intrinsic width，允许宽度增大也允许缩小。

不要复用 `recordingPeakWidth`，也不要因为 Compact 提示态需要测文字而重新启用 transcript measurement。

## 16. Settings 接入

`AppearanceSettingsTab` 新增：

```swift
@AppStorage(RecordingIndicatorStyle.storageKey)
private var indicatorStyle = RecordingIndicatorStyle.defaultValue
```

presentation：

```swift
FloatingBarPresentation(
    indicatorStyle: RecordingIndicatorStyle(rawValue: indicatorStyle) ?? .regular,
    visualStyle: RecordingVisualStyle(rawValue: visualStyle) ?? .timeline,
    showsLiveTranscript: showLiveTranscript,
    enablesHoverTranscriptPreview: hoverTranscriptPreview
)
```

Recording Display card 顺序：

1. Indicator Style；
2. Visual Style；
3. Live Transcript；
4. Hover Text Preview。

Compact 时后三项 `.disabled(isCompact)`，但不写回 binding。

如增加说明文案，使用：

```swift
L("仅常规外观可用", "Available in Regular only")
```

## 17. Appearance Preview 接入

现有 `AppearancePreviewStage` 已直接运行：

```swift
FloatingBarView(
    state: demoState,
    presentationOverride: presentation
)
```

所以不新增第二套 compact preview。

需要修正当前 outer condition `presentation.visualStyle.showsRecordingPanel`：Compact 必须忽略 Regular `.hidden`。

可以抽出 presentation helper：

```swift
var showsRecordingIndicator: Bool {
    indicatorStyle == .compact || visualStyle.showsRecordingPanel
}
```

Compact Preview 继续使用 `DemoState.startAppearancePreview` 的 synthetic audio 驱动声纹。

> **注意（QA 提示）**：`DemoState` 如果进入 `.processing` / `.done` / `.error` 等相位，Compact Preview 必须继续呈现 24pt 高 Compact status，并根据当前提示内容自适应宽度。固定 180pt 的提示态或任何 55pt Regular feedback 都是回归错误。

## 18. Panel 策略

第一版保持 `FloatingBarController.panelSize` 不变。

理由：

1. Regular 仍需要最大 400pt + tooltip overhang；
2. AppKit panel 本身透明，用户只看到 SwiftUI capsule；
3. Compact 录音态固定 180 × 24；提示态在同一 host 内以 24pt 高、内容自适应宽度 bottom-center；
4. preference 在录音过程中变化时不需要 resize panel；
5. 避免重新 position 导致可见跳动。

## 19. Processing / Recovering / Done / Error

第一版必须实现 Compact 专属后处理反馈；这是 Indicator Style 一致性的组成部分，不再视为后续增强。

geometry：

```text
preparing + compact  -> 180 × 24
recording + compact  -> 180 × 24
processing + compact -> intrinsic(content), height 24
recovering + compact -> intrinsic(content), height 24
done + compact       -> intrinsic(content), height 24
error + compact      -> intrinsic(content), height 24
```

提示态宽度计算以本次内容为准，并 clamp 到 `compactStatusMaxWidth`；不设置 180pt minimum。

状态数据继续复用现有 source of truth：

- Processing：`effectiveProcessingLabel`；
- Recovering：`effectiveProcessingLabel` + existing recovery semantics；
- Done：`feedbackMessage` + `feedbackKind`；
- Error：`feedbackMessage` + `feedbackKind`；
- Revise Done：`latestReviseUndoTicketID` 决定是否显示 Compact Undo；
- Mac Action：继续用 `feedbackKind` 区分 success / failure / unsure。

关键约束是**只复用状态语义，不复用 Regular renderer**。从 Recording 进入 Processing、Done 或 Error 时 capsule 高度保持 24pt、整体布局风格不变，但宽度应从录音态的 180pt 过渡到当前提示内容的 intrinsic width；状态文案变化后还要能够继续向两侧扩展或收窄。

## 20. 文件变更规划

预计修改：

```text
Sources/Type4Me/UI/AppState.swift
Sources/Type4Me/UI/DesignSystem.swift
Sources/Type4Me/UI/FloatingBar/FloatingBarView.swift
Sources/Type4Me/UI/Settings/AppearanceSettingsTab.swift
Sources/Type4Me/UI/Settings/AppearancePreviewStage.swift
Tests/Type4MeTests/AppearancePreviewTests.swift
```

预计新增：

```text
Sources/Type4Me/UI/FloatingBar/CompactAudioIndicator.swift
```

第一版预计不修改 `FloatingBarPanel.swift`。

## 21. 单元测试

### 21.1 Preference

覆盖：

- missing storage → `.regular`；
- valid regular / compact raw values；
- invalid raw value → `.regular`；
- zh/en display name。

### 21.2 Presentation

覆盖：

- Regular 保留 visual style / live / hover；
- Compact 强制 live transcript effective false；
- Compact 强制 hover effective false；
- Compact 不受 Regular `.hidden` 影响；
- nil override 继续使用 AppStorage fallback。

如果 effective resolution 仍是 private computed property，建议抽出小型纯 helper 后测试，而不是依赖 pixel snapshot。

### 21.3 Geometry 与 Phase Coverage

覆盖 contract：

```text
preparing / recording -> 180 × 24
processing / recovering / done / error -> height 24, width = current intrinsic content width clamped to max
control visual -> 15 × 15
wave width -> 2
wave min -> 2
wave max -> 18
```

额外覆盖：

- 短提示的实际宽度可小于 180pt；
- 长提示在 max width 内自然增长；
- 内容由长变短时宽度能够回缩，不保留 high-water mark；
- 超过 max width 才发生 tail truncation；
- Compact phase resolution 永远不调用 Regular `feedbackWidth` / 55pt capsule geometry。

### 21.4 Existing Regression

`RecordingVisualStyle.allCases` 不应因为 Compact 增加新 case；现有 DemoState lifecycle、formatting、Appearance navigation tests 继续通过。

## 22. 手工验收

### Settings / Preview

- Indicator Style 中英文正确；
- Regular 下三项 regular-only setting 可用；
- Compact 下三项 disabled；
- 来回切换不改变保存值；
- Compact Preview 录音态固定 180 × 24，提示态根据当前内容自适应宽度且高度保持 24pt；
- synthetic audio 驱动波形；
- Compact 不显示 transcript / transcript hover popup，但录音阶段支持模式提示与按钮悬停提示；
- Regular visual style = hidden 后切 Compact，Compact 仍显示。

### Production Floating Bar

- Compact 录音尺寸固定；
- ASR partial/final 到达不改变 width；
- Finish / Cancel first click 在非激活 app 中生效；
- finish 后 Processing / Recovering / Done / Error 全部继续保持 24pt 高 Compact，并根据当前提示内容自适应宽度；
- processing 显示当前 `effectiveProcessingLabel`，包括润色、校准、改口等；
- Done / Error 使用 Compact icon + `feedbackMessage`；
- Revise recording 不显示 revise prompt text，而使用 compact audio indicator；Revise Done 的 Undo 仍可操作；
- Mac Action success / failure / unsure 不回退 Regular。

### Audio / Accessibility

- silence 接近 2pt；
- speech 不超过 18pt；
- 所有柱宽 2pt；
- 不出现 layout overflow；
- Finish / Cancel accessibility label 正确；
- visual 15pt 不导致 action target 失效。

## 23. 构建与回归计划

实现完成后至少：

```bash
swift test
swift build
```

重点回归：

- Existing AppearancePreviewTests；
- Settings language switch；
- all RecordingVisualStyle；
- production FloatingBarPanel；
- Quick Mode / Revise Finish / Cancel；
- Regular Live Transcript / Hover Popup；
- Compact + Regular visualStyle hidden；
- Processing / Recovery / Done / Error phase transitions。

当前文档阶段是 Markdown-only change，不强制执行 Swift build。

## 24. 实现顺序

1. 新增 `RecordingIndicatorStyle`；
2. 增加 Compact geometry / semantic tokens；
3. 扩展 `FloatingBarPresentation`；
4. 增加 effective Indicator Style / capability resolution；
5. 实现 phase-aware Compact geometry：录音态固定 180pt，提示态 intrinsic content width；
6. 新增 `CompactAudioIndicator`；
7. 复用现有 button action + AppKit interaction 实现 compact controls；
8. 屏蔽 compact top overlay、transcript measurement、AudioRipple；
9. 接入 Appearance Settings dropdown + disabled states；
10. 实现 Compact Processing / Recovering / Done / Error status content 与 Revise Undo / Mac Action feedback；
11. 修正 AppearancePreviewStage 的 Regular hidden / Compact visibility 与 full-lifecycle phase preview；
12. 添加 preference / presentation / full-phase geometry tests；
13. 手工 QA Regular 与 Compact 全生命周期；
14. `swift test`；
15. `swift build`。

## 25. 风险与缓解

### 风险 1：Compact 被混入 RecordingVisualStyle

缓解：独立 `RecordingIndicatorStyle`，保持 layout 与 effect 正交。

### 风险 2：Compact 覆盖用户旧设置

缓解：只做 effective capability gating，不写回 Live / Hover / Visual Style。

### 风险 3：Regular `.hidden` 把 Compact 隐藏

缓解：render visibility 优先看 Indicator Style。

### 风险 4：15pt 按钮难点击

缓解：区分 visual size 与 interaction cell，复用 `FloatingBarButtonInteraction`。

### 风险 5：音频动画过重

缓解：简单 rounded bars + `AudioLevelMeter`，不复制 particle renderer，不把 mic level 放入 Observable state。

### 风险 6：提示宽度抖动或过度增长

缓解：提示宽度只跟随当前 `icon + text + optional action` 的 intrinsic width，不使用 high-water mark；在内容变化时使用现有宽度动画节奏平滑过渡，并以 `compactStatusMaxWidth` 限制极长文案。只有超过 max width 才尾部截断，同时把完整 `effectiveProcessingLabel` / `feedbackMessage` 暴露给 accessibility。

### 风险 7：Preview 与 Production 分叉

缓解：Preview 继续直接运行真实 `FloatingBarView` + presentation override。

### 风险 8：颜色 token 名称语义不稳定

`recordingTooltipBadge` 数值符合 inactive color，但名称偏 Tooltip。建议建立 Compact semantic alias，由现有 token 提供实际颜色值。

## 26. 第一版技术决策汇总

| 项目 | 决策 |
|---|---|
| Preference | `RecordingIndicatorStyle.regular / compact` |
| Storage key | `tf_recordingIndicatorStyle` |
| Default | `.regular` |
| Migration | 无 |
| RecordingVisualStyle | 不增加 Compact case |
| Presentation | `FloatingBarPresentation` 增加 indicatorStyle |
| Compact phases | preparing / recording / processing / recovering / done / error |
| Compact geometry | 录音态固定 180 × 24；提示态高 24、宽度按 intrinsic content 自适应并设 max |
| Control visual | 15 × 15 |
| Wave geometry | width 2, height 2–18 |
| Wave source | existing `AudioLevelMeter` |
| Wave renderer | 独立轻量 `CompactAudioIndicator` |
| Color | Design Token，不写 raw RGB |
| Transcript / Hover | Compact effective disabled |
| Regular AudioRipple | Compact recording 不使用 |
| Mode/action hint | 录音阶段支持模式提示与按钮悬停操作提示 |
| Buttons | 复用 RecordingControlAction + AppKit interaction |
| Regular hidden value | 不影响 Compact visibility |
| Panel size | 第一版保持现有 fixed host |
| Preview | 复用真实 FloatingBarView |
| Processing / Recovery / Result | Compact 专属 status content，复用状态数据但不复用 Regular renderer |
| Build requirement for docs | 不需要；实现阶段执行 swift test + swift build |
