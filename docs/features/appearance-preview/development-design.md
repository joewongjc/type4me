# Type4Me 外观预览开发设计

> 分支：`feat/appearance-preview`
> 文档类型：开发设计
> 文档状态：设计中
> 设计日期：2026-08-25
> 对应产品设计：`docs/features/appearance-preview/product-design.md`

## 1. 设计摘要

本功能在 Settings Hub 中新增 `Appearance` 二级页面，把当前 `GeneralSettingsTab` 中六个具有直接视觉或文本输出反馈的设置迁移到该页面，并在页面顶部提供统一 `AppearancePreviewStage`。

实现重点不是重新绘制一个“像 Floating Bar 的 Demo”，而是让设置页运行真实 `FloatingBarView` 和真实 `TextOutputFormatter`，只替换它们的数据来源：录音 UI 使用可控的 Demo State 与合成 `AudioLevelMeter`，文本输出使用固定 sample 和显式 `TextOutputFormattingOptions`。

当前代码已经具备主要基础：

- `FloatingBarView<S: FloatingBarState>` 已把运行状态抽象成协议；
- `AudioLevelMeter` 只是一个可写的轻量 level 容器，可直接使用合成数值；
- `Sources/Type4Me/UI/Setup/DemoState.swift` 已实现 `FloatingBarState`、合成音量和 Floating Bar 演示循环；
- `FloatingBarView` 的生产直接构造点目前集中在 `FloatingBarPanel`；
- `TextOutputFormatter.format(_:options:)` 是纯格式化入口，支持显式 spacing、quotes 和 punctuation options。

因此本功能不需要启动真实录音、ASR 或建立第二套渲染实现。

## 2. 核心工程原则

1. Preview 复用真实 View，不复制真实 View；
2. Preview 模拟状态，不模拟最终渲染；
3. 现有 UserDefaults storage key 不改变；
4. 页面迁移只改变设置入口位置，不改变设置语义；
5. `FloatingBarView` 的生产行为必须保持向后兼容；
6. Preview 不依赖麦克风、ASR、网络、剪贴板或文本注入；
7. 页面离开后必须停止合成 audio timer / task；
8. Preview 的文本格式化必须显式传 options，不能重新实现格式规则；
9. 新增 UI 文案必须同时提供中文和英文；
10. 设计要允许未来把更多 appearance parameters 注入 Preview Stage。

## 3. 当前实现与改造点

### 3.1 Settings 导航

`Sources/Type4Me/UI/Settings/SettingsView.swift` 当前：

- `SettingsTab` 包含 `.preferences`, `.models`, `.modes`, `.about` 等；
- `settingsSubtabs` 负责 Settings Hub 的二级导航；
- `.preferences` 映射到 `GeneralSettingsTab(showsHeader: false)`；
- Settings 窗口最小宽度为 900pt。

新增 `.appearance` 后，需要同步更新所有 exhaustive switch，不能只修改 picker 数组。

### 3.2 GeneralSettingsTab

当前六项设置由 `GeneralSettingsTab` 直接持有：

```text
RecordingVisualStyle.storageKey
LiveTranscriptDisplayPreference.storageKey
tf_hoverTranscriptPreview
tf_stripTrailingPunctuation
CJKSpacingMode.storageKey
CornerQuotePreference.storageKey
```

本功能把对应的 `@AppStorage` 和 row builder 移到新的 `AppearanceSettingsTab`。

Storage key 不变，因此不需要 migration。

### 3.3 FloatingBarView

`FloatingBarView` 已从 `FloatingBarState` 获取：

- phase；
- transcript segments；
- synthetic-compatible `AudioLevelMeter`；
- mode；
- processing/feedback state。

但以下 presentation preferences 当前由 View 内部的 `@AppStorage` 隐式读取：

```swift
@AppStorage(LiveTranscriptDisplayPreference.storageKey)
private var showLiveTranscript

@AppStorage("tf_hoverTranscriptPreview")
private var hoverTranscriptPreview

@AppStorage(RecordingVisualStyle.storageKey)
private var visualStyle
```

为了让 Preview Stage 成为长期可扩展基础设施，建议增加一个轻量 presentation override，而不是让 Preview 只能依赖全局 UserDefaults 的隐藏读取。

### 3.4 DemoState

现有 `DemoState` 已经：

