# Type4Me Compact 实时识别文本开发设计

> 文档类型：开发设计
> 文档状态：当前有效（已实现，持续验证）
> 设计日期：2026-08-27
> 最后校验：2026-08-30
> 实现基线：`a90f8d2`
> 产品设计：[product-design.md](product-design.md)
> 说明：本文档独立维护，不修改 `docs/features/compact-recording-indicator/` 既有设计。

## 1. 设计摘要

当前 Compact 在 `.preparing` / `.recording` 使用固定 180 × 24 capsule：左右是 Finish / Cancel，中间是 `CompactAudioIndicator`。`effectiveShowsLiveTranscript` 当前明确对 Compact 返回 `false`，Settings 也在 Compact 下隐藏 Live Transcript。

本功能让已有 `tf_showLiveTranscript` 同时作用于 Regular 与 Compact：

```text
Compact + Live Transcript Off
preparing / recording -> 180 × 24

Compact + Live Transcript On
preparing / recording -> 180 × 48
  top 24 -> CompactLiveTranscriptRow
  bottom 24 -> existing controls + waveform

processing / recovering / done / error
-> existing Compact status, height 24, intrinsic width
```

实时文字不参与 capsule width。短文本从左侧开始；超过可视宽度后，通过 deterministic negative offset 实现 follow-tail，让最新 transcript 尾部持续可见。

## 2. 核心工程原则

1. 复用 `tf_showLiveTranscript`，不新增 Compact transcript preference。
2. Compact 录音 width 继续固定 180pt。
3. 现有 24pt Compact control lane 不改几何和 action。
4. `TF.compactIndicatorHeight` 继续表示 24pt 基础高度，禁止直接改成 48。
5. 48pt 只表示 Live Transcript 开启时的 Compact recording expanded height。
6. transcript 直接读取 `state.transcriptionText`，不建立第二套 ASR state。
7. follow-tail 只改变 text offset，不改变 capsule width。
8. Compact 仍禁止 Transcript Popup。
9. Processing / Recovering / Done / Error 继续现有 Compact renderer。
10. Preview 继续复用真实 `FloatingBarView`。
11. Panel 复用当前 `FloatingBarPanelLayout` 动态尺寸机制。
12. 新尺寸、字体、fade 数值进入 `TF` token。

## 3. 当前实现基线

### 3.1 Presentation

当前：

```swift
struct FloatingBarPresentation: Equatable {
    var indicatorStyle: RecordingIndicatorStyle = .regular
    var visualStyle: RecordingVisualStyle = .siri
    var showsLiveTranscript: Bool = true
    var enablesHoverTranscriptPreview: Bool = true
    var showsTooltips: Bool = true
    var showsCancelButton: Bool = true
}
```

无需增加新字段。

### 3.2 Live Transcript gate

当前：

```swift
private var effectiveShowsLiveTranscript: Bool {
    guard effectiveIndicatorStyle == .regular else { return false }
    return presentationOverride?.showsLiveTranscript ?? showLiveTranscript
}
```

这是 Compact 无法使用 live text 的主要 capability gate。

### 3.3 Compact geometry

当前：

```swift
private var capsuleHeight: CGFloat {
    usesCompactPresentation ? TF.compactIndicatorHeight : TF.barHeight
}
```

全部 Compact phase 都是 24pt。

### 3.4 Compact recording content

当前单行结构：

```swift
HStack(spacing: 0) {
    compactRecordingButton(.finish)
    CompactAudioIndicator(meter: state.audioLevel)
    compactRecordingButton(.cancel)
}
.frame(width: TF.compactIndicatorWidth,
       height: TF.compactIndicatorHeight)
```

这部分应抽成 bottom control lane，不重新设计。

### 3.5 Settings

当前 `AppearanceSettingsTab` 把：

```text
Recording Visual
Live Transcript
Hover Text Preview
```

一起放进 `if !isCompact`，所以 Compact 下无法控制 live transcript。

### 3.6 Panel

当前 `FloatingBarView` 已计算 `FloatingBarPanelLayout`，并通过 `onPanelLayoutChange` 把 capsule 和 overlay 尺寸传给 controller。24 ↔ 48 不需要新建固定 Panel 方案。

## 4. Capability Resolution

`Live Transcript` 改为 Regular / Compact 共用：

```swift
private var effectiveShowsLiveTranscript: Bool {
    presentationOverride?.showsLiveTranscript ?? showLiveTranscript
}
```

