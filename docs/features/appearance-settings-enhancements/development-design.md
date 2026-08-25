# Type4Me 录音外观增强配置开发设计

> 分支：`feat/appearance-settings-enhancements`
> 文档类型：开发设计
> 文档状态：已完成
> 设计日期：2026-08-25
> 对应产品设计：`docs/features/appearance-settings-enhancements/product-design.md`

---

## 1. 设计摘要

本设计在 `Type4Me` 现有的外观与悬浮条架构上，实现两个通用的外观控制配置以及设置页交互的动态条件化呈现：
1. **显示 Tooltips（`tf_showTooltips`）**：通用控制项，控制模式提示气泡（Mode Hint）与悬停按钮操作气泡（Action Hint）的显隐。
2. **显示取消按钮（`tf_showCancelButton`）**：通用控制项，控制常规悬浮条与紧凑型悬浮条右侧取消按钮（Cancel Button）的显隐与布局适配。
3. **设置页动态条件展示**：在 `AppearanceSettingsTab` 中，根据当前选择的 `indicatorStyle` 动态控制常规专属配置项的挂载与隐藏，替代原有的置灰禁用。

---

## 2. 核心工程原则

1. **配置独立与正交**：`tf_showTooltips` 与 `tf_showCancelButton` 均为独立 Boolean 偏好，不受 `indicatorStyle` 或 `visualStyle` 约束；
2. **零迁移与安全回退**：缺失 Key 时自动回退为默认值 `true`，已有用户无感知平滑兼容；
3. **状态保留原则**：隐藏常规专属配置项时不重写其存储值；切回常规模式后已保存的动效与文本偏好立即恢复；
4. **Preview 一致性**：`FloatingBarPresentation` 完整承载新配置字段，Settings Preview Stage 直接复用生产渲染管道，无分叉逻辑；
5. **快捷键保留**：隐藏取消按钮属于纯视觉/触控层精简，键盘全局 `Esc` 键取消录音的事件链路不受影响；
6. **多语言即时响应**：所有新增文案遵循 `L("...", "...")` 国际化规范，支持运行中切换语言无需重启。

---

## 3. 现有架构与扩展点

### 3.1 FloatingBarPresentation 结构

当前定义（`Type4Me/UI/FloatingBar/FloatingBarView.swift`）：
```swift
struct FloatingBarPresentation: Equatable {
    var indicatorStyle: RecordingIndicatorStyle
    var visualStyle: RecordingVisualStyle
    var showsLiveTranscript: Bool
    var enablesHoverTranscriptPreview: Bool
}
```

扩展为：
```swift
struct FloatingBarPresentation: Equatable {
    var indicatorStyle: RecordingIndicatorStyle
    var visualStyle: RecordingVisualStyle
    var showsLiveTranscript: Bool
    var enablesHoverTranscriptPreview: Bool
    var showsTooltips: Bool
    var showsCancelButton: Bool
}
```

### 3.2 AppStorage 键与默认值

在 `AppState.swift` 或相关服务中定义常量：
```swift
enum AppearancePreferenceDefaults {
    static let showTooltipsKey = "tf_showTooltips"
    static let showTooltipsDefault = true

    static let showCancelButtonKey = "tf_showCancelButton"
    static let showCancelButtonDefault = true
}
```

---

## 4. 表现层与布局适配设计

### 4.1 FloatingBarView 中的 Presentation Resolution

在 `FloatingBarView.swift` 中引入两项配置的解析：
```swift
@AppStorage(AppearancePreferenceDefaults.showTooltipsKey)
private var showTooltips = AppearancePreferenceDefaults.showTooltipsDefault

@AppStorage(AppearancePreferenceDefaults.showCancelButtonKey)
private var showCancelButton = AppearancePreferenceDefaults.showCancelButtonDefault

private var effectiveShowsTooltips: Bool {
    presentationOverride?.showsTooltips ?? showTooltips
}

private var effectiveShowsCancelButton: Bool {
    presentationOverride?.showsCancelButton ?? showCancelButton
}
```

### 4.2 Tooltips 显隐控制逻辑