- conform `FloatingBarState`；
- 使用 `AudioLevelMeter`；
- 每 50ms 更新合成 audio level；
- 可以控制 recording / processing / done / hidden；
- 不使用真实录音和 ASR。

当前仓库搜索没有找到它的其他直接引用，因此它适合作为本次 Preview state 的基础，而不是再复制一个几乎相同的协议实现。

### 3.5 TextOutputFormatter

`TextOutputFormatter` 已支持：

```swift
TextOutputFormatter.format(text, options: options)
```

以及：

```swift
TextOutputFormattingOptions(
    cjkSpacingMode: ...,
    usesCornerQuotes: ...,
    trailingPunctuationMode: ...
)
```

Appearance Preview 直接使用这个入口即可覆盖三类文本设置。

## 4. 文件变更规划

### 4.1 新增文件

```text
Sources/Type4Me/UI/Settings/AppearanceSettingsTab.swift
Sources/Type4Me/UI/Settings/AppearancePreviewStage.swift
Tests/Type4MeTests/AppearancePreviewTests.swift
```

测试文件名可根据最终测试职责拆分；第一版保持一个聚合文件即可。

### 4.2 修改文件

```text
Sources/Type4Me/UI/Settings/SettingsView.swift
Sources/Type4Me/UI/Settings/GeneralSettingsTab.swift
Sources/Type4Me/UI/FloatingBar/FloatingBarView.swift
Sources/Type4Me/UI/Setup/DemoState.swift
```

如果实现阶段发现 `DemoState` 被其他未被静态 token search 捕获的入口使用，应保持现有 public behavior，再增加可控 preview API，不直接删除原 demo loop。

## 5. SettingsTab.appearance

在 `SettingsTab` 新增：

```swift
case appearance
```

建议显示信息：

```swift
case .appearance:
    return L("外观", "Appearance")
```

Subtitle：

```swift
case .appearance:
    return L("录音显示与文本输出", "Recording display & text output")
```

Icon 建议使用系统 symbol，例如：

```swift
"paintbrush"
```

最终 symbol 以现有 Settings 视觉密度为准，不引入自定义 asset。

## 6. Settings Hub 集成

无订阅版本：

```swift
[.preferences, .appearance, .models, .modes, .about]
```

条件版本继续遵循现有产品规则，例如不显示 Models 时：

```swift
[.preferences, .appearance, .modes, .about]
```

同时修改：

- `content` 中 Settings Hub case；
- `settingsHubContent`；
- `displayName`；
- `subtitle`；
- `icon`；
- 所有 `SettingsTab` exhaustive switch。

Appearance 使用现有 `settingsScrollableContent`，不新增左右 SplitView。

## 7. AppearanceSettingsTab

建议结构：

```swift
struct AppearanceSettingsTab: View, SettingsCardHelpers {
    @AppStorage(RecordingVisualStyle.storageKey)
    private var visualStyle = RecordingVisualStyle.defaultValue

    @AppStorage(LiveTranscriptDisplayPreference.storageKey)
    private var showLiveTranscript = LiveTranscriptDisplayPreference.defaultValue

    @AppStorage("tf_hoverTranscriptPreview")
    private var hoverTranscriptPreview = true

    @AppStorage("tf_stripTrailingPunctuation")
    private var stripTrailingPunctuation = "off"

    @AppStorage(CJKSpacingMode.storageKey)
    private var cjkSpacingMode = CJKSpacingMode.defaultValue

    @AppStorage(CornerQuotePreference.storageKey)
    private var useCornerQuotes = CornerQuotePreference.defaultValue
}
```

Body：

```text
AppearancePreviewStage
16pt spacing
Recording Display card
16pt spacing
Text Output card
```

### 7.1 Recording Display card

按顺序：

1. Visual Style；
2. Live Transcript；
3. Hover Text Preview。

### 7.2 Text Output card

按顺序：

1. Strip Trailing Punctuation；
2. Pangu Spacing；
3. Corner Quotes。

Row 文案与选项尽量直接从 `GeneralSettingsTab` 搬移，避免迁移过程中无关 copy change 扩大 review 范围。

## 8. GeneralSettingsTab 收缩

从 `GeneralSettingsTab` 删除六个 Appearance setting 的：

- `@AppStorage` property；
- row builder；
- card 中 divider / row insertion。

迁移后推荐保持：

### Recording