`Hover Text Preview` 继续 Regular-only：

```swift
private var effectiveHoverTranscriptPreview: Bool {
    guard effectiveIndicatorStyle == .regular else { return false }
    return presentationOverride?.enablesHoverTranscriptPreview ?? hoverTranscriptPreview
}
```

能力矩阵：

| Capability | Regular | Compact |
|---|---:|---:|
| Live Transcript | ✅ | ✅ |
| Hover Transcript Popup | ✅ | ❌ |
| Recording Visual | ✅ | ❌ |
| Tooltips | ✅ | ✅ |
| Cancel Button | ✅ | ✅ |

`showTranscriptPopup` 已有 Compact guard，因此 inline transcript 不会误触发 Popup。

## 5. Design Token

保留现有：

```swift
TF.compactIndicatorWidth  // 180
TF.compactIndicatorHeight // 24
```

禁止把 `compactIndicatorHeight` 改成 48，因为它同时用于 control row、status phase 和 `CompactAudioIndicator`。

新增：

```swift
static let compactTranscriptLaneHeight: CGFloat = 24
static let compactTranscriptExpandedHeight: CGFloat = 48
static let compactTranscriptFontSize: CGFloat = 12
static let compactTranscriptHorizontalInset: CGFloat = 8
static let compactTranscriptLeadingFadeWidth: CGFloat = 10
```

继续复用：

```swift
TF.floatingBackground
TF.floatingBorder
TF.floatingText
```

不新增 raw color。

## 6. Phase-aware Height

新增：

```swift
private var usesCompactExpandedRecordingLayout: Bool {
    usesCompactRecordingLayout && effectiveShowsLiveTranscript
}
```

高度：

```swift
private var capsuleHeight: CGFloat {
    guard usesCompactPresentation else { return TF.barHeight }
    return usesCompactExpandedRecordingLayout
        ? TF.compactTranscriptExpandedHeight
        : TF.compactIndicatorHeight
}
```

Contract：

```text
compact preparing + live on  -> 48
compact recording + live on  -> 48
compact preparing + live off -> 24
compact recording + live off -> 24
compact processing           -> 24
compact recovering           -> 24
compact done                 -> 24
compact error                -> 24
```

`compactCapsuleWidth` 不修改：Preparing / Recording 始终 180pt。

## 7. Compact Recording Content 重构

建议把当前录音行抽成 `compactRecordingControls`：

```swift
private var compactRecordingControls: some View {
    HStack(spacing: 0) {
        compactRecordingButton(.finish)
            .frame(width: 32, height: TF.compactIndicatorHeight)

        CompactAudioIndicator(meter: state.audioLevel)
            .frame(maxWidth: .infinity,
                   maxHeight: TF.compactIndicatorHeight)

        if effectiveShowsCancelButton {
            compactRecordingButton(.cancel)
                .frame(width: 32,
                       height: TF.compactIndicatorHeight)
        } else {
            Spacer().frame(width: TF.recordingEdgeInset)
        }
    }
    .frame(width: TF.compactIndicatorWidth,
           height: TF.compactIndicatorHeight)
}
```

然后组合：

```swift
@ViewBuilder
private var compactRecordingContent: some View {
    if effectiveShowsLiveTranscript {
        VStack(spacing: 0) {
            CompactLiveTranscriptRow(text: state.transcriptionText)
            compactRecordingControls
        }
        .frame(width: TF.compactIndicatorWidth,
               height: TF.compactTranscriptExpandedHeight)
    } else {
        compactRecordingControls
    }
}
```

不改 `CompactAudioIndicator` 和 recording action callback。

## 8. CompactLiveTranscriptRow

建议新增：

```text
Type4Me/UI/FloatingBar/CompactLiveTranscriptRow.swift
```

API：

```swift
struct CompactLiveTranscriptRow: View {
    let text: String
}
```

职责：

- 12pt Medium 单行文本；
- 固定 180pt row；
- 左右 8pt inset；
- follow-tail offset；
- overflow leading fade；
- accessibility 完整 transcript。

不负责：

- 组合 ASR segments；
- preference；
- phase；
- Popup；
- buttons；
- Panel resize。

## 9. Follow-tail 算法

### 9.1 Viewport

```swift
let viewportWidth = TF.compactIndicatorWidth
    - TF.compactTranscriptHorizontalInset * 2
```

即：

```text
180 - 8 - 8 = 164pt
```

### 9.2 Text measurement

