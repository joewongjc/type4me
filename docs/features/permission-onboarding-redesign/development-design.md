# Type4Me 权限引导与首启流程开发设计

> 文档类型：开发设计  
> 文档状态：当前有效（已实现，持续验证）
> 最后校验：2026-09-05
> 实现基线：`5fce88f`
> 设计日期：2026-09-02  
> 对应分支：`feat/permission-onboarding-redesign`  
> 对应产品设计：[product-design.md](product-design.md)  

---

## 1. 架构总览

本功能对 Type4Me 的首启向导、权限管理与主界面模型引导进行端到端重构：

```mermaid
graph TD
    subgraph AppLifecycle [应用生命周期 Type4MeApp]
        Launch[didFinishLaunching] --> CheckSetup{hasCompletedSetup?}
        CheckSetup -- 否 --> PresentSetup[presentSetupWizard - 带重试]
        CheckSetup -- 是 --> CheckPerms{必需权限已齐备?}
        CheckPerms -- 否 --> PresentGuide[presentPermissionGuide - 带重试]
        CheckPerms -- 是 --> RegisterHotkey[启动快捷键监听]
    end

    subgraph SetupFlow [首启流程 SetupWizardView]
        PresentSetup --> StepWelcome[Step 0: WelcomeView]
        StepWelcome --> StepPerms[Step 1: Screenflare PermissionGuideView]
        StepPerms -->|完成/重启| FinishSetup[写入 hasCompletedSetup = true 及默认 Edition<br/>关闭向导，打开 SettingsView]
    end

    subgraph PermGuide [权限状态机 PermissionGuideModel]
        StepPerms -.-> Model[PermissionGuideModel]
        Model --> Mic[AVCaptureDevice]
        Model --> AX[AXIsProcessTrusted + PermissionDragOverlay]
        Model --> Speech[SFSpeechRecognizer - 仅在 Apple ASR 时呈现]
        AX --> ProbeTap[注入 hotkeyProbe 闭包执行实际 Tap 测试]
        ProbeTap -->|Tap 失败| NeedsRestart[needsRestart = true]
    end

    subgraph HomeAlerts [首页提醒 GeneralSettingsTab]
        FinishSetup --> Home[GeneralSettingsTab]
        Home --> CheckASRConfig{ModelSettingsHelpers.hasConfiguredCredentials(ASR)}
        Home --> CheckLLMConfig{ModelSettingsHelpers.hasConfiguredCredentials(LLM)}
        CheckASRConfig -- 未配置 --> CardASR[🔴 ASR 悬浮提醒卡片]
        CheckLLMConfig -- 未配置 --> CardLLM[🟠 LLM 悬浮提醒卡片]
        CardASR -->|点击| JumpASR[AppNavigationModel: tab=.models, category=.asr]
        CardLLM -->|点击| JumpLLM[AppNavigationModel: tab=.models, category=.llm]
        ModelsChanged[Notification.Name.credentialsDidChange] -->|订阅触发| RefreshCards[实时刷新卡片显示状态]
    end
```

---

## 2. 详细技术实现方案与 Review 改进

### 2.1 `PermissionGuideModel` 状态机与真实 EventTap 探测

`PermissionGuideModel` 不仅依赖 `AXIsProcessTrusted()`，还必须探测真实的快捷键 EventTap 是否生效（以应对 macOS 内核缓存导致授权后仍需重启的问题）：

```swift
@MainActor
@Observable
final class PermissionGuideModel {
    // MARK: - Observable State
    var micGranted: Bool = false
    var accessibilityGranted: Bool = false
    var speechGranted: Bool = false
    var isAppleASRSelected: Bool = false

    /// 当辅助功能已开启 (AXIsProcessTrusted == true)，但内核 EventTap 仍失败时，置为 true
    var needsRestart: Bool = false
    var isDragOverlayShown: Bool = false

    var requiredPermissionsGranted: Bool {
        micGranted && accessibilityGranted
    }

    // MARK: - Injected Probes & Callbacks
    /// 注入由 AppDelegate 提供的真实 Hotkey tap 探测闭包
    var hotkeyProbe: (() -> Bool)?
    /// 宿主窗口唤醒回调（区分向导 embedded 还是独立 guide 窗口）
    var onFlowCompleteOrRaise: (() -> Void)?

    // MARK: - Lifecycle & Actions
    func refresh() {
        micGranted = PermissionManager.hasMicrophonePermission
        accessibilityGranted = PermissionManager.hasAccessibilityPermission
        speechGranted = PermissionManager.hasSpeechRecognitionPermission
        isAppleASRSelected = (KeychainService.selectedASRProvider == .apple)

        if accessibilityGranted {
            if let probe = hotkeyProbe {
                let tapOk = probe()
                needsRestart = !tapOk
            } else {
                needsRestart = false
            }
        } else {
            needsRestart = false
        }
    }

    func requestMicrophone() { ... }

    func beginAccessibilityFlow(hostRaiseCallback: @escaping () -> Void) {
        self.onFlowCompleteOrRaise = hostRaiseCallback
        PermissionManager.openAccessibilitySettings()
        isDragOverlayShown = true
        dragOverlay.show(
            appName: "Type4Me",
            permissionName: L("辅助功能", "Accessibility")
        ) { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.isDragOverlayShown = false
                self.refresh()
                NSApp.activate(ignoringOtherApps: true)
                // 仅唤起发起该流程的宿主窗口，避免错开独立 guide 窗口
                self.onFlowCompleteOrRaise?()
            }
        }
    }

    func requestSpeechRecognition() { ... }

    /// 执行重启，且在重启前确保持久化首启状态
    func relaunchApp(persistSetup: @escaping () -> Void) {
        persistSetup()
        let url = Bundle.main.bundleURL
        let task = Process()
        task.launchPath = "/usr/bin/open"
        task.arguments = ["-n", url.path]
        try? task.run()
        NSApp.terminate(nil)
    }
}
```