`activeTopOverlay` 增加对 `effectiveShowsTooltips` 的统一判断：
```swift
private var activeTopOverlay: FloatingBarTopOverlay? {
    if effectiveIndicatorStyle == .regular {
        guard recordingVisualStyle.showsRecordingPanel else { return nil }
    }
    // Transcript Popup 由独立的 hoverTranscriptPreview 控制
    if showTranscriptPopup { return .transcript }

    // 模式提示与操作提示均受 effectiveShowsTooltips 控制
    guard effectiveShowsTooltips else { return nil }

    if let hoveredAction, state.barPhase == .recording || state.barPhase == .preparing {
        return .action(hoveredAction)
    }
    if showsModeHint,
       (state.barPhase == .preparing || state.barPhase == .recording) {
        return .mode
    }
    return nil
}
```

此外，在 `handlePhaseChange(.preparing)` 中：
```swift
case .preparing:
    // ...
    if effectiveShowsTooltips {
        showModeHint()
    }
```

### 4.3 取消按钮与录音布局适配

#### 4.3.1 紧凑模式（Compact Layout）
```swift
private var compactRecordingContent: some View {
    HStack(spacing: 0) {
        compactRecordingButton(.finish)
            .frame(width: 32, height: TF.compactIndicatorHeight)

        CompactAudioIndicator(meter: state.audioLevel)
            .frame(maxWidth: .infinity, maxHeight: TF.compactIndicatorHeight)

        if effectiveShowsCancelButton {
            compactRecordingButton(.cancel)
                .frame(width: 32, height: TF.compactIndicatorHeight)
        } else {
            Spacer().frame(width: 10)
        }
    }
    .frame(width: TF.compactIndicatorWidth, height: TF.compactIndicatorHeight)
}
```
- **尺寸稳定**：总宽固定为 `TF.compactIndicatorWidth`（180pt），高 24pt；
- **右侧填充**：隐藏取消按钮时，右侧使用 10pt 内边距占位，`CompactAudioIndicator` 弹性扩展填满中间可用宽度；
- **声纹动画**：Canvas 根据传入的 `size.width` 动态计算总列数并自动延伸声纹流。

#### 4.3.2 常规模式（Regular Layout）
```swift
private var recordingContent: some View {
    HStack(spacing: TF.recordingControlGap) {
        recordingButton(.finish)

        recordingText

        if effectiveShowsCancelButton {
            recordingButton(.cancel)
        }
    }
    .padding(.leading, TF.recordingEdgeInset)
    .padding(.trailing, effectiveShowsCancelButton ? TF.recordingEdgeInset : 14)
}
```

- **宽度计算**：
  - 最小宽度保持 `TF.barWidthCompact`（180pt）；
  - `TF.recordingChromeWidth` 常量根据是否包含取消按钮动态折算：
    - 含取消按钮：Finish (35) + Gap (8) + Cancel (35) + Gap (8) + Insets (20) ≈ 106pt；
    - 不含取消按钮：Finish (35) + Gap (8) + Insets (24) ≈ 67pt；
  - 动态计算公式：
    ```swift
    private var currentChromeWidth: CGFloat {
        effectiveShowsCancelButton ? TF.recordingChromeWidth : 67.0
    }
    ```
- **Esc 取消**：`handleKeyboardCancel` 与全局按键监听独立于视觉按钮，无按键移除副作用。

---

## 5. 设置页（AppearanceSettingsTab）设计

### 5.1 视图构建与动画

在 `AppearanceSettingsTab.swift` 中：
```swift
@AppStorage(AppearancePreferenceDefaults.showTooltipsKey)
private var showTooltips = AppearancePreferenceDefaults.showTooltipsDefault

@AppStorage(AppearancePreferenceDefaults.showCancelButtonKey)
private var showCancelButton = AppearancePreferenceDefaults.showCancelButtonDefault

// ...
settingsGroupCard(L("录音显示", "Recording Display"), icon: "macwindow") {
    indicatorStyleRow

    if !isCompact {
        SettingsDivider()
        visualStyleRow
        SettingsDivider()
        liveTranscriptRow
        SettingsDivider()
        hoverPreviewRow
    }

    SettingsDivider()
    showTooltipsRow
    SettingsDivider()
    showCancelButtonRow
}
```

