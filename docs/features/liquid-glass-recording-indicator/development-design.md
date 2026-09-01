# Type4Me 液态玻璃录音指示条开发设计

> 文档类型：开发设计
> 文档状态：当前有效（已实现，持续验证）
> 设计日期：2026-08-25
> 最后校验：2026-09-01
> 实现基线：`b67ee103`（PR #279）
> 对应产品设计：[product-design.md](product-design.md)
> 上游文档：[外观设置增强开发设计](../appearance-settings-enhancements/development-design.md)、[紧凑型录音指示条开发设计](../compact-recording-indicator/development-design.md)

---

## 1. 设计摘要

本功能包含两层彼此独立的“Liquid Glass”视觉系统：

1. **前景 Orb / Text 材质**：`RecordingVisualStyle` 从五种旧背景效果重构为十种动态预设与一种静态红色预设；`FloatingBarView` 不再使用 `AudioRipple` 或 `ProcessingProgress`，改用 Metal/SwiftUI Shader 绘制录音球和文字填充。
2. **背景 Apple Liquid Glass 材质**：PR #279 将胶囊和悬停气泡的底层表面升级为 macOS 26 原生 SwiftUI `.glassEffect()`，并为 macOS 14/15 和“减少透明度”保留独立 fallback。Dark / Light 主题只改变背景与控件的可读性策略，不改变 Orb 预设本身。

前景实现采用 SwiftUI `Shader` 作为球体和文字的 `ShapeStyle`，而不是建立独立的 MTKView 或在运行时编译着色器。项目最低系统版本为 macOS 14；原生 Apple Liquid Glass 路径通过 `#available(macOS 26.0, *)` 隔离，因此旧系统继续编译并运行磨砂 fallback。

## 2. 已验证的实现基线

| 区域 | PR #279 当前实现 |
|---|---|
| `RecordingVisualStyle` | 11 个 Orb/文字前景样式继续使用既有 Metal/SwiftUI Shader 路径，不因背景主题变化而改变。 |
| 胶囊背景 | `RecordingGlassSurface` 统一承载 Regular 胶囊和悬停气泡背景。macOS 26+ 使用原生 `.glassEffect(.regular, in:)`；macOS 14/15 使用 `VisualEffectBlur` fallback；Reduce Transparency 使用实色。 |
| Dark / Light | `RecordingTheme` 为确定性二选一。Dark 原生玻璃下方使用 `TF.glassDarkContrastFloor = 0.52`；Light 不加该黑色底垫。 |
| Border | native glass 在 preparing/recording/processing/recovering 阶段不叠加人工 rim；旧系统与 Reduce Transparency fallback 保留既有边界。Done/Error 仍保留反馈边框。 |
| Theme scope | `FloatingBarView` 使用 `.environment(\.colorScheme, ...)` 将主题限定在自身 view tree，避免 Settings Preview 改写整个窗口外观。 |
| Preview | `AppearancePreviewStage` 继续复用真实 `FloatingBarView`，并以 `.id(presentation.theme)` 在主题切换时重建预览实例；`RecordingGlassSurface` 自身也按 theme identity 重建 native glass 表面。 |
| Panel geometry | `FloatingBarPanelLayout.panelSize` 将宽度向上取整为偶数，`bottomCenteredFrame` 对 origin 做点级取整，避免 overlay resize 时中心胶囊出现半点横向漂移。 |
| Compact | 继续使用既有 Compact renderer；本次背景材质升级不改变其录音状态机、实时文本语义或生命周期。 |

## 3. 范围与不变量

1. 不修改 `FloatingBarPhase`、`RecognitionSession` 的音频/ASR 时序或任何注入行为。
2. Compact 不读取也不渲染 `RecordingVisualStyle`；其全生命周期 24pt 高度和声纹历史语义不得回归。
3. `AudioLevelMeter` 继续由现有回调写入、由渲染时间线读取；不引入新的麦克风采集。
4. Production 与 Appearance Preview 必须使用同一个 `FloatingBarView`、`LiquidGlassOrb` 和 `LiquidGlassText`。
5. 不在 SwiftUI `body` 内迁移 `UserDefaults` 或写入偏好。
6. 球体、文字效果及其 fallback 不可改变文字宽度计算、Capsule 几何、按钮 hit area 或现有 top overlay 逻辑。
7. 背景材质只能改变视觉表面，不得引入新的录屏权限、状态机分支或额外屏幕采样；Dark / Light 是用户显式选择，不自动读取底层第三方窗口像素。
8. `Reduce Motion` 控制前景动画，`Reduce Transparency` 控制背景材质，两者必须保持独立语义。

