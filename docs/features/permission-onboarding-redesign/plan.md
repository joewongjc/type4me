# Type4Me 权限引导与首启流程实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 重构 Type4Me 的首次启动向导为极简 2 步流程，1:1 复刻 Screenflare 风格的高保真深色权限引导卡片，并在应用首页右下角集成未配置默认模型的悬浮引导卡片，修复首启与权限恢复的窗口路由。

**Architecture:** 
1. `PermissionGuideModel` 状态机增强：接入由 `AppDelegate` 注入的真实 `hotkeyProbe` 探测、宿主窗口唤起闭包与持久化重启机制。
2. `SetupWizardView` 极简重构：收敛至 Step 0（欢迎）与 Step 1（Screenflare 权限页），并在完成或重启前持久化 `hasCompletedSetup`（及云版本 `.byoKey`）。
3. `PermissionGuideView` 视觉 1:1 重构：深色半透明圆角卡片、居中头部、分组容器、麦克风（必需）、辅助功能（必需+动态重启提示）、Apple 语音识别（条件可选），系统设置联动 + 底部拖拽浮层 + 重启自愈按钮。
4. `FloatingModelAlertCards` 首页集成：在 `GeneralSettingsTab` 右下角展示未配置 ASR/LLM 提醒卡片，点击一键跳转至 `Models` 对应类别，响应 `credentialsDidChange` 通知自动消除。
5. 窗口路由与生命周期修复：在 `MenuBarControlCenter` 注册全局 `openSetupAction`/`openSettingsAction`，并在 `Type4MeApp` 中以重试重发机制 `presentSetupWizard()` 稳定拉起。

**Tech Stack:** Swift 6, SwiftUI, AppKit, AVFoundation, ApplicationServices (AX API), Speech (SFSpeechRecognizer), ServiceManagement.

**Spec:** `docs/features/permission-onboarding-redesign/product-design.md` & `docs/features/permission-onboarding-redesign/development-design.md`

## Global Constraints

- **Bilingual Copy:** 必须支持中文和英文，所有文案通过 `L(zh, en)` 实现，跟随 `AppLanguage.current` / `tf_language` 实时更新，无需重启应用。
- **Conditional Compilation:** 严格保持 `#if HAS_CLOUD_SUBSCRIPTION` 与 `#if HAS_SHERPA_ONNX` 条件编译守卫完整可用。
- **No Floating Windows Stacking:** 辅助功能拖拽授权完成后仅唤醒发起该流程的宿主窗口，严禁重复层叠独立权限窗口。
- **Swift 6 & MainActor:** 所有 UI 与可观察状态类均严格标注 `@MainActor`，禁止跨线程并发冲突。

---

### Task 1: 凭证变更广播与导航模型扩展 (Credentials Notification & Navigation Model)

**Files:**
- Modify: `Type4Me/Services/KeychainService.swift`
- Modify: `Type4Me/UI/Settings/SettingsView.swift`
- Modify: `Type4Me/UI/Settings/ModelSettingsTab.swift`
- Test: `Tests/Type4MeTests/KeychainNotificationTests.swift`

**Interfaces:**
- Consumes: `KeychainService.selectedASRProvider`, `KeychainService.selectedLLMProvider`, `ModelCategory`
- Produces: `Notification.Name.credentialsDidChange`, `AppNavigationModel.pendingModelCategory: ModelCategory?`

- [ ] **Step 1: 编写凭证通知与导航测试**

```swift
import XCTest
@testable import Type4Me

final class KeychainNotificationTests: XCTestCase {
    func testCredentialsDidChangeNotificationName() {
        XCTAssertEqual(Notification.Name.credentialsDidChange.rawValue, "tf_credentialsDidChange")
    }
}
```

- [ ] **Step 2: 运行测试验证失败**

Run: `swift test --filter KeychainNotificationTests`
Expected: FAIL (symbol not found).

- [ ] **Step 3: 实现 `credentialsDidChange` 与 `AppNavigationModel` 扩展**

1. 在 `KeychainService.swift` 扩展通知：
```swift
extension Notification.Name {
    static let credentialsDidChange = Notification.Name("tf_credentialsDidChange")
}
```
并在 `saveASRCredentials`, `saveLLMCredentials`, `selectedASRProvider` setter, `selectedLLMProvider` setter 成功时发送通知：
```swift
NotificationCenter.default.post(name: .credentialsDidChange, object: nil)
```

