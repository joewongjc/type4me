# Type4Me URL 录音控制开发设计

> 分支：`feat/194-url-recording-commands`
> 文档类型：开发设计
> 文档状态：已实现
> 对应 Issue：[#194](https://github.com/joewongjc/type4me/issues/194)
> 设计日期：2026-08-24
> 实现基线：`e4b4627a4ca6a20d8ec506008341840f0f5a1ca3`
> 目标版本：Type4Me 2.x
> 对应产品设计：`docs/features/url-recording-commands/product-design.md`

## 1. 设计摘要

Issue #194 不需要新的录音引擎，也不应该新增第二套录音状态机。

当前代码已经具备两个关键基础：

1. `AppDelegate.application(_:open:)` 已负责 URL Scheme 白名单与命令分发；
2. `AppDelegate` 已拥有统一录音启动和完成路径，包括 `requestRecordingStart(mode:source:)`、`RecordingControlCoordinator`、`RecognitionSession`、`RecordingStartGate` 和 `AppState.barPhase`。

因此本功能只增加一层**录音 URL command routing**：

```text
URL Scheme
   ↓
AppDelegate URL router
   ↓
External recording command
   ↓
Existing AppDelegate recording APIs
   ↓
AppState / RecordingControlCoordinator / RecognitionSession
```

禁止 URL handler 直接操作音频引擎、伪造 HotkeyBinding 或复制快捷键状态机。

## 2. 当前实现基线

### 2.1 URL Scheme

`Sources/Type4Me/Type4MeApp.swift` 已实现：

```swift
func application(_ application: NSApplication, open urls: [URL])
```

现有 host 包括：

- `vocabulary`；
- `reload-vocabulary`；
- `auth`（no-op）；
- `settings` / `preferences`。

Scheme 通过 `CFBundleURLSchemes` 动态读取，fallback 为 `type4me`。因此新增录音 command 不需要修改 Scheme 注册架构。

### 2.2 录音启动

当前共享启动入口：

```swift
private func requestRecordingStart(
    mode: ProcessingMode,
    source: RecordingStartSource
)
```

它已经负责：

- phase guard；
- ASR Provider 下的 Mode resolve；
- Selection Ask 新问题准备；
- `RecordingStartGate` generation；
- `requestedAt`；
- `appState.selectModeForRecording`；
- `appState.startRecording()`；
- `session.awaitIdle()`；
- gate 二次校验；
- `session.startRecording(mode:requestedAt:)`。

URL start 必须调用它，而不是复制这些步骤。

### 2.3 录音完成

`RecordingControlCoordinator.perform(_:)` 先处理 Selection Ask follow-up，再调用标准录音控制。

标准 finish 已正确区分：

- `.preparing` → `session.cancelRecording()`；
- `.recording` → `session.stopRecording()`。

URL stop/toggle-stop 应复用 `recordingControlCoordinator.perform(.finish)`。

## 3. 目标代码结构

第一版优先小改动，不为了三个 command 引入大型 router framework。

推荐在 `Type4MeApp.swift` 中增加窄的 command enum 与方法；如果测试性需要，可把纯解析逻辑提取到 `Services`。

建议结构：

```swift
enum RecordingURLCommand: Equatable {
    case start
    case stop
    case toggle
}
```

可选 parser：

```swift
enum RecordingURLCommandParser {
    static func parse(_ url: URL) -> RecordingURLCommand?
}
```

第一版 host 不带参数，因此 parser 可以保持极小。

AppDelegate 增加：

```swift
private func handleRecordingURLCommand(_ command: RecordingURLCommand)
private func requestURLRecordingStart()
private func requestURLRecordingStop()
```

## 4. Command routing

### 4.1 URL host

在现有 `application(_:open:)` switch 中增加：

```swift
case "start":
    handleRecordingURLCommand(.start)
case "stop":
    handleRecordingURLCommand(.stop)
case "toggle":
    handleRecordingURLCommand(.toggle)
```

所有 Scheme 校验继续使用现有 `registeredURLSchemes()`。

### 4.2 Recording source

扩展：

```swift
enum RecordingStartSource: String {
    case hotkey
    case menuBar
    case reviseHotkey
    case reviseMenuBar
    case urlScheme
}
```

这样启动日志可以区分 URL 来源：

```text
urlScheme record start mode=...
```

日志不得包含录音文本或其他用户正文。

## 5. 状态语义

URL command 的业务真相来自 `appState.barPhase`。

### 5.1 start

实现：

```swift
private func requestURLRecordingStart() {
    switch appState.barPhase {
    case .hidden, .done, .error:
        requestRecordingStart(
            mode: appState.currentMode,
            source: .urlScheme
        )
    case .preparing, .recording, .processing, .recovering:
        DebugFileLogger.log("url start ignored phase=\(appState.barPhase)")
    }
}
```

即使 `requestRecordingStart` 自身已有 phase guard，也建议 URL 层显式表达协议语义，便于测试和日志。

### 5.2 stop

实现：

```swift
private func requestURLRecordingStop() {
    switch appState.barPhase {
    case .preparing, .recording:
        recordingControlCoordinator.perform(.finish)
    case .hidden, .processing, .recovering, .done, .error:
        DebugFileLogger.log("url stop ignored phase=\(appState.barPhase)")
    }
}
```

不能直接调用：

```swift
appState.stopRecording()
session.stopRecording()
```

否则可能绕过 Selection Ask follow-up 和标准 cleanup。

### 5.3 toggle

```swift
private func requestURLRecordingToggle() {
    switch appState.barPhase {
    case .hidden, .done, .error:
        requestURLRecordingStart()
    case .preparing, .recording:
        requestURLRecordingStop()
    case .processing, .recovering:
        DebugFileLogger.log("url toggle ignored phase=\(appState.barPhase)")
    }
}
```

`toggle` 不维护自己的 boolean。

## 6. Current Mode resolution

### 6.1 输入

URL start 传入：

```swift
appState.currentMode
```

### 6.2 Provider resolution

不在 URL 层重新解析 Provider compatibility。

继续由既有：

```swift
requestRecordingStart(mode:source:)
```

调用：

```swift
ASRProviderRegistry.resolvedMode(for:provider:)
```

从而保持 URL、菜单和快捷键行为一致。

### 6.3 不新增 name-based lookup

第一版不读取 `mode` query item，不按 `ProcessingMode.name` 查找模式。

这样避免：

- 本地化名称；
- 用户重命名；
- 自定义模式重名；
- API 与 UI 文案耦合。

## 7. 与 HotkeyManager 的交互

### 7.1 不伪造快捷键

禁止：

- 创建假的 `ModeBinding`；
- 调用 CGEvent 模拟热键；
- 改写 active key state 来“假装按键”。

URL command 是 AppDelegate 的新 command source，不是 HotkeyManager 的输入设备。

### 7.2 URL 启动后按快捷键

现有 Hotkey `onStart` 已检查 `appState.barPhase`。当 URL 已经启动录音时，如果 toggle-style hotkey 产生不一致的 onStart，当前逻辑会检测 `.preparing/.recording` 并重定向 STOP，防止丢弃累计文本。

实现后应增加回归测试或手工验证：

1. URL start；
2. 按当前模式 toggle hotkey；
3. 应正常结束当前 URL Session，而不是开始第二轮。

### 7.3 Cross-mode finish

URL start 使用 `appState.currentMode`。之后用户按另一 Mode 的快捷键时，继续遵循现有 `onCrossModeFinish` 和 `CrossModeFinishPreference`。

URL 层不参与 mode switch 决策。

## 8. Selection Ask / 特殊模式

`appState.currentMode` 可能是 `.selectionAsk` execution kind。

URL start 不应自己判断并复制 Selection Ask 流程；必须把 Mode 交给 `requestRecordingStart`，由现有：

```swift
if effectiveMode.executionKind == .selectionAsk {
    askAnythingCoordinator.prepareForExternalNewQuestion()
}
```

处理。

URL stop 使用 `RecordingControlCoordinator`，从而保留 active follow-up routing。

需要特别测试 Selection Ask 当前 Mode 的 URL start/stop，避免“普通录音能工作、Ask Anything 走错 owner”。

## 9. Preparing 状态

`.preparing` 是最容易出现竞态的阶段。

要求：

- start during preparing → no-op；
- stop/toggle during preparing → 通过 `RecordingControlCoordinator.perform(.finish)`；
- `RecordingStartGate` 必须确保被终止的 pending start 不会在 `awaitIdle()` 后继续启动 Session。

如果现有 finish 路径不能 invalidate `RecordingStartGate`，实现阶段必须补齐这一竞态，并同步检查菜单栏完成录音是否存在相同问题。

该项是实现阶段的重点代码审查点。

## 10. URL parser 与输入校验

第一版三个命令不接受 query 参数。

建议策略：

- host 大小写按现有 URL 规范统一处理或明确只接受 lowercase；
- `/path` 不参与 command；
- query item 可选择忽略或拒绝，但必须测试并固定语义。

推荐**拒绝未知参数**，保持外部 API 可预测：

```text
type4me://start?mode=code
```

在第一版不应悄悄忽略 `mode`，否则用户会误以为指定模式已经生效。

如果采用严格 parser，可复用 Vocabulary URL 的设计思想：允许字段白名单、重复参数拒绝、错误只记诊断日志。

## 11. 测试设计

### 11.1 Parser tests

如果提取 `RecordingURLCommandParser`，覆盖：

- `type4me://start`；
- `type4me://stop`；
- `type4me://toggle`；
- Dev / Personal Scheme；
- 未注册 Scheme；
- unknown host；
- query 参数策略；
- duplicate query 参数（如 parser 明确禁止）。

### 11.2 State routing tests

推荐把 phase → action 判断提取为纯逻辑，例如：

```swift
enum RecordingURLDecision: Equatable {
    case start
    case finish
    case ignore
}
```

这样可直接覆盖矩阵：

| command | hidden | preparing | recording | processing | recovering | done | error |
| --- | --- | --- | --- | --- | --- | --- | --- |
| start | start | ignore | ignore | ignore | ignore | start | start |
| stop | ignore | finish | finish | ignore | ignore | ignore | ignore |
| toggle | start | finish | finish | ignore | ignore | start | start |

### 11.3 Integration tests

至少覆盖：

- URL start 选择 `appState.currentMode`；
- start 复用 Provider-resolved effective mode；
- URL stop 进入 `RecordingControlCoordinator`；
- preparing stop 不会在 gate 后重新启动；
- Selection Ask current mode；
- URL start 后可用 hotkey finish；
- URL start 后可用 menu/floating finish；
- processing 阶段 start/toggle 不开启第二个 Session。

### 11.4 手工 DEV App 验收

```bash
open 'type4me-dev://start'
open 'type4me-dev://stop'
open 'type4me-dev://toggle'
```

验证场景：

1. TextEdit / 浏览器输入框；
2. Stream Deck 或等价工具连续两次 toggle；
3. 快速连续多次 start；
4. preparing 阶段立即 stop；
5. processing 时再次 toggle；
6. 切换不同 current mode 后 start；
7. current mode 为 Ask Anything；
8. URL start 后使用快捷键结束。

## 12. README 更新

实现完成后更新 README 中英文 URL Scheme 章节。

新增：

```text
type4me://start
type4me://stop
type4me://toggle
```

说明：

- `start` 使用当前 mode；
- `stop` 是正常 finish，不是 cancel；
- `toggle` 适合 Stream Deck；
- Dev / Personal 仅替换 Scheme prefix；
- 第一版不支持 `?mode=`。

## 13. 变更范围预估

预计主要修改：

```text
Sources/Type4Me/Type4MeApp.swift
Tests/Type4MeTests/...URL...Tests.swift
README.md
docs/features/url-recording-commands/product-design.md
docs/features/url-recording-commands/development-design.md
```

如果纯 parser/decision 类型足够独立，可以新增：

```text
Sources/Type4Me/Services/RecordingURLCommands.swift
```

但第一版应避免为了形式拆出过多文件。

## 14. 风险与审查重点

### 14.1 Preparing race

停止 pending start 后必须保证 gate 失效，不能出现 UI 已停止但 Session 随后启动。

### 14.2 多控制面一致性

URL、快捷键、菜单栏、浮动条必须操作同一个 Session owner 与 phase truth。

### 14.3 Current Mode 与 active recording mode

URL start 使用调用瞬间的 `appState.currentMode`；录音开始后 Session 使用冻结的 effective mode。后续 UI 切换不应偷偷改变本轮。

### 14.4 URL 是公开接口

一旦发布，`start` / `stop` / `toggle` 的幂等语义应视为兼容承诺。不要以后把 `start` 改成 toggle，也不要让 `stop` 变成 cancel。

### 14.5 前台焦点保护与后台调用 (`-g`) 规范

1. **调用层最佳实践**：推荐使用 `open -g 'type4me://toggle'`（`-g` / `--background`），使 macOS LaunchServices 在纯后台派发 URL AppleEvent，彻底杜绝系统级前台 App 切换和输入光标抖动。
2. **App 层焦点防御与注入恢复**：
   - `AppDelegate.handleRecordingURL` 收到控制命令时，若 App 处于 active 状态，立即调用 `NSApp.hide(nil)` 归还焦点给原前台应用；
   - `RecognitionSession` 启动时记录前台 `targetApplication`，注入文本前若目标应用未激活则执行 `target.activate()`，确保 `Cmd+V` 稳定注入目标输入控件；
   - `TextInjectionEngine` 在模拟粘贴前检测并避让自身前台状态。

## 15. 实施顺序

1. 添加纯 command / decision 类型与测试；
2. 接入 AppDelegate URL router；
3. 增加 `.urlScheme` source；
4. 复用 `requestRecordingStart` 与 `RecordingControlCoordinator`；
5. 修复/验证 preparing gate 竞态；
6. 补 integration tests；
7. DEV App 实机验证；
8. 更新 README；
9. 更新本文档状态和实现基线。

## 16. 完成定义

- [x] 产品设计中的三条 URL 命令全部实现；
- [x] phase routing 有自动化测试；
- [x] 未引入第二套录音状态机；
- [x] 未用 CGEvent/快捷键模拟实现；
- [x] Selection Ask 路径验证通过；
- [x] preparing race 验证通过；
- [x] Public / Dev / Personal Scheme 测试通过；
- [x] README 中英文同步；
- [x] DEV App 用 `open 'type4me-dev://toggle'` 实机完成一次端到端输入。