- Microphone；
- Lower System Volume；
- Mic Keep-Alive；
- Allow Cross-Mode Finish。

### Speech Recognition

- Start Sound；
- Alert Output。

其他 Revise、System Integration、Permissions、Advanced 不变。

本次不趁机重命名这些 card 或大规模调整 General UI，避免把信息架构迁移与视觉重构混在一个 PR。

## 9. FloatingBar presentation 注入

### 9.1 问题

Preview Stage 如果直接创建：

```swift
FloatingBarView(state: demoState)
```

当前 View 会读取全局 `@AppStorage`。这在第一版表面上可以工作，因为 Appearance 设置本身也是 AppStorage，但它会继续把真实渲染组件绑定到隐藏的全局来源，未来预览 hypothetical state、测试、对比主题或暂存配置会越来越困难。

### 9.2 推荐方案：可选 override

第一版采用最小侵入方式，增加：

```swift
struct FloatingBarPresentation: Equatable {
    var visualStyle: RecordingVisualStyle
    var showsLiveTranscript: Bool
    var enablesHoverTranscriptPreview: Bool
}
```

`FloatingBarView` 保留现有 `@AppStorage`，并增加：

```swift
let presentationOverride: FloatingBarPresentation?

init(
    state: S,
    presentationOverride: FloatingBarPresentation? = nil
) {
    self.state = state
    self.presentationOverride = presentationOverride
}
```

内部统一使用 effective values：

```swift
private var effectiveVisualStyle: RecordingVisualStyle {
    presentationOverride?.visualStyle
        ?? RecordingVisualStyle(rawValue: visualStyle)
        ?? .timeline
}

private var effectiveShowsLiveTranscript: Bool {
    presentationOverride?.showsLiveTranscript ?? showLiveTranscript
}

private var effectiveHoverPreview: Bool {
    presentationOverride?.enablesHoverTranscriptPreview ?? hoverTranscriptPreview
}
```

然后把所有 rendering 判断改为使用 effective properties。

### 9.3 生产兼容性

`FloatingBarPanel` 仍可保持：

```swift
FloatingBarView<AppState>(state: state)
```

即 production 不传 override，行为继续完全由现有 UserDefaults 驱动。

Appearance Preview 显式传入页面当前值：

```swift
FloatingBarView(
    state: demoState,
    presentationOverride: previewPresentation
)
```

这使 Preview 的依赖清晰，同时把生产调用点改动控制到最小。

### 9.4 为什么第一版不彻底移除 @AppStorage

更纯粹的架构是让 FloatingBarView 完全只接受 presentation config，再由 production wrapper 负责观察 AppStorage。

但这会扩大当前 PR 的行为变化和生命周期风险。第一版先增加 override seam；如果未来 Appearance 参数明显增加，再单独把 production preference adapter 抽出来。

## 10. DemoState 泛化

### 10.1 目标

Appearance Preview 需要保持在稳定 `.recording` 状态，不能沿用当前自动：

```text
recording → processing → done → hidden → repeat
```

否则用户刚把鼠标移上去测试 hover，状态可能已经切走。

### 10.2 推荐改造

保留当前 `startQuickModeDemo()`，新增一个可控入口：

```swift
func startAppearancePreview(sampleText: String) {
    stop()
    segments = [
        TranscriptionSegment(text: sampleText, isConfirmed: true)
    ]
    recordingStartDate = Date()
    barPhase = .recording
    startAudioSimulation()
}
```

`stop()` 继续作为统一 teardown。

这样 onboarding/demo 现有循环语义不会被删除，Appearance 页面也不复制：

- `FloatingBarState` boilerplate；
- AudioLevelMeter；
- audio timer；
- cleanup。

如果实现时确认 `DemoState` 应承担更通用职责，可以后续 rename 为 `FloatingBarDemoState`；第一版不把 rename 作为必要条件，减少 diff。

### 10.3 合成音量

继续使用现有：

```swift
AudioLevelMeter.current
```

不读取 `AVAudioEngine` 或 microphone。

现有随机范围足以驱动 three visual styles；如果视觉 QA 发现随机跳动过于抖动，可以把 Preview 模式改成确定性的正弦 / composite curve，以便 screenshot 和 UI test 更稳定。

第一版优先保持简单，后续再决定是否 deterministic。

## 11. AppearancePreviewStage

建议 API：