在 `indicatorStyleRow` 切换时，添加 `.animation(TF.springGentle, value: isCompact)` 保证行增删的平滑视觉过渡。

### 5.2 Row 视图定义

```swift
private var showTooltipsRow: some View {
    settingsToggleRow(
        L("显示 Tooltips", "Show Tooltips"),
        subtitle: L(
            "开启后在录音开始与悬停按钮时显示提示气泡",
            "Show hints on recording start and button hover"
        ),
        isOn: $showTooltips
    )
}

private var showCancelButtonRow: some View {
    settingsToggleRow(
        L("显示取消按钮", "Show Cancel Button"),
        subtitle: L(
            "关闭后隐藏取消按钮，仍可通过 Esc 键取消录制",
            "Hide cancel button; you can still cancel using Esc key"
        ),
        isOn: $showCancelButton
    )
}
```

---

## 6. AppearancePreviewStage 联动

在 `AppearancePreviewStage.swift` 中：
- `presentation` 计算属性同步传递 `showsTooltips` 与 `showsCancelButton`；
- 预览视图实时响应开关变化：
  - 关闭取消按钮时，预览界面的录音条立即隐藏取消按钮；
  - 关闭 Tooltips 时，预览阶段不弹出模式气泡或悬停气泡。

---

## 7. 文件变更规划

| 文件 | 变更内容 |
|---|---|
| `Type4Me/UI/AppState.swift` | 声明 `AppearancePreferenceDefaults` 常量（key / default） |
| `Type4Me/UI/FloatingBar/FloatingBarView.swift` | `FloatingBarPresentation` 扩展新字段；`activeTopOverlay` 与录音布局适配显隐 |
| `Type4Me/UI/Settings/AppearanceSettingsTab.swift` | 新增两个通用开关；重构为条件化渲染（`if !isCompact`） |
| `Type4Me/UI/Settings/AppearancePreviewStage.swift` | 传递新增 presentation 字段以供实时预览 |
| `Type4MeTests/AppearancePreviewTests.swift` | 增加新增配置的默认值、Presentation 解析与布局断言测试 |

---

## 8. 单元测试与验证计划

### 8.1 单元测试用例
1. **Presentation 默认值与初始化测试**：
   - 验证 `FloatingBarPresentation` 包含 `showsTooltips: true` 与 `showsCancelButton: true`；
2. **偏好安全回退测试**：
   - 验证缺少 UserDefaults key 时默认解析为 `true`；
3. **Tooltips 逻辑判定测试**：
   - 验证 `showsTooltips == false` 时 `activeTopOverlay` 为 `nil`；
4. **取消按钮显隐布局测试**：
   - 验证 Compact 模式在隐藏取消按钮时仍满足 180 × 24 几何约束；
   - 验证 Regular 模式在隐藏取消按钮时满足 180 最小宽度与紧凑计算规则；
5. **多语言文本匹配测试**：
   - 验证中英文标题与副标题渲染正确。

### 8.2 自动化测试命令
```bash
swift test
swift build
```

---

## 9. 技术决策汇总

| 决策项 | 决策内容 | 理由 |
|---|---|---|
| **Tooltips 控制范围** | 同时控制模式提示与按钮操作气泡 | 保证界面免打扰的一致性 |
| **取消按钮隐藏行为（Compact）** | 宽度保持 180pt，声纹自然右延 | 维持胶囊尺寸稳定性与视觉平衡 |
| **取消按钮隐藏行为（Regular）** | 移除右侧按钮，右侧内边距 10pt，最小宽度 180pt | 保持一致的下限胶囊触控与视觉质感 |
| **设置页模式切换交互** | 条件隐藏专属项（`if !isCompact`），通用项置底 | 消除不生效项的认知干扰，界面极简高效 |
| **存储 Key** | `tf_showTooltips` 与 `tf_showCancelButton` | 命名风格与现有 `tf_` 系列完全一致 |
| **默认值** | 均为 `true` | 保障老用户平滑无感升级 |