---

### 2.2 `SetupWizardView` 极简重构与云版本状态兼容

1. **步骤精简为 2 步**（`step = 0: Welcome`, `step = 1: Permissions`）。
2. **云版本状态安全闭环**：若在带有 `HAS_CLOUD_SUBSCRIPTION` 标记的环境下编译，完成首启或重启前自动将默认版本设为 `.byoKey`（`AppEditionMigration.switchTo(.byoKey)`），确保 `appState.appEdition != nil` 且 `appState.hasCompletedSetup = true`，彻底防止重启后重复陷入向导循环。
3. **完成动作**：
   ```swift
   private func completeSetupAndLaunchHome() {
       #if HAS_CLOUD_SUBSCRIPTION
       if appState.appEdition == nil {
           AppEditionMigration.switchTo(.byoKey)
       }
       #endif
       appState.hasCompletedSetup = true
       NSApp.keyWindow?.close()
       AppDelegate.presentSettings()
   }
   ```

---

### 2.3 `PermissionGuideView` 视觉重构 (Screenflare 规范)

重构 `PermissionGuideView`，支持 Screenflare 风格的高保真深色卡片布局：

```swift
struct PermissionGuideView: View {
    @Bindable var model: PermissionGuideModel
    let embedded: Bool
    var onFinish: (() -> Void)?

    var body: some View {
        VStack(spacing: 16) {
            // 1. 顶部 Header
            headerSection

            // 2. 分组权限列表容器
            VStack(spacing: 0) {
                microphoneRow
                dividerLine
                accessibilityRow
                // 仅当当前选择 Apple Speech 或支持 Apple 语音识别时条件渲染
                if model.isAppleASRSelected {
                    dividerLine
                    speechRecognitionRow
                }
            }
            .background(Color.white.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.white.opacity(0.1), lineWidth: 1)
            )

            // 3. 底部说明
            footerNote

            // 4. 底部操作栏（步骤点 + 主操作按钮：重启 Type4Me / 进入应用）
            bottomBar
        }
        .padding(28)
        .background(screenflareCardBackground)
        .preferredColorScheme(.dark)
        .onAppear { model.refresh() }
    }
}
```

---

### 2.4 凭证变更广播与首页悬浮提醒卡片 (`FloatingModelAlertCards`)

#### A. 统一广播 `Notification.Name.credentialsDidChange`
在 `KeychainService` 中，当以下事件发生时统一发布通知：
1. `saveASRCredentials(...)` 保存成功时；
2. `saveLLMCredentials(...)` 保存成功时；
3. `selectedASRProvider` 变更时；
4. `selectedLLMProvider` 变更时。

```swift
extension Notification.Name {
    static let credentialsDidChange = Notification.Name("tf_credentialsDidChange")
}
```

#### B. 首页提醒卡片悬浮层
将 `FloatingModelAlertCards` 挂载在 `GeneralSettingsTab` 的右下角（或限制在 `selectedTab == .general`），避免遮挡模型编辑 Tab：

```swift
struct FloatingModelAlertCards: View {
    @Environment(AppNavigationModel.self) private var navigationModel
    @State private var isASRMissing: Bool = false
    @State private var isLLMMissing: Bool = false

    var body: some View {
        VStack(alignment: .trailing, spacing: 10) {
            if isASRMissing {
                alertCard(
                    color: .red,
                    icon: "waveform.badge.exclamationmark",
                    title: L("需配置默认语音识别模型", "Configure Speech Recognition Model"),
                    subtitle: L("点击前往模型页配置 API Key 或本地模型", "Click to set up API keys or local models"),
                    action: {
                        navigationModel.selectedTab = .models
                        navigationModel.pendingModelCategory = .asr
                    }
                )
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }

            if isLLMMissing {
                alertCard(
                    color: TF.amber,
                    icon: "sparkles",
                    title: L("需配置默认文本润色模型", "Configure Text Polishing Model"),
                    subtitle: L("用于智能纠错、标点与改写", "Used for smart punctuation and rewriting"),
                    action: {
                        navigationModel.selectedTab = .models
                        navigationModel.pendingModelCategory = .llm
                    }
                )
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .padding(20)
        .animation(.spring(response: 0.35, dampingFraction: 0.82), value: isASRMissing)
        .animation(.spring(response: 0.35, dampingFraction: 0.82), value: isLLMMissing)
        .task { checkModelStatus() }
        .onReceive(NotificationCenter.default.publisher(for: .credentialsDidChange)) { _ in
            checkModelStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: .asrProviderDidChange)) { _ in
            checkModelStatus()
        }
    }

    private func checkModelStatus() {
        let currentASR = KeychainService.selectedASRProvider
        let currentLLM = KeychainService.selectedLLMProvider
        isASRMissing = !ModelSettingsHelpers.hasConfiguredCredentials(for: currentASR)
        isLLMMissing = !ModelSettingsHelpers.hasConfiguredCredentials(for: currentLLM)
    }
}
```