## 4. 偏好模型与迁移

### 4.1 枚举

继续使用 `RecordingVisualStyle` 作为现有 presentation 和设置页的类型，避免把同一项偏好拆成两个并存的 enum：

```swift
enum RecordingVisualStyle: String, CaseIterable {
    static let storageKey = "tf_visualStyle"
    static let defaultValue = Self.siri.rawValue

    case siri
    case blueDrop
    case chromaticMetal
    case frost
    case opal
    case voiceWave
    case violetEmber
    case aurora
    case chrome
    case spectrum
    case staticGlass = "static"

    var displayName: String { /* L(zh, en) */ }
    var isAnimated: Bool { self != .staticGlass }
}
```

`showsRecordingPanel` 和 `showsBackgroundEffect` 删除：Regular 可见阶段始终渲染胶囊；是否有动态由 `isAnimated` 和辅助功能策略决定。`RecordingIndicatorStyle`、`LiveTranscriptDisplayPreference`、Tooltip 和取消按钮的 key 不变。

### 4.2 一次性迁移

引入私有 schema key `tf_recordingVisualStyleSchemaVersion`，目标版本为 `2`。在 `Type4MeApp` 的启动 bootstrap 中、首次创建 `FloatingBarView` 之前调用：

```swift
RecordingVisualStyle.migrateLegacyPreferenceIfNeeded(userDefaults: .standard)
```

迁移函数应是显式、幂等、可注入 `UserDefaults` 的纯偏好操作：

```text
classic     → siri
dual        → voiceWave
timeline    → spectrum
effectless  → static
hidden      → static
missing/invalid → siri
```

迁移仅在 schema 小于 2 时执行。它先读取旧 raw value、写入新 raw value、最后写 schema；任何后续用户选择都不再被覆盖。`hidden → static` 有意使 Regular 重新可见，必须在 Release Notes 中记录。测试使用独立 suite，禁止污染标准 `UserDefaults`。

### 4.3 Presentation 解析

`FloatingBarPresentation.visualStyle` 的字段名和 preview override seam 保持不变。生产路径仍通过 `@AppStorage(RecordingVisualStyle.storageKey)` 解析；preview 显式传入当前样式。所有 fallback 统一为 `.siri`，不得遗留 `.timeline`。

## 5. Orb 来源、许可与预设数据

### 5.1 上游快照