2. 在 `SettingsView.swift` 中的 `AppNavigationModel` 增加属性：
```swift
@MainActor
@Observable
final class AppNavigationModel {
    var selectedTab: SettingsTab = .general
    var pendingModelCategory: ModelCategory?
    var pendingAskAnythingSessionID: UUID?
    var pendingModeSelectionID: UUID?
}
```

3. 在 `ModelSettingsTab.swift` 中处理 `pendingModelCategory`：
```swift
.onAppear {
    if let targetCategory = navigationModel.pendingModelCategory {
        selectedCategory = targetCategory
        navigationModel.pendingModelCategory = nil
    }
    // ... existing onAppear logic
}
.onChange(of: navigationModel.pendingModelCategory) { _, newCategory in
    if let newCategory {
        selectedCategory = newCategory
        navigationModel.pendingModelCategory = nil
    }
}
```

- [ ] **Step 4: 运行测试验证通过**

Run: `swift test --filter KeychainNotificationTests`
Expected: PASS.

- [ ] **Step 5: 提交改动**

```bash
git add Type4Me/Services/KeychainService.swift Type4Me/UI/Settings/SettingsView.swift Type4Me/UI/Settings/ModelSettingsTab.swift Tests/Type4MeTests/KeychainNotificationTests.swift
git commit -m "feat: add credentialsDidChange notification and pendingModelCategory routing"
```

---

### Task 2: `PermissionGuideModel` 状态机与真实 EventTap 探测重构

**Files:**
- Modify: `Type4Me/Permissions/PermissionGuideModel.swift`
- Test: `Tests/Type4MeTests/PermissionGuideModelTests.swift`

**Interfaces:**
- Consumes: `PermissionManager`, `KeychainService.selectedASRProvider`, `PermissionDragOverlayController`
- Produces: `PermissionGuideModel.hotkeyProbe`, `PermissionGuideModel.needsRestart`, `PermissionGuideModel.isAppleASRSelected`, `PermissionGuideModel.relaunchApp(...)`

- [ ] **Step 1: 编写 `PermissionGuideModel` 单元测试**

```swift
import XCTest
@testable import Type4Me

@MainActor
final class PermissionGuideModelTests: XCTestCase {
    func testNeedsRestartDetectionWhenHotkeyProbeFails() {
        let model = PermissionGuideModel()
        model.accessibilityGranted = true
        model.hotkeyProbe = { false } // simulate kernel cache failure
        model.refresh()
        XCTAssertTrue(model.needsRestart)
    }

    func testNeedsRestartFalseWhenHotkeyProbeSucceeds() {
        let model = PermissionGuideModel()
        model.accessibilityGranted = true
        model.hotkeyProbe = { true }
        model.refresh()
        XCTAssertFalse(model.needsRestart)
    }
}
```

- [ ] **Step 2: 运行测试验证失败**

Run: `swift test --filter PermissionGuideModelTests`
Expected: FAIL.

- [ ] **Step 3: 完善 `PermissionGuideModel.swift` 实现**

重构 `PermissionGuideModel.swift`，增加：
- `var speechGranted: Bool = false`
- `var isAppleASRSelected: Bool = false`
- `var needsRestart: Bool = false`
- `var hotkeyProbe: (() -> Bool)?`
- `var onFlowCompleteOrRaise: (() -> Void)?`
- `var requiredPermissionsGranted: Bool { micGranted && accessibilityGranted }`
- `func requestSpeechRecognition()`
- `func beginAccessibilityFlow(hostRaiseCallback: @escaping () -> Void)`
- `func relaunchApp(persistSetup: @escaping () -> Void)`

- [ ] **Step 4: 运行测试验证通过**

Run: `swift test --filter PermissionGuideModelTests`
Expected: PASS.

- [ ] **Step 5: 提交改动**

```bash
git add Type4Me/Permissions/PermissionGuideModel.swift Tests/Type4MeTests/PermissionGuideModelTests.swift
git commit -m "feat: add hotkey tap probing and relaunch mechanics to PermissionGuideModel"
```

---

### Task 3: `PermissionGuideView` 1:1 Screenflare 视觉重构

**Files:**
- Modify: `Type4Me/Permissions/PermissionGuideView.swift`

**Interfaces:**
- Consumes: `PermissionGuideModel`, `L(zh, en)`, `TF.amber`, `PermissionDragOverlay`
- Produces: `PermissionGuideView(model:embedded:onFinish:)`

