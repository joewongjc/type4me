# Type4Me 当前键盘焦点文本回写开发设计

> 文档类型：开发设计
> 文档状态：设计完成，待实现
> 设计日期：2026-09-10
> 最后校验：2026-09-10
> 对应产品设计：[产品设计](product-design.md)
> 关联 Issue / PR：Issue #291、Issue #266、PR #269

## 1. 架构总览与分层

将原本交织了“目标元素寻找”、“全局输入监控”、“不透明编辑器启发”、“AX焦点连续性”以及“事后插入证明”的庞大状态机彻底解耦，拆分为三个单向、职责独立的子系统：

```
+-------------------------------------------------------------+
|                      Target Selection                       |
|   Interactive: Current Frontmost App (Keyboard Focus)       |
|   Automation:  Pinned Target Application (PID Verified)     |
+-------------------------------------------------------------+
                              |
                              v
+-------------------------------------------------------------+
|                      Delivery Pipeline                      |
|   1. Write Temporary Clipboard                              |
|   2. Dispatch Cmd+V to Target App                           |
|   3. Restore Clipboard (per ClipboardOutputPolicy)          |
+-------------------------------------------------------------+
                              |
                              v
+-------------------------------------------------------------+
|               Passive Observation & Telemetry               |
|   Non-blocking AX Context (IntelliSense Learning & History) |
+-------------------------------------------------------------+
```

## 2. 目标选择机制 (Target Selection)

### 2.1 模式抽象
重构注入目标定义，以 `InjectionTargetMode` 显式区分输入场景：

```swift
enum InjectionTargetMode: Sendable {
    /// 普通交互式输入：输出时直接读取当前键盘焦点所在的前台应用
    case currentKeyboardFocus

    /// 外部自动化任务：指定绑定的目标应用（需保持激活与 PID 一致）
    case pinnedApplication(NSRunningApplication)
}
```

### 2.2 交互模式目标判定
在 `currentKeyboardFocus` 下：
1. 直接读取 `NSWorkspace.shared.frontmostApplication`；
2. 若前台应用为 `nil`、已终止（`isTerminated`）或为 Type4Me 自身，判定为无外部注入目标，走剪贴板兜底；
3. 若为正常第三方应用，直接将该应用作为目标，无需任何 AX 前置查询或控件可编辑性校验。

### 2.3 自动化模式目标判定
在 `pinnedApplication` 下：
1. 校验目标进程是否存活；
2. 如未处于活跃状态，调用 `app.activate(options: .activateIgnoringOtherApps)`；
3. 校验激活后前台应用的 PID 是否与绑定的 PID 一致；若不一致则判定失败并兜底到剪贴板，防止向非预期窗口投递数据。

## 3. 投递管线精简 (Delivery Pipeline)

### 3.1 主投递路径
```swift
func inject(
    _ text: String,
    mode: InjectionTargetMode
) -> InjectionOutcome {
    let targetApp: NSRunningApplication? = {
        switch mode {
        case .currentKeyboardFocus:
            let frontmost = NSWorkspace.shared.frontmostApplication
            guard let frontmost,
                  frontmost.bundleIdentifier != Bundle.main.bundleIdentifier,
                  !frontmost.isTerminated
            else { return nil }
            return frontmost

        case .pinnedApplication(let app):
            guard !app.isTerminated else { return nil }
            if NSWorkspace.shared.frontmostApplication?.processIdentifier != app.processIdentifier {
                _ = app.activate(options: .activateIgnoringOtherApps)
                // 允许短时间等待激活生效
            }
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else {
                return nil
            }
            return app
        }
    }()

    guard let targetApp else {
        copyToClipboard(text, transient: false)
        return .clipboardFallback(reason: .noTargetApp)
    }

    // 1. 根据剪贴板保留策略捕获当前系统剪贴板快照
    let restoreNeeded = shouldRestoreClipboard(for: currentPolicy)
    if restoreNeeded {
        captureClipboardSnapshot()
    }

    // 2. 写入待粘贴文本到剪贴板
    writeToSystemPasteboard(text)

    // 3. 向前台应用发送标准 Cmd+V
    let posted = postPasteKeyEvent(to: targetApp)
    guard posted else {
        return .clipboardFallback(reason: .eventPostFailed)
    }

    // 4. 如需恢复剪贴板，调度延迟恢复（200-500ms，适配 Electron/原生响应时序）
    if restoreNeeded {
        scheduleClipboardRestore()
    }

    // 5. 异步触发被动感知（不阻塞主流程，不改变注入结果）
    triggerPassiveObservation(app: targetApp, text: text)

    return .pasteDispatched(targetApp: targetApp)
}
```

### 3.2 注入结果模型重塑
移除 `inferInjectionOutcome` 对“是否真正插入”的虚假保证，将结果类型简化为事实陈述：

```swift
enum InjectionOutcome: Equatable, Sendable {
    /// Cmd+V 已成功投递至目标应用的事件队列
    case pasteDispatched(targetApp: NSRunningApplication)

    /// 无法投递，已退化为纯剪贴板写入
    case clipboardFallback(reason: FallbackReason)

    enum FallbackReason: Equatable, Sendable {
        case noTargetApp
        case targetTerminated
        case targetMismatch
        case eventPostFailed
    }
}
```