- 上游：[`LerSent001/orb`](https://github.com/LerSent001/orb)
- 固定来源提交：`fbf6eb81ad85e1125ed62027769bcfefc01d3613`
- 参考文件：`src/presets.ts`、`effect.metal`
- 许可证：MIT，Copyright (c) 2026 LerSent001。

不要在构建时访问 GitHub，也不要把 `main` 当作不受控依赖。首次实现时，将使用到的预设参数和液态流场函数以固定快照纳入仓库，并在文件头写明来源、提交和 MIT 版权声明；同时在仓库及 app bundle 的第三方声明中附上完整 MIT 文本。`src/toolcraft` 不进入本项目，因而不携带其单独的许可材料。

上游 `plasma` 预设不在首版 `RecordingVisualStyle` 的产品目录中；不得为了“全量导入”而在设置中暴露未确认的选项。

### 5.2 预设的单一真源

新增 `Type4Me/UI/FloatingBar/LiquidGlass/OrbPreset.swift`：

```swift
struct OrbPreset: Equatable, Sendable {
    let styleID: Float
    let speed: Float
    let contourDeform: Float
    let glassOpacity: Float
    let colors: SIMD4<SIMD4<Float>>
    let shell: OrbShell
    let glowColor: SIMD4<Float>
}
```

`RecordingVisualStyle.preset` 是唯一映射入口。它将用户可见样式映射到经固定快照的 Orb 参数；Metal 不读取字符串，不直接保存颜色，也不判断本地化名称。静态样式不使用上游时间流场，改用固定的红色玻璃参数。

## 6. Metal 与 SwiftUI 渲染架构

### 6.1 文件布局

```text
Type4Me/UI/FloatingBar/LiquidGlass/
├── OrbPreset.swift                 # 预设数据、映射和无动画策略
├── LiquidGlassMotion.swift         # 音量平滑、时间和 reduce-motion 策略
├── LiquidGlassOrb.swift            # 左侧 Finish 控件的 SwiftUI 外壳
├── LiquidGlassText.swift           # 文本掩码、confirmed/partial 组合
└── LiquidGlassShaders.metal        # 从 Orb 固定快照移植的 Metal 算法和 stitchable entry points
Type4Me/Resources/ThirdPartyNotices/
└── Orb-LICENSE
```

SwiftPM target `Type4Me` 同时包含 Swift 与 `.metal` 文件。构建产物中的预编译 Metal library 通过 `Bundle.module` 加载；不得使用 `makeLibrary(source:)` 在首次录音时即时编译。这样避免首次显示指示条时卡顿，也符合 Apple 对预编译 Metal library 的性能建议。

### 6.2 Shader entry points

上游 `effect.metal` 是面向完整矩形 fragment renderer 的生成代码，不能原样作为 SwiftUI text fill 使用。实现应保留其液态流场、palette、shell/highlight 和预设算法，改写最外层入口为 SwiftUI 可调用的 `[[ stitchable ]]` 函数：

```metal
[[ stitchable ]]
half4 liquidGlassFill(
    float2 position,
    float2 origin,
    float2 size,
    float time,
    float audioEnergy,
    float styleID,
    float motionEnabled);

[[ stitchable ]]
half4 liquidGlassText(
    float2 position,
    float2 origin,
    float2 size,
    float time,
    float audioEnergy,
    float styleID,
    float motionEnabled);
```

- `liquidGlassFill` 用于 `Circle().fill(shader)`，由 Circle 负责最终边界裁切；shader 负责内部流体、玻璃壳、折射高光和边缘发光。
- `liquidGlassText` 作为 `Text.foregroundStyle(shader)` 的 ShapeStyle。文字本身是掩码，shader 不采样或移动原有 glyph。
- Swift 层传入 view 的 global origin 和 size，使不同宽度的文字都按局部坐标流动；不能让长短文本的材质相位依赖整个 window 坐标。
- 动态样式在流场之上叠加低幅度的定向 specular sweep；它只改变字内亮度与色彩，不能构造进度填充。
- `staticGlass` 或系统减少动态效果时传 `motionEnabled = 0`，使用确定性 `time = 0` 帧。

### 6.3 材质策略与音量

`LiquidGlassMotion` 是无 UI 文案的可测试策略层：

```swift
struct LiquidGlassMotion: Equatable {
    let time: TimeInterval
    let energy: Float           // 0...1，已平滑、已截断
    let isAnimated: Bool
}
```

- 只在 Regular 的 `.preparing`、`.recording`、`.processing`、`.recovering` 且样式允许动画时使用 `TimelineView(.animation(minimumInterval: 1.0 / 30.0))`。
- 录音态从现有 `AudioLevelMeter.current` 读取，采用快速 attack、较慢 release 的指数平滑，并限制上限；它只调节流速、亮度和细微轮廓，绝不调节 SwiftUI frame 或字形尺寸。
- Processing/Recovering 的 `energy` 为固定低值，保证没有麦克风后仍存在均匀、可读的活动反馈。
- Done/Error/Hidden 不创建时间线。
- 一个 frame 内所有球体和文字使用相同单调时间基准，确保材质感觉属于同一套视觉系统。

## 7. FloatingBarView 改造

### 7.1 内容路由

```text
FloatingBarView
├── Recording（Regular）
│   ├── LiquidGlassOrb 作为 Finish 控件
│   └── RecordingTextContent
│       ├── 确认前缀：稳定 Text
│       └── 未确认尾段 / Listening：LiquidGlassText
├── Processing / Recovering
│   └── LiquidGlassText(effectiveProcessingLabel)
└── Done / Error
    └── 既有反馈 content，不使用时间线
```

`recordingButton(.finish)` 复用现有 `FloatingBarButtonInteraction`、accessibility action、`contentShape(Circle())` 与 35pt hit target，只用 `LiquidGlassOrb` 替换内层 `RecordingDot`/深灰填充。hover、focus 和 pressed 采用一个清晰但短暂的 stop affordance；静止态不覆盖球体材质。

### 7.2 流式文本组合

新增纯计算 helper，例如：

```swift
struct RecordingTextParts: Equatable {
    let confirmed: String
    let active: String
}
```

规则如下：

1. `segments.filter(\.isConfirmed)` 拼为 `confirmed`；最后一个 `isConfirmed == false` 段为 `active`。
2. `active` 非空时，使用零 spacing 的 `HStack` 将稳定 `Text(confirmed)` 与 `LiquidGlassText(active)` 拼接，保证基线一致。
3. 没有转写文本或实时文本关闭时，`active` 为 localized `倾听中 / Listening`，使录音阶段仍有文字滑光。
4. 所有段都已确认时只绘制稳定文本；球体继续表示录音活动。

现有 `recordingDisplayText` 与 `measureText` 仍对完整可见字符串测量。宽度计算、peak width、长文本 mask、Transcript Popup 和 `currentRecordingChromeWidth` 不能因渲染拆分而改变。

### 7.3 旧背景动效移除与当前背景边界

旧的全宽背景动效仍然删除或不再引用：

- `AudioRipple`
- `ProcessingProgress`
- `LevelSmoother`
- `LevelTimeline`
- `RecordingDot`

移除它们后清理所有针对 `.classic`、`.dual`、`.timeline`、`.effectless`、`.hidden` 的 `switch` 分支；编译器 exhaustive switch 必须成为遗漏检测器。`shouldRenderCapsule` 在 Regular 中不再依据 visual style 隐藏条，只受 `barPhase != .hidden` 控制。

PR #279 不恢复任何全宽背景动画，而是将静态承载表面统一为 `RecordingGlassSurface`：native glass / frosted fallback / opaque accessibility fallback 都只负责材质与可读性，不表达录音进度。Error 的红色 gradient 仍作为状态语义 overlay 存在。

## 8. 设置与预览接入

### 8.1 AppearanceSettingsTab

- `visualStyleRow` 标题替换为 `录音视觉 / Recording Visual`，副标题见产品设计。
- options 使用 `RecordingVisualStyle.allCases.map`，以 `displayName` 在显示时本地化；持久化 raw value 不存本地化字符串。
- Regular 显示该 row；Compact 隐藏但不写入、重置或迁移用户选择。

### 8.2 AppearancePreviewStage 与 DemoState

`AppearancePreviewStage` 增加本地 `PreviewPhase`：`.recording` 与 `.processing`。它向同一个 `FloatingBarView` 传相同的 `FloatingBarPresentation`，仅让 `DemoState` 生成不同 phase 和 sample segments：

```text
录音：确认前缀 + 未确认尾段 + 确定性合成音量
处理：effectiveProcessingLabel + 固定 processing energy
```

预览音量由确定性曲线生成，不使用 `Float.random`，便于截图、UI 自动化和设计评审复现。切出 Appearance tab 或 Stage 消失时继续调用既有 `stop()`，确保 timer/task 不泄漏。

主题切换采用两层 identity 保护：Preview 外层 `FloatingBarView` 绑定 `presentation.theme`，native `RecordingGlassSurface` 也绑定当前 theme。这样切换 Dark / Light 时会重新建立原生 glass layer，避免 SwiftUI 在同一 view identity 上复用旧材质导致预览残影或损坏。主题色通过 `FloatingBarView` 的局部 `colorScheme` environment 注入，禁止使用会影响整个 Settings window 的 `preferredColorScheme`。

## 9. 本地化、辅助功能与 fallback

1. 预设 display name、设置说明、PreviewPhase 和静态说明全部通过 `L(zh, en)` 计算，禁止存储已经翻译好的标题。
2. 使用 `@AppStorage("tf_language")` 或等效观察，使已有设置窗口、浮动面板和预览在语言切换时立即刷新。
3. 使用 `@Environment(\.accessibilityReduceMotion)`（或等效 macOS accessibility source）参与 `LiquidGlassMotion` 决策；不是仅降低帧率。
4. Finish 控件的 visual content 更换不影响 label、traits、accessibility action 或键盘可达性。
5. Metal library 或 shader function 在开发构建中若加载异常，记录诊断并使用稳定的 `LinearGradient`/`TF.recording` fallback；fallback 必须保留文字和按钮语义，不能隐藏 bar 或崩溃。
6. 背景材质读取 `@Environment(\.accessibilityReduceTransparency)`：开启时必须直接使用 `TF.floatingBackgroundLight` / `TF.floatingBackground` 实色，不进入 native glass 或 `NSVisualEffectView` 路径。
7. native Liquid Glass 只在 macOS 26+ 且 Reduce Transparency 关闭时使用；同一判断同时决定是否移除人工 rim，防止材质路径与边框路径不一致。

## 10. 文件变更规划

| 文件 | 变更 |
|---|---|
| `Type4Me/UI/AppState.swift` | 替换 `RecordingVisualStyle`、新增迁移和 `RecordingTextParts` 纯 helper（或置于同职责文件）。 |
| `Type4Me/Type4MeApp.swift` | 在启动 bootstrap 调用一次偏好迁移。 |
| `Type4Me/UI/FloatingBar/FloatingBarView.swift` | 前景继续承载 Orb/文字路由；背景统一为 `RecordingGlassSurface`，增加 native glass、Reduce Transparency、局部 colorScheme 与 native/fallback border 分流。 |
| `Type4Me/UI/FloatingBar/LiquidGlass/*` | 新增预设、动效策略、SwiftUI 外壳和 Metal shader。 |
| `Type4Me/UI/Settings/AppearanceSettingsTab.swift` | 更新 row 标题、说明和枚举选项。 |
| `Type4Me/UI/Settings/AppearancePreviewStage.swift` | 保留录音/处理预览阶段切换，并对 `FloatingBarView` 绑定 theme identity，稳定 Dark / Light 原生玻璃切换。 |
| `Type4Me/UI/Setup/DemoState.swift` | 增加确定性录音/处理 demo 数据与完整 teardown。 |
| `Type4Me/Resources/ThirdPartyNotices/Orb-LICENSE` | 加入上游 MIT 文本并确保 package/app 资源包含。 |
| `Type4Me/UI/DesignSystem.swift` | 定义 `glassDarkContrastFloor = 0.52`，并明确旧 rim 只用于 fallback。 |
| `Type4Me/UI/FloatingBar/FloatingBarPanel.swift` | panel width 偶数化、window origin 取整，稳定 overlay resize 时的中心位置。 |
| `Type4MeTests/AppStateTests.swift` | 覆盖旧样式迁移/fallback，并新增 overlay resize 时胶囊中心不漂移的回归测试。 |
| `Type4MeTests/AppearancePreviewTests.swift` | 覆盖 presentation、预览阶段和中英文行为。 |
| `Type4MeTests/LiquidGlassVisualTests.swift` | 新增纯策略、预设、文本分段和 reduce-motion 测试。 |

## 11. 自动化测试

### 11.1 偏好与迁移

- 11 个 case 的 raw value、排序、中文/英文 display name 和默认 `.siri`；
- 每一个旧 raw value 的一次性映射；
- schema 已是 2 时不覆盖用户的新选择；
- 缺失或未知值回退 `.siri`；
- Compact 下保存的样式在切回 Regular 后仍可用。

### 11.2 纯渲染策略

- `RecordingTextParts` 正确区分确认前缀、最后未确认尾段和 Listening fallback；
- `LiquidGlassMotion` 对静态和 Reduce Motion 总是 `isAnimated == false`、energy/time 为确定性值；
- 录音 energy 只处于 0...1，且不会影响布局数值；
- Processing/Recovering 为有活动反馈的固定 energy，Done/Error/Hidden 没有时间线。

### 11.3 Presentation 与回归

- Regular 不再因为视觉样式而隐藏 capsule；Compact 仍在 visual-style 静态值下显示自身 renderer；
- Finish/Cancel accessibility labels 和 control actions 仍存在；
- 设置变更能通过 `FloatingBarPresentation` 实时传入 Preview；
- Dark / Light 切换会重建 Preview 的 `FloatingBarView`，但不会改变 Settings window 其他区域的 color scheme；
- 不同 fractional overlay overflow 下 panel width 保持偶数，胶囊左边缘/中心位置不发生半点漂移；
- 中英文切换后所有新增 label 与 preview sample 重新求值。

像素截图是手工/CI UI 验证的补充，不能取代上面的确定性单元测试。

## 12. 手工验收与性能门槛

### 12.1 手工验收

1. 在每个动态预设下录音、安静、说话、停止、处理中、恢复、完成和错误；确认没有背景动画残留。
2. 检查静态和系统减少动态效果：球体和文字不再随时间或声音变化，仍保留玻璃层次和清晰状态文案。
3. 用中英文、短文本、400pt 长文本、确认文本和 partial tail 检查基线、溢出 mask、hover popup 及胶囊宽度。
4. 切换 Regular/Compact，确认 Compact 的 24pt 声纹轨、各 phase 的宽度、按钮和反馈保持原样。
5. 在 Appearance Preview 中切换样式、语言、录音/处理阶段及设置开关，确认不请求麦克风权限，离开页面后不继续刷新。
6. 用 VoiceOver、键盘焦点、Tooltip 关闭和 `Esc` 取消复核可操作性。
7. 在 macOS 26 分别验证 Dark / Light 原生 Liquid Glass；在 macOS 14/15 验证 `NSVisualEffectView` fallback；开启“减少透明度”后确认两种主题都立即成为实色且不残留 native glass rim。
8. 在 Appearance Preview 中反复切换 Dark / Light，确认只有预览浮动条刷新，设置窗口其他区域不闪烁、不改主题。
9. 展开/收起 Tooltip、Transcript Popup 等 overlay，确认面板尺寸变化时胶囊中心不横向跳动。

### 12.2 性能门槛

- 动态 Regular renderer 最多驱动一个 35pt 圆形和一行不超过 400pt 的文字，目标刷新率为 30fps；不持有逐帧增长的 buffer。
- 没有 visible Regular 动态内容、静态样式、Reduce Motion、Done、Error 或 Hidden 时，不创建 `TimelineView(.animation)`。
- 录音回调不得触发 SwiftUI 大范围观察刷新；沿用 `AudioLevelMeter` 的隔离读取模式。
- 以 Instruments 的 Core Animation、Metal System Trace 和 Energy Log 对 Intel/Apple Silicon 各进行一次 60 秒实录验证；若出现可见掉帧，先降低流场采样与文字局部尺寸，再考虑降低帧率，不能退回背景 Canvas。

## 13. 构建、许可证与发布检查

实现 PR 至少运行：

```bash
swift test
swift build -c release
```

还必须验证：

1. 纯构建与本地 Sherpa 构建均能编译 `.metal` 并从 app bundle 找到 library；
2. 打包脚本会携带第三方 Orb 许可证；
3. Release Notes 说明旧“无”会迁移成可见的“静态”红色玻璃方案；
4. 视觉更新作为版本核心能力时，按仓库既有发布约定在 CHANGELOG 与 Release Notes 放入实际 UI 配图。

## 14. 风险与缓解

| 风险 | 缓解 |
|---|---|
| 直接移植完整上游 fragment shader 与 SwiftUI shader ABI 不兼容 | 只移植共享流场/材质算法，单独实现 `[[ stitchable ]]` 入口；先做最小编译验证。 |
| 首次使用 runtime 编译造成录音开启卡顿 | 使用 SwiftPM 的预编译 `.metallib`，禁止 `makeLibrary(source:)`。 |
| 流光降低转写可读性 | 确认前缀静态化、限定高光振幅、全程保留高对比基色。 |
| 静态名义上静态却仍有时间线 | 将 `isAnimated` 作为单一策略开关，测试并在 Reduce Motion 路径复用。 |
| 迁移覆盖用户新设置或视图 body 反复写偏好 | schema 版本化、应用启动时执行一次、UserDefaults 注入测试。 |
| Compact 被错误接入 Orb | 以 `usesCompactPresentation` 在内容路由最前分流，并回归其所有 phase。 |
| Preview 与生产渲染漂移 | Preview 只替换 state，不复制 `FloatingBarView` 或 liquid-glass 组件。 |
| native glass 在反复主题切换时复用错误 layer | `FloatingBarView` Preview 与 `RecordingGlassSurface` 均按 theme 建立明确 identity。 |
| Dark 原生玻璃覆盖亮背景时对比度不足 | 在 glass 下方固定使用 `TF.glassDarkContrastFloor = 0.52`，不把 scrim 放到 glass 上方。 |
| overlay resize 导致半点横向漂移 | panel width 统一向上取偶数，最终 window origin 做取整，并以 fractional overflow 回归测试锁定。 |
| 上游许可证或参数漂移 | 固定 commit、保留 MIT、明确更新流程需人工审查和新快照。 |

## 15. 实现顺序

1. 先加入固定上游快照、MIT 文件和最小 `LiquidGlassShaders.metal` 编译验证；
2. 实现 `RecordingVisualStyle` 新 enum、迁移、预设映射和纯单元测试；
3. 实现 `LiquidGlassMotion`、`LiquidGlassOrb`、`LiquidGlassText`，先在 isolated preview 中检查 dynamic/static/reduce-motion；
4. 替换 Regular `FloatingBarView` 背景和 Finish/文字路由，删除旧效果组件；
5. 接入 Settings 与 Appearance Preview 的录音/处理阶段；
6. 完成单元测试、全量构建、手工视觉/无障碍/性能验收和许可证打包检查；
7. 在 PR #279 中将背景承载表面升级为 native Apple Liquid Glass，并补齐 Dark / Light、Reduce Transparency、旧系统 fallback、Preview identity 与 panel pixel alignment 回归。

## 16. 原生 Apple Liquid Glass 背景架构

### 16.1 材质选择顺序

`RecordingGlassSurface` 是胶囊和 Transcript Popup 背景的统一入口，分支优先级固定如下：

```text
Reduce Transparency 开启
    → 对应主题实色背景
否则 macOS 26+
    → SwiftUI .glassEffect(.regular, in: shape)
       Dark: glass 下方叠 0.52 black contrast floor
       Light: clear floor
否则 macOS 14/15
    → VisualEffectBlur + 主题 tint
```

该顺序意味着辅助功能优先级高于平台能力：即使运行在 macOS 26，只要用户开启 Reduce Transparency，也不得创建 native glass surface。

### 16.2 边框与状态 overlay

- preparing / recording / processing / recovering：native glass 自带边界折射，不额外画 rim；fallback 继续使用 `recordingGlassRim` / `recordingLightGlassRim`。
- done / error：继续绘制反馈边框，并使用短 opacity transition，避免状态切换时边框瞬间跳变。
- error gradient 仍叠加在材质表面之上，只表达错误状态，不改变基础主题选择。

### 16.3 Theme scope 与 Preview identity

`FloatingBarView` 在自身 view tree 注入 `.environment(\.colorScheme, ...)`，不能使用会传播到宿主窗口的 `preferredColorScheme`。Appearance Preview 额外通过 `.id(presentation.theme)` 重建 `FloatingBarView`；native `RecordingGlassSurface` 也通过 `.id(theme)` 重建材质层。这是针对原生 glass layer 生命周期的稳定性措施，而不是业务状态重置。

### 16.4 Panel pixel alignment

Tooltip/action overlay 会让 panel 在胶囊两侧产生 fractional overflow。为保持胶囊中心稳定：

1. `panelSize.width` 先 `ceil`，再向上取最近偶数；
2. `bottomCenteredFrame` 对最终 `x/y` origin 取整；
3. 单元测试使用 `12.5`、`37.25`、`73.9` 等 fractional overflow，验证 overlay resize 前后胶囊 origin 恒定。

这一修复只约束外层 window/panel 几何，不改变胶囊自身的自适应宽度或 spring 动画。

## 17. 外观主题与屏幕明暗采样技术调研

在探索液态玻璃指示条「自适应」外观模式期间，团队对基于 Quartz 屏幕采样的像素级明暗计算方案进行了预研与真机验证。

详见独立设计归档文档：[自适应主题与屏幕明暗采样技术调研与设计文档](adaptive-theme-and-screen-sampling-research.md)。

技术要点与未采纳原因：
1. **macOS 合成层隔离**：`NSVisualEffectView` 与 `.glassEffect()` 的物理折射在 WindowServer GPU 阶段执行，不向应用进程回传像素颜色；
2. **TCC 权限阻碍**：通过 `CGWindowListCreateImage` 或 `ScreenCaptureKit` 抓取底层窗口像素必须向用户索要「屏幕录制权限（Screen Recording / TCC）」，带来严重的隐私打扰与信任风险；
3. **架构决策**：彻底放弃屏幕抓取方案，保留纯粹的「暗色」与「明亮」双主题，零权限消耗，保障应用轻量与用户隐私。
