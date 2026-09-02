# Type4Me 权限引导与首启流程开发设计

> 文档类型：开发设计  
> 文档状态：设计完成，待审阅  
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
        CheckSetup -- 否 --> OpenSetup[openSetupWindowAction]
        CheckSetup -- 是 --> CheckPerms{必需权限已齐备?}
        CheckPerms -- 否 --> OpenGuide[openPermissionGuideAction]
        CheckPerms -- 是 --> RegisterHotkey[启动快捷键监听]
    end

    subgraph SetupFlow [首启流程 SetupWizardView]
        OpenSetup --> StepWelcome[Step 0: WelcomeView]
        StepWelcome --> StepPerms[Step 1: Screenflare PermissionGuideView]
        StepPerms -->|完成/重启| FinishSetup[写入 hasCompletedSetup = true<br/>关闭向导，打开 SettingsView]
    end

    subgraph PermGuide [权限状态机 PermissionGuideModel]
        StepPerms -.-> Model[PermissionGuideModel]
        Model --> Mic[AVCaptureDevice]
        Model --> AX[AXIsProcessTrusted + PermissionDragOverlay]
        Model --> Speech[SFSpeechRecognizer]
        AX --> CheckTap[EventTap 状态检测]
        CheckTap -->|需重启| NeedsRestart[needsRestart = true]
    end

    subgraph HomeAlerts [首页提醒 SettingsView / GeneralSettingsTab]
        FinishSetup --> Home[GeneralSettingsTab]
        Home --> CheckASRConfig{ModelSettingsHelpers.hasConfiguredCredentials(ASR)}
        Home --> CheckLLMConfig{ModelSettingsHelpers.hasConfiguredCredentials(LLM)}
        CheckASRConfig -- 未配置 --> CardASR[🔴 ASR 悬浮提醒卡片]
        CheckLLMConfig -- 未配置 --> CardLLM[🟠 LLM 悬浮提醒卡片]
        CardASR -->|点击| JumpASR[AppNavigationModel: tab=.models, category=.asr]
        CardLLM -->|点击| JumpLLM[AppNavigationModel: tab=.models, category=.llm]
    end
```

---

## 2. 模块与状态设计

### 2.1 `PermissionGuideModel` 状态机增强
`PermissionGuideModel` 负责统一的权限请求、轮询探测与重启状态管理：

```swift
@MainActor
@Observable
final class PermissionGuideModel {
    // 权限状态
    var micGranted: Bool = false
    var accessibilityGranted: Bool = false
    var speechGranted: Bool = false

    // 辅助功能是否已在系统设置开启但内核事件监听需要重启生效
    var needsRestart: Bool = false

    // 拖拽浮层状态
    var isDragOverlayShown: Bool = false

    // 计算属性：必需权限是否均已满足
    var requiredPermissionsGranted: Bool {
        micGranted && accessibilityGranted
    }

    // 刷新各权限状态
    func refresh() {
        micGranted = PermissionManager.hasMicrophonePermission
        accessibilityGranted = PermissionManager.hasAccessibilityPermission
        speechGranted = PermissionManager.hasSpeechRecognitionPermission
    }

    // 触发麦克风授权
    func requestMicrophone() { ... }

    // 触发辅助功能授权流程（打开设置 + 显示底部拖拽浮层 + 启动 0.5s 轮询）
    func beginAccessibilityFlow() { ... }

    // 触发 Apple 语音识别授权
    func requestSpeechRecognition() { ... }