- [ ] **Step 1: 编写视图静态结构与预览**

在 `PermissionGuideView.swift` 中实现：
1. 深色精致容器卡片风格：
   - 带有居中标题：`几项系统权限` / `A few permissions`
   - 副标题：`Type4Me 需要以下权限以录制语音并自动打字。录音数据仅在听写期间使用，绝不会离开你的 Mac。`
2. 分组权限列表容器（Grouped Container）：
   - 🔴 **麦克风 (必需)**：红橙渐变图标方块，标题 + `[ 必需 ]` 徽标，用途说明，右侧 `允许` / `已允许` 按钮。
   - 🔴 **辅助功能 (必需)**：蓝紫渐变图标方块，标题 + `[ 必需 ]` 徽标，用途说明，动态黄色提示 `已开启？macOS 可能需要在重启应用后生效。`，右侧 `允许` / `已允许` 按钮。
   - ⚪ **Apple 语音识别 (可选)**：仅当 `model.isAppleASRSelected == true` 时渲染，青绿渐变图标方块，标题 + `[ 可选 ]` 徽标，右侧 `允许` / `已允许` 按钮。
3. 底部次要提示文案：
   - `随时可以在 macOS「系统设置」中更改这些权限。`
4. 底部操作栏（Bottom Bar）：
   - 左下角：步骤圆点 `• •`
   - 右下角主按钮：
     - 若 `model.needsRestart` 为真：高亮蓝色胶囊按钮 **「重启 Type4Me」**；
     - 若未就绪：置灰禁用；
     - 若就绪：高亮琥珀金胶囊按钮 **「进入应用」/「Launch Type4Me」**（或向导中的下一步）。

- [ ] **Step 2: 编译验证**

Run: `swift build`
Expected: Build successfully without errors.

- [ ] **Step 3: 提交改动**

```bash
git add Type4Me/Permissions/PermissionGuideView.swift
git commit -m "feat: implement 1:1 Screenflare-style PermissionGuideView layout and interactions"
```

---

### Task 4: `SetupWizardView` 简化为 2 步与首启安全闭环

**Files:**
- Modify: `Type4Me/UI/Setup/SetupWizardView.swift`

**Interfaces:**
- Consumes: `PermissionGuideModel`, `AppState`, `AppEditionMigration`, `AppDelegate.presentSettings`
- Produces: 2-step Setup Wizard (`step 0: welcome`, `step 1: permissions`)

- [ ] **Step 1: 重构 `SetupWizardView.swift`**

1. 将向导步骤精简为：
   - `case 0: welcomeStep`
   - `default: permissionsStep`
2. `permissionsStep` 中嵌入 `PermissionGuideView(model: permissionGuideModel, embedded: true)`。
3. 提供 `completeSetupAndLaunchHome()` 方法：
   - 在 `#if HAS_CLOUD_SUBSCRIPTION` 下，若 `appState.appEdition == nil`，调用 `AppEditionMigration.switchTo(.byoKey)`。
   - 写入 `appState.hasCompletedSetup = true`。
   - 关闭向导窗口，调用 `AppDelegate.presentSettings()` 激活主界面首页。
4. 权限引导中的重启操作同样在调用 `model.relaunchApp` 前执行上述持久化。

- [ ] **Step 2: 编译与测试**

Run: `swift build`
Expected: Build successfully without errors.

- [ ] **Step 3: 提交改动**

```bash
git add Type4Me/UI/Setup/SetupWizardView.swift
git commit -m "feat: simplify SetupWizardView to 2 steps with safe cloud edition persistence"
```

---

### Task 5: 窗口注册与生命周期唤起修复 (Type4MeApp & MenuBarControlCenter)

**Files:**
- Modify: `Type4Me/UI/MenuBar/MenuBarControlCenter.swift`
- Modify: `Type4Me/Type4MeApp.swift`

**Interfaces:**
- Consumes: `openWindow(id: "setup")`, `openWindow(id: "settings")`, `openWindow(id: "permission-guide")`
- Produces: `AppDelegate.openSetupAction`, `AppDelegate.openSettingsAction`, `AppDelegate.presentSetupWizard()`, `AppDelegate.presentSettings()`

- [ ] **Step 1: 注册 `openSetupAction` 与 `openSettingsAction`**