```swift
struct AppearancePreviewStage: View {
    let presentation: FloatingBarPresentation
    let formattingOptions: TextOutputFormattingOptions
}
```

内部：

```swift
@State private var demoState = DemoState()
```

生命周期：

```swift
.task {
    demoState.startAppearancePreview(sampleText: Self.floatingBarSample)
}
.onDisappear {
    demoState.stop()
}
```

如果 `.task` 会因依赖变化频繁重启，应把启动条件限制为 view lifecycle，而不是每个 setting change。

### 11.1 预览容器尺寸

Floating Bar 真实最大 capsule width 约 400pt，并且 Transcript Popup 位于 bar 上方。

Stage 需要给真实 View 足够高度和宽度，不能只给 50pt 高的 bar frame，否则 popup 会被 layout clip。

建议 Preview 的 recording canvas 独占一个明确高度区域，并让 `FloatingBarView` 自己保持 bottom alignment。

不要改变 `TF.barWidth` 或 Transcript Popup width 来“适配设置页”，否则预览不再代表真实产品。

### 11.2 Hidden style

当：

```swift
presentation.visualStyle.showsRecordingPanel == false
```

真实 `FloatingBarView` 应继续渲染为空。

Stage 在其外层显示 localized empty-state helper：

```swift
L(
    "录音时不显示悬浮条",
    "The floating bar is hidden while recording."
)
```

不要让 `FloatingBarView` 为 Preview 特判 hidden。

## 12. Preview sample 设计

Floating Bar hover popup 只有文本溢出时才出现，因此 Floating Bar sample 需要足够长。

建议使用比文本格式 sample 更长的固定字符串，例如：

```text
我正在使用Type4Me测试一段足够长的实时识别文本，方便直接预览悬停窗口和录音动效。
```

英文 UI 可以通过 `L()` 提供对应长文本，但无论语言都必须超过真实 overflow threshold。

文本输出 sample 固定使用：

```text
我刚刚在MacBook上测试Type4Me 2.1，“这个效果很好”。
```

两者职责不同：

- Floating Bar sample 保证交互条件；
- formatting sample 保证规则差异明显。

## 13. 文本格式化 Preview

AppearanceSettingsTab 从 AppStorage raw value 构造显式 options：

```swift
private var formattingOptions: TextOutputFormattingOptions {
    TextOutputFormattingOptions(
        cjkSpacingMode: CJKSpacingMode(rawValue: cjkSpacingMode) ?? .pangu,
        usesCornerQuotes: useCornerQuotes,
        trailingPunctuationMode:
            TrailingPunctuationMode(rawValue: stripTrailingPunctuation) ?? .off
    )
}
```

输出：

```swift
let formatted = TextOutputFormatter.format(
    Self.formattingSample,
    options: formattingOptions
)
```

不要调用只读取全局 UserDefaults 的 convenience API：

```swift
TextOutputFormatter.format(text)
```

显式 options 更容易测试，也保证 Preview 的依赖与 UI bindings 一致。

## 14. Preview 与实际设置的更新链路

```text
Settings control
      ↓
@AppStorage existing key
      ↓
AppearanceSettingsTab recompute
      ├── FloatingBarPresentation
      │        ↓
      │  FloatingBarView override
      │
      └── TextOutputFormattingOptions
               ↓
         TextOutputFormatter
```

因此：

- Preview 即时更新；
- preference 同时即时保存；
- 后续真实 Floating Bar 继续从同一个 existing key 读取；
- 没有第二套持久化 state。

## 15. Hover 交互

不要在 AppearancePreviewStage 自己监听 hover 来伪造 Popup。

真实路径继续是：

```text
FloatingBarHoverTracker
      ↓
isTranscriptHoverActive
      ↓
showTranscriptPopup
      ↓
TranscriptPopup
```

Preview 只负责提供：

- `.recording` phase；
- long non-empty segments；
- `enablesHoverTranscriptPreview` setting。

这可以真正验证 hover tracker、overflow calculation、350ms exit delay 和 Popup hover retention。

## 16. Finish / Cancel 控件

真实 Floating Bar 的 finish/cancel button 仍然会调用：

```swift
state.performRecordingControlAction(...)
```

在 Appearance preview 中点击这些控件不应结束整个 Preview 体验。

推荐 `startAppearancePreview` 模式下让 DemoState 的 action handler：