字体必须与实际渲染一致：

```swift
let compactTranscriptFont = NSFont.systemFont(
    ofSize: TF.compactTranscriptFontSize,
    weight: .medium
)
```

测量：

```swift
ceil((text as NSString).size(
    withAttributes: [.font: compactTranscriptFont]
).width)
```

不要复用 Regular 14pt `floatingBarFont`。

### 9.3 Offset helper

建议抽成 internal pure helper：

```swift
func compactTranscriptOffset(
    textWidth: CGFloat,
    viewportWidth: CGFloat
) -> CGFloat {
    -max(0, textWidth - viewportWidth)
}
```

例子：

```text
80 / 164  -> 0
164 / 164 -> 0
190 / 164 -> -26
300 / 164 -> -136
```

这同时满足：

- 短文本 leading aligned；
- 到右边界前不移动；
- overflow 后 tail 贴住右边界；
- ASR correction 让文本变短时 offset 可以自然回到 0。

### 9.4 View sketch

```swift
Text(text)
    .font(.system(size: TF.compactTranscriptFontSize,
                  weight: .medium))
    .foregroundStyle(TF.floatingText)
    .lineLimit(1)
    .fixedSize(horizontal: true, vertical: false)
    .offset(x: offset)
    .frame(width: viewportWidth, alignment: .leading)
    .clipped()
```

外层加 8pt horizontal padding，并固定 180 × 24。

## 10. Overflow Mask

只有 `textWidth > viewportWidth` 时启用 leading fade。

建议：

```text
0...10pt: transparent -> opaque
10pt...end: opaque
```

右侧始终 opaque，确保最新识别结果最清晰。

短文本不应用 fade。

## 11. ASR Partial / Correction

数据源只有：

```swift
state.transcriptionText
```

它已由 `AppState.setLiveTranscript` 统一组合 confirmed segments + partial。

Compact 不监听 segments 去改变 width，也不使用 `recordingPeakWidth`。

行为：

- append：重新测量，并在 overflow 后向左跟随；
- correction/rewrite：立即以新的 `state.transcriptionText` 为准；
- correction 后仍 overflow：重新计算最新 tail；
- correction 后回到 viewport 内：offset = 0。

### Animation

可以对纯 append 的 offset 变化使用 80–120ms ease-out。

可选优化：

```swift
newText.hasPrefix(oldText)
```

时才做动画；rewrite 直接跳到最新正确位置，避免“滚过已经被 ASR 修掉的旧文本”。

第一版 correctness 不依赖该优化。

## 12. Empty State

当 `state.transcriptionText.isEmpty`：

- row 仍占 24pt；
- 内容为空；
- 不显示 `Listening / 倾听中`；
- 不显示 Revise placeholder。

不要复用 Regular 的 `recordingDisplayText`。

## 13. Settings 修改

当前：

```swift
indicatorStyleRow
if !isCompact {
    visualStyleRow
    liveTranscriptRow
    hoverPreviewRow
}
showTooltipsRow
showCancelButtonRow
```

改为：

```swift
indicatorStyleRow
SettingsDivider()

if !isCompact {
    visualStyleRow
    SettingsDivider()
}

liveTranscriptRow

if !isCompact {
    SettingsDivider()
    hoverPreviewRow
}

SettingsDivider()
showTooltipsRow
SettingsDivider()
showCancelButtonRow
```

Regular 保持：

```text
Indicator Style
Recording Visual
Live Transcript
Hover Text Preview
Show Tooltips
Show Cancel Button
```

Compact 变为：

```text
Indicator Style
Live Transcript
Show Tooltips
Show Cancel Button
```

不迁移 `showLiveTranscript` 值。

## 14. Appearance Preview

现有 `AppearancePreviewStage` 已使用长 sample transcript，并直接运行真实 `FloatingBarView`。

理论上无需修改 Preview View 本身。

必须验收：

```text
Compact + Live On + Recording -> 180 × 48 + follow-tail
Compact + Live Off + Recording -> 180 × 24
Compact + Processing -> intrinsic width × 24
```

Preview action isolation 保持不变。

## 15. Panel Layout

当前 panel layout 以：

```swift
let capsuleSize = NSSize(width: capsuleWidth,
                         height: capsuleHeight)
```

为输入，有 overlay 时高度为：

```text
capsule height + overlay gap + overlay height
```

所以本功能只需要正确解析 `capsuleHeight`。

手工验证：