### 3.3 剪贴板策略完全回归 `ClipboardOutputPolicy`
- 无论目标应用是纯原生、Rust+Metal（super.engineering）、Electron 还是终端，剪贴板是否保留纯粹由用户配置的 `ClipboardOutputPolicy`（`alwaysCopy` / `cancelProcessed` / `cancelRawTranscript` / `neverCopy`）决定；
- 彻底取消在 `TextInjectionEngine` 内强制 `retainResult` 的特判逻辑。

## 4. 减负与代码删除清单 (Weight Reduction)

本次重构的核心工作是**删除负资产代码**，预计净减少代码约 1800 ~ 2200 行。

### 4.1 `TextInjectionEngine.swift` 清理项
- **删除 `InputActivityMonitor`（约 450 行）**：
  - 移除全局 Event Tap 事件统计与 Epoch 计数器；
  - 移除 `StopGestureTail` 结构体及 `Fn` 物理按键释放尾部事件过滤（179 键码探测）；
  - 移除合成事件标记（`syntheticInputEventMarker`）。
- **删除 `FocusContinuityGuard` 与 `ConfirmedTargetInvalidationState`（约 200 行）**：
  - 移除通过 `AXObserver` 对焦点变更的死守监控。
- **删除目标启发与扫描逻辑（约 600 行）**：
  - 移除 `EndInjectionTarget`（`exactElement` 与 `bestEffortOpaqueWindow`）；
  - 移除 `ConfirmedFocusLookup`、`OpaquePasteDestinationLookup`；
  - 移除 `scanForAccessibleEditableDescendant`（300 个节点递归遍历）；
  - 移除 `standardPasteCommandState`（菜单栏遍历找 Paste 菜单）；
  - 移除 `isStrictEditableCandidate`、`shouldUseBestEffortOpaqueDestination`。
- **删除注入后 AX 证明逻辑（约 250 行）**：
  - 移除 `inferInjectionOutcome` 中强行将 `AXWindow` 判定为不可编辑并推翻粘贴结果的代码；
  - 移除 `inferInsertedRange` 等推断逻辑。

### 4.2 关联文件清理项
- **`Type4Me/Injection/InjectionTargetPreference.swift`**：
  - 废弃并删除该文件及其枚举定义。
- **`Type4Me/Input/HotkeyManager.swift`**：
  - 移除对 `TextInjectionEngine.beginGlobalInputEvent`、`endGlobalInputEvent` 和 `authorizeCurrentGlobalInputForStopCapture` 的调用。
- **`Type4Me/Type4MeApp.swift`**：
  - 移除 `activeInjectionTargetPreference`、`freezeInjectionTargetPreference`、`preparePreciseTargetCapture` 以及相关的通知监听。
- **`Type4Me/Session/RecognitionSession.swift`**：
  - 移除 `injectionTargetPreference` 参数传递与 `planInjectionTarget` / `hasEndTarget` 分支，直接统一为交互式输入模式。
- **`Type4Me/UI/Settings/GeneralSettingsTab.swift`**：
  - 移除 `injectionTargetRow` 视图及相关 `@AppStorage` 状态。
- **`Type4MeTests/InjectionTargetPreferenceTests.swift`（770 行）**：
  - 彻底删除该测试文件（其测试内容全为已废弃的内部私有状态与偏好加载）。

## 5. 数据迁移与向后兼容

- **UserDefaults 配置清理**：
  - `tf_injectionTargetPreference` 键值废弃，启动时无需强行迁移或重写，任其自然休眠；
- **URL Commands 与自动化兼容**：
  - 外部通过 `type4me://record` 调用的自动化流程，继续通过 `.pinnedApplication` 模式运行，保持原有的隔离安全性；
- **Tracked Replacement (Revise)**：
  - Revise 专用的 `injectTracked` 与选区替换逻辑保持独立，不依赖本次精简的代码。

## 6. 测试与验证方案

### 6.1 单元测试改造
- 增加针对 `InjectionTargetMode.currentKeyboardFocus` 与 `.pinnedApplication` 的目标路由测试；
- 增加剪贴板保护策略一致性测试：验证不管任何应用场景，均按 `ClipboardOutputPolicy` 执行保留或恢复。

### 6.2 实机端到端验收矩阵
1. **Issue #291 核心回归**：在 super.engineering 中录音并完成，验证文字正确注入且剪贴板按策略恢复，无错误弹窗；
2. **主流自定义渲染应用**：
   - 微信 / 企业微信聊天窗口；
   - 终端 / Ghostty / iTerm2；
   - Obsidian / VS Code；
   - Chrome / Safari 地址栏与网页输入框；
3. **录音期间跨应用切换**：在 App A 开始录音，停止后快速切换到 App B，文字准确注入到 App B；
4. **URL Scheme 自动化测试**：通过脚本调用 URL Scheme，确认即使切换到其他应用，自动化结果仍安全投递给目标 App。