    // 执行应用重启
    func relaunchApp() {
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

### 2.2 `SetupWizardView` 极简重构
将 `SetupWizardView` 简化为 2 个步骤：
- **`step = 0` (Welcome)**：品牌图标、定位文本与「开始设置」主按钮；
- **`step = 1` (Permissions)**：Screenflare 风格的 `PermissionGuideView(embedded: true)`；
- 完成动作：调用 `appState.hasCompletedSetup = true`，关闭当前窗口，并调用 `AppDelegate.openSettingsAction?()` 打开主应用首页。

```swift
struct SetupWizardView: View {
    @Environment(AppState.self) private var appState
    @Environment(PermissionGuideModel.self) private var permissionGuideModel
    @State private var step = 0
    @AppStorage("tf_language") private var language = AppLanguage.systemDefault

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch step {
                case 0: welcomeStep
                default: permissionsStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(TF.springGentle, value: step)
        }
        .frame(width: 640, height: 480)
        .id(language)
    }
}
```

---

### 2.3 `PermissionGuideView` 视觉重构 (Screenflare 规范)
重构 `PermissionGuideView`，使其在深色卡片中呈现居中头部、分组权限列表与底部自愈操作栏：

```swift
struct PermissionGuideView: View {
    @Bindable var model: PermissionGuideModel
    let embedded: Bool

    var body: some View {
        VStack(spacing: 16) {
            // 1. 顶部 Header
            headerSection

            // 2. 分组权限列表容器
            permissionGroupContainer {
                microphoneRow
                divider
                accessibilityRow
                divider
                speechRecognitionRow
            }

            // 3. 底部次要提示
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

### 2.4 首页模型配置悬浮提醒卡片 (`FloatingModelAlertCards`)

在 `SettingsView` 的右下角挂载一个轻量悬浮提醒视图层：

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

并在 `AppNavigationModel` 中支持指定子类别：
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

---

### 2.5 修复 `Type4MeApp.swift` 唤起机制

将原本失效的 `sendAction(Selector(("showSetupWindow:")), ...)` 替换为原生注册的 SwiftUI 打开闭包：

```swift
// AppDelegate 增加静态动作分发
static var openSetupAction: (() -> Void)?
static var openSettingsAction: (() -> Void)?
static var openPermissionGuideAction: (() -> Void)?

// 首启检测调用
if needsSetup {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
        MainActor.assumeIsolated {
            if self?.suppressSetupWizardForHeadlessLaunch == true { return }
            Self.openSetupAction?()
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
```

---

## 3. 涉及文件与改动清单 (Files Touched)

| 文件路径 | 变动职责 |
|---|---|
| `Type4Me/UI/Setup/SetupWizardView.swift` | 简化向导为 2 步，移除冗余服务商表单，集成首启完成自动跳转首页 |
| `Type4Me/Permissions/PermissionGuideView.swift` | 1:1 重构为 Screenflare 风格深色卡片、分组权限列表与底部操作栏 |
| `Type4Me/Permissions/PermissionGuideModel.swift` | 新增语音识别授权、重启状态检测 `needsRestart` 与应用重启执行 `relaunchApp()` |
| `Type4Me/Type4MeApp.swift` | 绑定 `openSetupAction` / `openSettingsAction`，修复首启自动唤起与权限恢复路由 |
| `Type4Me/UI/Settings/SettingsView.swift` | 在右下角叠加 `FloatingModelAlertCards`，处理模型类别自动切换 |
| `Type4Me/UI/Settings/ModelSettingsTab.swift` | 响应 `navigationModel.pendingModelCategory`，自动定位 ASR / LLM 选项卡 |
| `Type4Me/UI/Localization.swift` | 补充双语对照文案（全链路 `L(zh, en)`） |

---

## 4. 验证与回归计划

1. **首次启动冷启动验证**：
   - 清除 `tf_hasCompletedSetup` 偏好，启动应用，确认自动弹出 640×480 尺寸的精致向导。
   - 点击「开始设置」，平滑转场至步骤 2 权限页。
2. **Screenflare 权限流与拖拽浮层验证**：
   - 点击麦克风「允许」，验证系统麦克风授权与「已允许」状态切换。
   - 点击辅助功能「允许」，验证系统设置 Accessibility 页面自动打开，且屏幕底部准确弹出 `PermissionDragOverlay` 拖拽条。
   - 验证状态变更后卡片即刻变为绿色勾选，当需要重启时右下角按钮变为「重启 Type4Me」。
3. **完成并进入首页验证**：
   - 点击「进入应用」，验证向导关闭并自动唤起主界面首页（`SettingsTab.general`）。
4. **首页模型提示卡片与跳转验证**：
   - 在未配置 ASR / LLM 时，验证右下角准确浮现 🔴 红色与 🟠 橙色卡片。
   - 点击卡片，验证平滑跳转至「模型」设置页并自动选中对应 ASR / LLM 类别。
   - 填入有效凭证或选择 Apple Speech / Codex CLI 后返回首页，验证卡片平滑淡出消除。
5. **动态语言切换验证**：
   - 在中文与英文之间切换 `tf_language`，确认向导、权限页、提示卡片所有文本均实时热刷新。