- 录音中切 Live Transcript 24 ↔ 48，bottom anchor 不漂移；
- mode hint 位于 48pt capsule 上方；
- action tooltip 仍对齐底部两个按钮；
- Finish 后 48 -> 24 resize 无明显位置跳动。

## 16. Tooltips / Cancel Button

`recordingActionHorizontalOffset` 的 Compact path 只依赖 capsule width：

```swift
capsuleWidth / 2 - 16
```

width 仍为 180，因此无需修改水平对齐算法。

`Show Cancel Button = Off` 只改变 bottom control lane；上方 transcript viewport 始终固定 164pt，不与 control chrome 耦合。

Transcript lane 不增加 hover tracker，也不触发 Popup。

## 17. Processing / Result 隔离

现有 `compactPhaseContent` routing 保持不变：

```text
preparing / recording -> compactRecordingContent
processing            -> compactStatusContent
recovering            -> compactStatusContent
done                  -> compactDoneContent
error                 -> compactStatusContent
```

Expanded height 必须只由：

```swift
usesCompactRecordingLayout && effectiveShowsLiveTranscript
```

触发。

禁止用：

```swift
usesCompactPresentation && effectiveShowsLiveTranscript
```

否则 Processing / Done 会错误保持 48pt。

## 18. Regular Regression Isolation

Regular 不应变化：

- dynamic capsule width；
- `recordingPeakWidth`；
- 14pt live text；
- Transcript Popup；
- LiquidGlassText / Orb；
- Hover Text Preview；
- Recording Visual；
- tooltip geometry。

Regular 的 segment / width logic 已经有 `!usesCompactPresentation` guard，应继续保留。

## 19. Accessibility

`CompactLiveTranscriptRow`：

- accessibility label = 完整 `text`；
- 视觉 viewport 不影响完整内容读取；
- 空 text 时可 `.accessibilityHidden(true)`；
- 不声明 editable / button trait；
- Finish / Cancel 保持现有 accessibility action 和 first-click。

## 20. 文件规划

预计修改：

```text
Type4Me/UI/DesignSystem.swift
Type4Me/UI/FloatingBar/FloatingBarView.swift
Type4Me/UI/Settings/AppearanceSettingsTab.swift
Type4MeTests/AppearancePreviewTests.swift
```

预计新增：

```text
Type4Me/UI/FloatingBar/CompactLiveTranscriptRow.swift
```

大概率无需修改：

```text
Type4Me/UI/AppState.swift
Type4Me/UI/FloatingBar/CompactAudioIndicator.swift
Type4Me/UI/Settings/AppearancePreviewStage.swift
```

## 21. 单元测试

### 21.1 Offset pure helper

```swift
XCTAssertEqual(
    compactTranscriptOffset(textWidth: 80,
                            viewportWidth: 164),
    0
)
XCTAssertEqual(
    compactTranscriptOffset(textWidth: 164,
                            viewportWidth: 164),
    0
)
XCTAssertEqual(
    compactTranscriptOffset(textWidth: 190,
                            viewportWidth: 164),
    -26
)
```

还应验证 textWidth = 0 时不会产生正 offset。

### 21.2 Geometry contract

```text
compact base height = 24
transcript lane = 24
expanded recording height = 48
recording width = 180
font = 12
horizontal inset = 8
viewport = 164
```

### 21.3 Phase resolution

覆盖：

```text
Compact + live on + recording -> 48
Compact + live off + recording -> 24
Compact + live on + processing -> 24
Regular + live on -> existing 55pt behavior
```

如果 View property private，建议抽小型 pure resolution helper，不做 pixel snapshot。

### 21.4 Capability

覆盖：

- Compact + `showsLiveTranscript=true` 不再被强制 false；
- Compact + false 不显示 transcript lane；
- Regular true/false 保持原行为；
- Compact Hover Transcript Popup 仍禁用；
- 没有新增 UserDefaults key。

## 22. Manual QA

### Settings

- Compact 下出现 Live Transcript；
- Compact 下仍不出现 Recording Visual / Hover Text Preview；
- toggle 使用原 `tf_showLiveTranscript`；
- 切回 Regular 值一致。

### Short transcript

口述：

```text
你好，这是测试
```

要求：leading aligned，offset 0，无滚动。

### Long transcript

持续口述超过 viewport：

- 到右边界后才左移；
- 最新字符始终可见；
- capsule width 仍 180；
- leading fade 仅 overflow 后出现。

### English