- 不触发真实业务；
- 可以短暂展示 processing/done 后自动恢复 recording，或直接 no-op。

第一版推荐 **no-op**，因为页面目的不是演示录音完整生命周期，而是保持一个稳定可配置的 recording canvas。

为了不改变 `startQuickModeDemo` 的现有 action behavior，可在 DemoState 内记录当前 demo mode：

```swift
enum DemoMode {
    case quickLoop
    case appearancePreview
}
```

然后仅在 `.appearancePreview` 时忽略 finish/cancel。

如果最终认为不可点击的按钮会造成误导，可以在 Preview 外层用 `.allowsHitTesting` 精细限制左右 action control，但不能因此破坏文本 hover。优先通过 state action no-op 保留真实 hover/hit-testing 结构。

## 17. 生命周期与资源清理

`DemoState.stop()` 必须在以下场景执行：

- Appearance page disappear；
- Settings window content unmount；
- Preview State deinit 可作为兜底，但不能只依赖 deinit。

需要验证：

- `demoTask` cancelled；
- `audioTimer.invalidate()`；
- `audioLevel.current = 0`；
- bar state reset；
- 不残留 Timer 持有 Settings View。

## 18. Storage 与迁移

本功能不新增替代 key，也不 rename key。

| 设置 | Existing storage |
|---|---|
| Visual Style | `RecordingVisualStyle.storageKey` |
| Live Transcript | `LiveTranscriptDisplayPreference.storageKey` |
| Hover Preview | `tf_hoverTranscriptPreview` |
| Trailing Punctuation | `tf_stripTrailingPunctuation` |
| Pangu Spacing | `CJKSpacingMode.storageKey` |
| Corner Quotes | `CornerQuotePreference.storageKey` |

因此：

- 不需要 `UserDefaults` migration；
- 不需要 version marker；
- 不需要把旧值 copy 到新 key；
- General → Appearance 只是 UI ownership 迁移。

## 19. 本地化

新增所有用户可见文案使用 `L(zh, en)`。

至少包括：

- Appearance；
- Recording Display；
- Text Output；
- Recognized Speech；
- Preview helper；
- hidden bar helper。

Appearance Preview 如果持有语言相关 sample，必须在 `tf_language` 变化后重新计算可见文本。

FloatingBarView 自身已经观察语言用于 mode name；新的 Preview 不能缓存 launch-time localized String。

## 20. 单元测试

建议新增 `AppearancePreviewTests.swift`，优先测试纯逻辑，不做脆弱 pixel snapshot。

### 20.1 Presentation override

如果把 effective resolution 提取成可测试 helper，覆盖：

- override visual style 优先于 stored raw；
- override live transcript 优先；
- override hover preference 优先；
- nil override 保持 existing stored semantics；
- invalid raw visual style 回退 `.timeline`。

### 20.2 Formatting options

使用固定 sample 覆盖：

- pangu 开启时 CJK/Latin spacing 可见；
- remove 模式移除边界空格；
- corner quotes 转换；
- punctuation period/all/off；
- 多个选项组合后的输出与 `TextOutputFormatter` 一致。

不要重新测试 `TextOutputFormatter` 的全部 regex；Appearance tests 只验证 wiring 和代表性组合。

### 20.3 Demo lifecycle

如果 Timer/Task 结构容易测试，覆盖：

- `startAppearancePreview` 设置 `.recording`；
- segments 非空；
- `stop()` 回到 `.hidden` 并清空 state；
- appearance mode action 不进入真实业务路径。

## 21. UI / 手工验收

### Navigation

- Appearance 正确出现在 Settings Hub；
- member / non-member 条件分支不破坏 tab 列表；
- 从 Appearance 切到其他 Settings tab 正常。

### Recording preview

- classic / dual / timeline 动起来；
- effectless 有 bar 无效果；
- hidden 无 bar且显示 helper；
- live transcript off 显示 Listening；
- live transcript on 显示 long sample。

### Hover preview

- enabled + hover → popup；
- disabled + hover → no popup；
- 鼠标移动到 popup 不闪退；
- leave delay 与真实 Floating Bar 一致。

### Text preview

- punctuation 3 modes；
- Pangu 3 modes；
- quotes 2 modes；
- 组合切换无 stale output。

### Lifecycle

- 打开 Appearance 不触发麦克风 permission；
- 切走后没有继续更新 preview audio；
- 关闭 Settings 后没有 timer leak。