---

### 2.5 修复 `Type4MeApp.swift` 窗口注册与启动唤起机制

1. **注册 `openSetupAction`**：
   在 `MenuBarControlCenter.swift` 的 `registerGlobalOpenActions` 中增加对 `setup` 窗口的注册：
   ```swift
   AppDelegate.openSetupAction = { [openWindow] in
       openWindow(id: "setup")
   }
   ```
2. **实现健壮的重试唤起机制 `presentSetupWizard()`**：
   ```swift
   static var openSetupAction: (() -> Void)?

   func presentSetupWizard(retryCount: Int = 0) {
       if let action = Self.openSetupAction {
           action()
           NSApp.activate(ignoringOtherApps: true)
           return
       }
       guard retryCount < 10 else {
           NSLog("[App] Failed to present setup wizard: open action not registered after retries")
           return
       }
       DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
           self?.presentSetupWizard(retryCount: retryCount + 1)
       }
   }
   ```

---

## 3. 涉及文件与改动清单 (Files Touched)

| 文件路径 | 变动职责 |
|---|---|
| `Type4Me/UI/Setup/SetupWizardView.swift` | 简化向导为 2 步，移除冗余服务商表单，集成首启完成及云版本安全持久化 |
| `Type4Me/Permissions/PermissionGuideView.swift` | 1:1 重构为 Screenflare 风格深色卡片、分组权限列表与底部操作栏 |
| `Type4Me/Permissions/PermissionGuideModel.swift` | 接入 `hotkeyProbe` 真实探测、`onFlowCompleteOrRaise` 宿主闭包、持久化重启 `relaunchApp` |
| `Type4Me/Type4MeApp.swift` | 绑定 `openSetupAction` / `presentSetupWizard()`，注入 `hotkeyProbe` 到 `PermissionGuideModel` |
| `Type4Me/UI/MenuBar/MenuBarControlCenter.swift` | 注册全局 `AppDelegate.openSetupAction` |
| `Type4Me/Services/KeychainService.swift` | 在 ASR/LLM 凭证保存与提供商变更时广播 `credentialsDidChange` 通知 |
| `Type4Me/UI/Settings/GeneralSettingsTab.swift` | 在首页右下角集成 `FloatingModelAlertCards` |
| `Type4Me/UI/Settings/SettingsView.swift` | `AppNavigationModel` 支持 `pendingModelCategory`，并在 Tab 切换时联动 |
| `Type4Me/UI/Settings/ModelSettingsTab.swift` | 响应 `navigationModel.pendingModelCategory`，自动定位 ASR / LLM 选项卡 |
| `Type4Me/UI/Localization.swift` | 补充双语对照文案（全链路 `L(zh, en)`） |

---

## 4. 验证与回归计划

1. **首次启动冷启动验证**：
   - 清除 `tf_hasCompletedSetup`（及云版本 `tf_app_edition`），启动应用，确认通过带重试的 `presentSetupWizard()` 稳定弹出 640×480 尺寸的精致向导。
   - 点击「开始设置」，平滑转场至步骤 2 权限页。
2. **Screenflare 权限流与拖拽浮层验证**：
   - 点击麦克风「允许」，验证系统麦克风授权与「已允许」状态切换。
   - 点击辅助功能「允许」，验证系统设置 Accessibility 页面自动打开，且屏幕底部准确弹出 `PermissionDragOverlay` 拖拽条；拖拽授权完成后仅回到发起向导窗口。
   - 验证通过 `hotkeyProbe` 进行真实的 EventTap 探测；当系统要求重启时，右下角按钮准确变为「重启 Type4Me」。
   - 点击「重启 Type4Me」，验证首启状态已正确写入并自动以新进程拉起应用。
3. **完成并进入首页验证**：
   - 点击「进入应用」，验证向导关闭并自动唤起主界面首页（`SettingsTab.general`）。
4. **首页模型提示卡片与跳转验证**：
   - 在未配置 ASR / LLM 时，验证仅在首页右下角浮现 🔴 红色与 🟠 橙色卡片。
   - 点击卡片，验证平滑跳转至「模型」设置页并自动选中对应 ASR / LLM 类别。
   - 填入有效凭证保存后，验证通过 `credentialsDidChange` 通知使得首页卡片平滑淡出消除。
5. **动态语言切换验证**：
   - 在中文与英文之间切换 `tf_language`，确认向导、权限页、提示卡片所有文本均实时热刷新。