验证长单词、空格、标点时测量与实际 12pt Text 一致，不出现 trailing clipping。

### ASR correction

- 旧 partial 不残留；
- correction 不 resize capsule；
- 文本缩短后能回到 leading。

### Cancel hidden

- transcript viewport 不变；
- bottom controls 保持当前行为；
- Esc 仍可取消。

### Tooltips

- 48pt 时 mode hint 位置正确；
- Finish / Cancel bubble 对齐正确；
- tooltip 不遮 transcript；
- Show Tooltips Off 时隐藏。

### Finish transition

```text
180 × 48 recording
→ intrinsic × 24 processing
→ intrinsic × 24 done/error
```

全程不进入 Regular renderer。

## 23. 性能

ASR partial 更新频率远低于 `AudioLevelMeter` Canvas animation。

允许每次 `state.transcriptionText` 改变做一次 12pt NSString width measurement。

避免：

- TimelineView 驱动文字；
- 第二套高频 Observable transcript model；
- 无限 marquee animation；
- ScrollView 用户滚动状态与 ASR follow-tail 混用。

如果 profiling 后测量成为热点，再考虑 width cache，第一版不提前复杂化。

## 24. 为什么不优先使用 horizontal ScrollView

`ScrollViewReader + scrollTo(end)` 看似简单，但在以下场景更难稳定：

- 首次从未溢出切到溢出；
- ASR partial correction；
- 文本变短后需要回到 leading；
- panel 录音中 resize；
- 禁止用户手动把视口留在旧位置。

本功能的目标不是“可浏览的横向文本”，而是 deterministic follow-tail，因此固定 viewport + text width + offset 更直接。

## 25. 风险与缓解

### 风险 1：直接改 `compactIndicatorHeight = 48`

会误伤 status / waveform。

缓解：保留 24，新增 expanded token。

### 风险 2：复用 Regular `recordingPeakWidth`

会把固定 width Compact 与动态 width Regular 混在一起。

缓解：Compact 只计算 text offset。

### 风险 3：partial 高频更新造成抖动

缓解：viewport 内 offset 恒 0；overflow 后只移动必要距离，动画保持短小。

### 风险 4：已有 Compact 用户默认变成 48pt

这是复用既有 Live Transcript preference 的预期语义变化。

用户关闭 Live Transcript 后立即恢复 180 × 24。

### 风险 5：无 realtime partial 时上层为空

第一版接受空白 lane，不伪造 placeholder，也不动态改变高度。

### 风险 6：48 -> 24 transition 跳动

复用当前动态 Panel layout 和现有 critically damped capsule resize，重点做 bottom-anchor QA。

## 26. 实现顺序

1. 增加 transcript geometry / typography token；
2. 允许 Compact 解析 `effectiveShowsLiveTranscript`；
3. 增加 expanded recording height resolution；
4. 抽出 `compactRecordingControls`；
5. 新增 `CompactLiveTranscriptRow`；
6. 实现 text measurement + follow-tail offset；
7. 增加 overflow leading fade；
8. 调整 Settings Compact 项；
9. 添加 offset / geometry / capability tests；
10. 验证 Appearance Preview；
11. 手工 QA 中英文、ASR correction、tooltips、Cancel hidden；
12. `swift test`；
13. `swift build`。

## 27. 技术决策汇总

| 项目 | 决策 |
|---|---|
| Preference | 复用 `tf_showLiveTranscript` |
| New storage | 无 |
| Live On recording | 180 × 48 |
| Live Off recording | 180 × 24 |
| Status phases | 继续 24pt Compact |
| Base height token | 保持 24 |
| Expanded height | 新增 48 |
| Transcript component | `CompactLiveTranscriptRow` |
| Font | 12pt Medium |
| Color | `TF.floatingText` |
| Insets | 8pt horizontal |
| Viewport | 164pt |
| Width | 固定 180 |
| Follow-tail | deterministic negative offset |
| Offset | `-max(0, textWidth - viewportWidth)` |
| Left fade | overflow 时约 10pt |
| Right fade | 无 |
| ASR source | `state.transcriptionText` |
| Correction | 跟随最新 source of truth |
| Transcript Popup | Compact 禁用 |
| Tooltips | 保持现状 |
| Cancel hidden | 不影响 transcript viewport |
| Panel | 复用 `FloatingBarPanelLayout` |
| Preview | 复用真实 `FloatingBarView` |
| Existing Compact docs | 不修改 |