### Localization

- zh/en 页面标题和 Section；
- live transcript off 的 Listening；
- hidden helper；
- raw/formatted labels。

## 22. 构建与回归计划

实现 PR 完成后至少：

```bash
swift test
swift build
```

重点回归：

- Settings Hub 所有二级 tab；
- GeneralSettingsTab；
- production FloatingBarPanel；
- live transcript on/off；
- hover transcript popup；
- all RecordingVisualStyle；
- TextOutputFormatter existing tests；
- Settings language switch。

当前设计文档阶段不要求为了 Markdown 变更执行 build。

## 23. 实现顺序

1. 新增 `SettingsTab.appearance` 并接入 Settings Hub；
2. 新增 `AppearanceSettingsTab`；
3. 把六个 existing rows 从 General 搬入 Appearance，storage key 不变；
4. 增加 `FloatingBarPresentation` + optional override；
5. 扩展 `DemoState`，增加稳定的 Appearance preview mode；
6. 新增 `AppearancePreviewStage`，运行真实 FloatingBarView；
7. 接入 raw/formatted text preview；
8. 增加 unit tests；
9. 手工验证 hover、hidden、live transcript 和所有 text-format combinations；
10. `swift test` + `swift build`；
11. Review 后再决定是否增加 sticky/highlight 等增强。

## 24. 风险与缓解

### 风险 1：Preview 与 production 渲染漂移

缓解：直接复用 `FloatingBarView`、`AudioRipple`、`TranscriptPopup` 和 `TextOutputFormatter`，不复制视觉实现。

### 风险 2：FloatingBarView override 改坏真实浮动栏

缓解：override 默认为 nil，`FloatingBarPanel` 生产调用保持原 constructor semantics；新增测试覆盖 nil fallback。

### 风险 3：Preview hover 永远触发不了

原因可能是 sample 不够长，真实逻辑只有 overflow 时才显示 Popup。

缓解：固定使用经过验证足够长的 sample，并以真实 `TF.barWidth` 做手工验收。

### 风险 4：Demo Timer 泄漏

缓解：复用 `stop()`，在 View disappear 明确调用；不依赖隐式 deinit。

### 风险 5：Settings tab 增加后横向 picker 过宽

900pt 最小窗口下需要实际验证五个二级 tab 的宽度。若出现拥挤，优先压缩 picker 的 horizontal padding，而不是回退双栏或把 Appearance 提升为 Sidebar 一级入口。

### 风险 6：迁移设置时意外改变 defaults

缓解：原样复用 existing key、default constant 和 option raw values；不创建新 storage。

### 风险 7：DemoState 未来还有其他演示用途

缓解：保留 `startQuickModeDemo()`；Appearance 增加独立 mode/entry，不删除现有循环 API。

## 25. 可选后续重构

当 Appearance Preview 承载更多参数后，可以进一步把 preference adapter 从 `FloatingBarView` 中移出：

```text
AppStorage adapter
      ↓
FloatingBarPresentation
      ↓
FloatingBarView
```

届时 production 和 preview 都只传显式 presentation config，`FloatingBarView` 成为完全由 state + presentation 驱动的纯渲染层。

第一版不要求完成这个重构，以控制行为风险和 review scope。

## 26. 第一版最终技术决策

| 项目 | 决策 |
|---|---|
| 新页面 | `SettingsTab.appearance` |
| Settings layout | 复用单栏 `settingsScrollableContent` |
| Setting storage | 复用 6 个 existing keys |
| General migration | 只搬 rows，不改变语义 |
| Floating bar rendering | 直接复用 `FloatingBarView` |
| Presentation wiring | Optional `FloatingBarPresentation` override |
| Production fallback | 不传 override，继续读现有 AppStorage |
| Preview state | 泛化现有 `DemoState` 增加 stable appearance mode |
| Audio | 合成 `AudioLevelMeter`，不访问 microphone |
| Hover | 真实 `FloatingBarHoverTracker` / TranscriptPopup |
| Text preview | 显式 options 调 `TextOutputFormatter` |
| Preview sample | 固定、覆盖 overflow 与 formatting cases |
| Cleanup | 页面离开明确 `DemoState.stop()` |
| Preference migration | 无 |
| Network / ASR | Preview 不使用 |
| Sticky preview | 第一版不做 |