在 `MenuBarControlCenter.swift` 的 `registerGlobalOpenActions` 中：
```swift
AppDelegate.openSetupAction = { [openWindow] in
    openWindow(id: "setup")
}
AppDelegate.openSettingsAction = { [openWindow] in
    openWindow(id: "settings")
}
```

- [ ] **Step 2: 完善 `Type4MeApp.swift` 中的窗口派发与探针注入**

1. 在 `AppDelegate` 中增加：
```swift
static var openSetupAction: (() -> Void)?
static var openSettingsAction: (() -> Void)?

func presentSetupWizard(retryCount: Int = 0) {
    if let action = Self.openSetupAction {
        action()
        NSApp.activate(ignoringOtherApps: true)
        return
    }
    guard retryCount < 15 else {
        NSLog("[App] Failed to present setup wizard after retries")
        return
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
        self?.presentSetupWizard(retryCount: retryCount + 1)
    }
}

static func presentSettings() {
    if let action = openSettingsAction {
        action()
        NSApp.activate(ignoringOtherApps: true)
    }
}
```
2. 注入 `hotkeyProbe`：
```swift
permissionGuideModel.hotkeyProbe = { [weak self] in
    self?.hotkeyManager.start() == true
}
```
3. 替换首启调用：
```swift
if needsSetup {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
        MainActor.assumeIsolated {
            if self?.suppressSetupWizardForHeadlessLaunch == true { return }
            self?.presentSetupWizard()
        }
    }
}
```

- [ ] **Step 3: 编译验证**

Run: `swift build`
Expected: Build successfully without errors.

- [ ] **Step 4: 提交改动**

```bash
git add Type4Me/UI/MenuBar/MenuBarControlCenter.swift Type4Me/Type4MeApp.swift
git commit -m "fix: register openSetupAction and implement robust presentSetupWizard routing"
```

---

### Task 6: 首页悬浮模型提醒卡片 (`FloatingModelAlertCards`)

**Files:**
- Modify: `Type4Me/UI/Settings/GeneralSettingsTab.swift`

**Interfaces:**
- Consumes: `KeychainService.selectedASRProvider`, `KeychainService.selectedLLMProvider`, `ModelSettingsHelpers.hasConfiguredCredentials`, `Notification.Name.credentialsDidChange`
- Produces: `FloatingModelAlertCards` overlay on `GeneralSettingsTab`

- [ ] **Step 1: 实现 `FloatingModelAlertCards` 视图与状态监听**

在 `GeneralSettingsTab.swift` 中实现右下角悬浮卡片栈：
1. 监听 `.credentialsDidChange` 与 `.asrProviderDidChange`。
2. 🔴 **红色卡片 (ASR)**：当 `!ModelSettingsHelpers.hasConfiguredCredentials(for: selectedASRProvider)` 时展示。点击后将 `navigationModel.selectedTab = .models` 并将 `navigationModel.pendingModelCategory = .asr`。
3. 🟠 **橙色卡片 (LLM)**：当 `!ModelSettingsHelpers.hasConfiguredCredentials(for: selectedLLMProvider)` 时展示。点击后将 `navigationModel.selectedTab = .models` 并将 `navigationModel.pendingModelCategory = .llm`。
4. 采用 Spring 动画与右侧滑入/滑出转场，配置完成后即刻自动消除。

- [ ] **Step 2: 编译验证**

Run: `swift build`
Expected: Build successfully without errors.

- [ ] **Step 3: 提交改动**

```bash
git add Type4Me/UI/Settings/GeneralSettingsTab.swift
git commit -m "feat: add FloatingModelAlertCards to GeneralSettingsTab for progressive model configuration"
```

---

### Task 7: 端到端构建、本地化校验与集成测试 (End-to-End Verification)

**Files:**
- Modify: `Type4Me/UI/Localization.swift` (补充所有缺失双语词条)
- Test: 全量单元测试与编译

- [ ] **Step 1: 补齐双语词条并验证中英双语覆盖**

检查所有新增与变动的 UI 文本，确保均使用 `L("中文", "English")`，并在 `Localization.swift` 中无编译警告。

- [ ] **Step 2: 运行完整测试套件**

Run: `swift test`
Expected: All test suites PASS.

- [ ] **Step 3: 运行 Release 构建验证**

Run: `swift build -c release`
Expected: Compiled successfully with zero warnings/errors.

- [ ] **Step 4: 提交最终改动**

```bash
git add Type4Me/UI/Localization.swift
git commit -m "chore: ensure full bilingual localization coverage for permission onboarding"
```
