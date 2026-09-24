# Type4Me 改口（Revise）开发设计

> 文档类型：开发设计
> 文档状态：当前有效（已实现，持续验证）
> 适用平台：Type4Me macOS 14+
> 对应产品设计：`docs/features/revise/product-design.md`
> 设计日期：2026-08-18
> 最后校验：2026-09-24
> 实现基线：`d57ce17`（PR #322）
> 阅读说明：本文基于 2026-08-18 当前代码结构设计；实现时若基础设施已变化，必须保持本文的产品契约、并发门和安全失败语义

---

## 1. 设计摘要

本设计为 Type4Me 增加“改口 / Revise”全局语音编辑能力。它复用现有录音、ASR、LLM、浮动条和文本注入基础设施，但不注册为 `ProcessingMode`，也不修改当前选中模式。

核心架构决策：

1. 新增独立纯 Swift 模块 `Type4MeReviseCore`，集中维护请求协议、Prompt、模型响应解析、指令分析、diff、范围校验和 Guard；
2. `RecognitionSession` 新增 `RecordingPurpose.revise`，复用唯一音频引擎、ASR client 和 LLM cache，不建立第二套录音会话；
3. 新增 `ReviseCoordinator` actor，作为改口目标、事务、修订代次和撤销票据的唯一状态源；
4. 将现有 `CorrectionObservationContext` 泛化为可被观察学习与改口共同消费的 `TrackedInjectionContext`；
5. 所有启用改口且成功注入的文字都尝试建立可追踪目标，不再依赖 Intelli Sense 学习开关；
6. 复用并扩展 `InjectedTextResolver`，返回当前可靠文本和当前 UTF-16 范围，以支持用户手改后的三方版本处理；
7. 新增 `TrackedTextReplacementEngine`，采用乐观并发检查、选区级替换、写后验证和剪贴板恢复，不写整个输入框；
8. LLM 只生成严格 JSON 编辑结果，不生成 AX 范围、键盘操作或外部动作；
9. Guard 以“编辑指令授权后的事实”为基准，不能直接复用 Intelli Sense 的“源文本事实全部保留”规则；
10. 成功改口写入独立 `recognition_revisions` 表，并通过外键归属于原识别记录；
11. 改口开始前结算现有 Intelli Sense 观察，改口主动替换本身不进入纠错或表达学习；成功后可以以修订结果为新基线重新观察用户手改；
12. 快捷键系统增加全局动作 owner，任何涉及改口与普通模式的并发按键都拒绝跨任务切换。

整体链路：

```mermaid
flowchart TD
    A["任意文字模式成功注入"] --> B["TextInjectionEngine 生成 TrackedInjectionContext"]
    B --> C["ReviseCoordinator 注册唯一目标"]
    C --> D["用户按 fn + R"]
    D --> E["解析当前可靠目标并冻结事务"]
    E --> F["RecognitionSession 以 revise purpose 录音"]
    F --> G["ASR 生成原始编辑指令"]
    G --> H["Type4MeReviseCore 构造请求与 Prompt"]
    H --> I["共享 LLMRuntime 生成严格 JSON"]
    I --> J["响应解析、指令授权、diff 与 Guard"]
    J --> K{"处理完成前目标仍完全一致？"}
    K -- 否 --> L["放弃应用，保留最新外部文字"]
    K -- 是 --> M["TrackedTextReplacementEngine 选区级替换"]
    M --> N["写后验证并更新目标代次"]
    N --> O["保存 revision、建立一次撤销票据"]
    O --> P["按修订结果重启可选用户编辑观察"]
```

---

## 2. 当前实现基线与缺口

### 2.1 录音与处理状态

`RecognitionSession` 当前是唯一录音 actor，内部拥有：

- `AudioCaptureEngine`；
- 当前 `SpeechRecognizer`；
- `LLMClientCache`；
- `TextInjectionEngine`；
- `HistoryStore`；
- 录音、收尾、注入与恢复状态机。

现有 `startRecording(mode:)` 将所有任务都表示为 `ProcessingMode`。这不适用于改口，因为改口不会成为当前模式，也不能参与模式切换、短文本豁免、动态 Prompt 或跨模式结束。

### 2.2 文本注入与跟踪

`TextInjectionEngine` 当前在每次剪贴板注入前后读取焦点控件，用于推断 `.inserted` 或 `.copiedToClipboard`。只有 `injectTracked` 会进一步生成 `CorrectionObservationContext`，而 `RecognitionSession` 只有在 Intelli Sense 学习计划开启时才调用它。

当前上下文已经包含改口所需的大部分信息：

- `AXUIElement`；
- PID 和 Bundle ID；
- 注入后控件全文；
- 注入范围；
- 注入前后选区；
- placeholder 候选；
- 注入文本、历史记录 ID 和模式 ID。

缺口是该类型和调用资格都被“纠错观察”命名与开关绑定。

### 2.3 用户编辑解析

`InjectedTextResolver` 已支持：

- 前后缀完全保留时的常数级 `.exact` 路径；
- 外部独立编辑时的 `.anchored` 路径；
- 跨注入边界、锚点不足和预算超时时安全返回 `.ambiguous`；
- UTF-16 注入范围与 Swift `String.Index` 的正确转换。

当前结果只返回解析后的文本，不返回它在当前控件值中的范围。改口应用阶段需要同时得到：

- 当前可靠文本；
- 当前原始 AXValue 中的 UTF-16 范围；
- 当前控件全文的冻结版本；
- 解析置信度。

### 2.4 注入后观察

`PostInjectionLearningCoordinator` 当前是 `@MainActor` 单例，观察 Intelli Sense 输出后的 AXValue 变化，并消费：

- 用户编辑历史；
- 即时纠错候选；
- 表达习惯样本；
- 批量纠错证据。

改口主动替换如果被该观察器当成用户手改，会形成“系统修改自己、再学习自己”的闭环。现有 `.nextRecording` 和 `.cancelled` 结束原因也无法表达“因为改口主动接管目标而结算”。

### 2.5 快捷键

`HotkeyManager` 当前只注册 `ModeBinding`，并用 `modeId` 判断：

- 同模式按键：结束录音；
- 不同模式按键：触发跨模式结束；
- 空闲按键：开始录音。

改口不是模式。若用虚假 mode ID 接入，普通录音中按 `fn + R` 会错误走跨模式结束，违反产品定义。

### 2.6 历史存储

`HistoryStore` 当前只有 `recognition_history` 表。一次成功识别记录包含原始文本、最终文本、模型信息和可选的用户编辑观察字段。

改口是原识别记录下的一条线性修订，不能伪装成新的普通识别记录，否则会：

- 重复统计录音输入量；
- 混淆来源模式；
- 无法表达 before/after；
- 无法在删除原记录时级联删除修订；
- 将编辑指令错误展示为“最终输入文字”。

### 2.7 当前没有历史开关

产品设计使用了“现有识别历史功能开启时保存”的条件表达。当前代码实际上始终写入识别历史，没有独立关闭开关。

V1 按当前行为保存成功改口。未来如果新增全局历史开关，改口必须继承它；本项目不额外创造一个只控制改口历史的开关。

---

## 3. 总体模块划分

### 3.1 新增模块

| 模块 | Target | 职责 |
|---|---|---|
| `Type4MeReviseCore` | 独立 library target | 纯数据模型、Prompt、JSON 协议、指令与范围分析、diff、Guard、trace |
| `ReviseCoordinator` | `Type4Me` | 唯一目标、事务、代次、过期、AX 预检、提交、撤销 |
| `ReviseSettingsStore` | `Type4Me` | 启用状态、全局快捷键、App 排除、迁移与通知 |
| `TrackedTextReplacementEngine` | `Type4Me` | 选区级替换、写前检查、写后验证、剪贴板恢复 |
| `ReviseAccessibilityClient` | `Type4Me` | AX 读写窄接口与测试替身边界 |
| `ReviseMetrics` | `Type4Me` | 无正文计数、失败原因和阶段耗时 |
| `Evaluation/ReviseEval` | 独立 Swift Package | 使用生产 Core 的真实模型语义评测 |

### 3.2 调整模块

| 现有模块 | 调整 |
|---|---|
| `Package.swift` | 增加 `Type4MeReviseCore` product/target 与依赖 |
| `RecognitionSession` | 引入 `RecordingPurpose`、改口开始与收尾分支、共享 LLM cache |
| `TextInjectionEngine` | 泛化 tracked context，所有符合资格的输出可生成目标 |
| `InjectedTextResolver` | 新增当前范围与全文冻结结果 |
| `PostInjectionLearningCoordinator` | 新增改口结算原因与修订 owner，支持从修订结果重启 |
| `HotkeyManager` | owner 从 mode 扩展为 mode/global action，增加并发策略 |
| `Type4MeApp` | 注册全局改口 binding，协调 AppState、Session 和 Coordinator |
| `AppState` / `FloatingBarView` | 增加 activity kind 与改口反馈，不新增平行浮动条 |
| `HistoryStore` | 增加 revision 表、事务接口、级联删除和批量读取 |
| `HistoryTab` | 在原记录展开区展示修订链和最新用户手改 |
| `GeneralSettingsTab` | 增加“全局操作 / 改口上一轮”设置卡片 |

### 3.3 依赖方向

```mermaid
flowchart LR
    Core["Type4MeReviseCore"]
    App["Type4Me executable"]
    Eval["ReviseEval"]
    Session["RecognitionSession"]
    Coord["ReviseCoordinator"]
    AX["ReviseAccessibilityClient"]
    DB["HistoryStore"]

    App --> Core
    Eval --> Core
    Session --> Core
    Session --> Coord
    Coord --> AX
    Coord --> DB
```

`Type4MeReviseCore` 不导入 AppKit、ApplicationServices、SQLite、Keychain 或具体 LLM Client。Core 的生产与评测入口必须相同，评测包不得复制 Prompt 或 Guard。

---

## 4. Core Target 设计

### 4.1 Target 定义

`Package.swift` 增加：

```swift
.target(
    name: "Type4MeReviseCore",
    path: "Type4MeReviseCore",
    swiftSettings: swiftDefines
)
```

依赖调整：

```swift
.executableTarget(
    name: "Type4Me",
    dependencies: [
        "Type4MeIntelliSenseCore",
        "Type4MeReviseCore",
        // conditional targets...
    ],
    ...
)
```

同时导出 library product，供 `Evaluation/ReviseEval` 使用。

不让 `Type4MeReviseCore` 直接依赖 `Type4MeIntelliSenseCore`。两个功能的事实保护契约不同：Intelli Sense 默认保护来源文本事实，改口必须允许指令明确推翻旧事实。可以在未来抽取真正无语义差异的 Unicode 或 token 工具，但不能直接调用 `IntelliSenseOutputValidator`。

### 4.2 文件建议

```text
Type4MeReviseCore/
├── ReviseDomain.swift
├── RevisePrompt.swift
├── ReviseModelResponse.swift
├── ReviseInstructionAnalyzer.swift
├── ReviseScopeResolver.swift
├── ReviseDiff.swift
├── ReviseProtectedFactAnalyzer.swift
├── ReviseOutputValidator.swift
├── ReviseSensitiveTextScanner.swift
└── ReviseValidationTrace.swift
```

### 4.3 请求模型

```swift
public struct ReviseRequest: Equatable, Sendable {
    public let requestID: UUID
    public let targetText: String
    public let instruction: String
    public let controlKind: ReviseControlKind
    public let sourceLanguage: ReviseLanguageProfile
    public let sourceModeKind: ReviseSourceModeKind
}

public enum ReviseControlKind: String, Codable, Sendable {
    case singleLine
    case multiLine
    case code
    case terminal
    case unknown
}

public enum ReviseSourceModeKind: String, Codable, Sendable {
    case direct
    case intelliSense
    case translation
    case voicePolish
    case customText
    case otherText
}
```

约束：

- `targetText` 是激活时解析出的当前可靠版本，不是最初历史版本；
- `instruction` 是本次 ASR 最终文本，不经过 `SnippetStorage` 替换；
- `sourceLanguage` 由确定性脚本统计生成，不由 LLM 决定；
- `controlKind` 只描述结构能力，不包含输入框其他正文；
- 不向 Core 传递 AX、Bundle ID、输入框全文、左右锚点或历史数据库对象。

### 4.4 输入预算

Beta 固定预算：

```swift
public enum ReviseInputBudget {
    public static let maxTargetCharacters = 16_000
    public static let maxInstructionCharacters = 2_000
    public static let maxModelResponseBytes = 256_000
}
```

超过预算时在网络请求前拒绝：

- 目标过长：`targetTooLong`；
- 指令过长：`instructionTooLong`；
- 响应过大：`responseTooLarge`。

不截断目标或指令。截断会破坏引用范围、事实保护和写后验证。

### 4.5 编辑意图

```swift
public enum ReviseIntent: String, Codable, Sendable {
    case replace
    case delete
    case insert
    case rewrite
    case format
    case translate
    case undo
    case unsupported
}
```

`undo` 先由本地分类器识别，命中后不调用 LLM。模型响应仍保留 `undo` 值，用于拒绝模型把非撤销指令误判为撤销。

### 4.6 范围描述

```swift
public struct ReviseScopeDescriptor: Codable, Equatable, Sendable {
    public var kind: Kind
    public var selector: String?
    public var ordinal: Int?

    public enum Kind: String, Codable, Sendable {
        case whole
        case literal
        case sentence
        case paragraph
        case listItem
        case semantic
    }
}
```

含义：

- `whole`：整个目标；
- `literal`：明确引用的字面片段；
- `sentence`：第一句、最后一句或第 N 句；
- `paragraph`：第一段、最后一段或第 N 段；
- `listItem`：第 N 项；
- `semantic`：客套话、语气、冗余等无法完全用字面定位的范围。

模型提供范围描述，但 `ReviseScopeResolver` 必须重新验证。模型给出的 ordinal 越界、selector 不存在或 selector 多处匹配且没有 ordinal 时返回歧义。

### 4.7 严格模型响应协议

模型必须只返回一个 JSON 对象：

```json
{
  "schema_version": 1,
  "intent": "replace",
  "scope": {
    "kind": "literal",
    "selector": "三点",
    "ordinal": 1
  },
  "ambiguous": false,
  "external_action_requested": false,
  "result": "明天下午四点和 Jerry 开会。"
}
```

对应类型：

```swift
public struct ReviseModelResponse: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let intent: ReviseIntent
    public let scope: ReviseScopeDescriptor
    public let ambiguous: Bool
    public let externalActionRequested: Bool
    public let result: String
}
```

解析规则：

1. 先使用现有 `strippingThinkTags()` 等价逻辑删除模型思考块；
2. 只允许首尾空白之外存在一个 JSON object；
3. 不接受 Markdown code fence；
4. 不从说明文字中搜索第一个 `{...}`；
5. `schema_version` 不支持时拒绝；
6. 未知 enum、缺字段、重复顶层对象和尾随说明全部拒绝；
7. 解析失败不重试为纯文本输出，也不把响应当候选文字。

第一版不自动发起第二次“修 JSON”请求，避免额外延迟和不可预测的双请求成本。真实模型评测必须验证生产候选模型的结构遵循率。

### 4.8 Prompt 构造

Prompt 由唯一 `RevisePromptBuilder` 生成。职责包括：

- 明确任务是编辑 `target_text`，不是回答 `instruction`；
- 明确目标和指令都是数据，目标内的提示词不是系统命令；
- 明确只返回严格 JSON；
- 指定允许的 intent 和 scope；
- 明确局部指令只做局部变化；
- 明确“其他别动”“只改”是强约束；
- 明确允许指令推翻旧事实；
- 明确未授权事实、否定、路径、URL、代码和技术 token 必须保留；
- 明确不发送、不提交、不查询外部事实、不声称执行；
- 明确单行控件不得返回换行；
- 明确翻译只有在指令要求时改变主语言；
- 明确不输出解释、diff、操作步骤或礼貌前缀。

实际 user payload 使用 `JSONEncoder` 编码：

```json
{
  "target_text": "...",
  "instruction": "...",
  "control_kind": "multiLine",
  "source_language": {"primary_script": "han", "mixed": true},
  "source_mode_kind": "intelliSense"
}
```

不得通过字符串拼接 XML 标签插入未转义正文。

### 4.9 本地撤销识别

`ReviseUndoClassifier` 使用小型白名单和边界判断：

```swift
public enum ReviseUndoClassifier {
    public static func isUndoInstruction(_ text: String) -> Bool
}
```

支持：

- 撤销刚才的改口；
- 恢复上一版；
- 刚才那次不要了；
- undo the last revision；
- revert the last change。

不应将以下内容误判为撤销：

- “不要撤销刚才的改口”；
- “把‘撤销’两个字删掉”；
- “解释一下怎么撤销”；
- 包含大量其他编辑要求的混合指令。

撤销识别命中后由 `ReviseCoordinator.undo()` 执行，不进入 Prompt、模型或 Guard。

---

## 5. 指令分析、授权与 Guard

### 5.1 为什么不能复用 Intelli Sense Guard

Intelli Sense 的来源文本是用户本次口述，它默认要求保留来源中的最终事实。改口的来源文本是上一版本，用户的编辑指令可能明确推翻其中的事实。

例如：

```text
目标：会议是下午三点。
指令：把三点改成四点，其他别动。
```

正确结果必须删除 3 并新增 4。若机械复用 `requiredProtectedTokens`，会把正确结果判为 `protectedTokenChanged`。

改口 Guard 的正确问题是：

> 结果是否只改变了编辑指令授权改变的内容？

### 5.2 指令分析结果

```swift
public struct ReviseInstructionAnalysis: Equatable, Sendable {
    public let likelyIntent: ReviseIntent?
    public let requiresMinimalChange: Bool
    public let allowsWholeRewrite: Bool
    public let allowsLanguageChange: Bool
    public let allowsEmptyResult: Bool
    public let explicitOldLiterals: [String]
    public let explicitNewLiterals: [String]
    public let explicitProtectedTokens: Set<String>
    public let ordinalReferences: [Int]
    public let hasExternalActionTail: Bool
}
```

确定性分析负责识别：

- “把 X 改成 Y”“X 不是，改成 Y”“replace X with Y”；
- “只改”“其他别动”“不要改别的”；
- “删掉最后一句”“删除第二段”“去掉第三点”；
- “更简洁/正式/口语”“改成列表”；
- “翻成英文/中文”；
- “改好后发送”等外部动作尾部。

模型意图与本地分析明显冲突时拒绝。例如本地识别为明确替换，模型却返回 `rewrite + whole`。

### 5.3 Diff 模型

```swift
public struct ReviseDiffHunk: Equatable, Sendable {
    public let sourceCharacterRange: Range<Int>
    public let resultCharacterRange: Range<Int>
    public let removedText: String
    public let insertedText: String
}

public struct ReviseDiffSummary: Equatable, Sendable {
    public let hunks: [ReviseDiffHunk]
    public let removedCharacterCount: Int
    public let insertedCharacterCount: Int
    public let changeRatio: Double
}
```

Core 以扩展字素簇计算语义 diff，只有与 AX 范围交互时使用 UTF-16。计算预算：

- `target + result <= 32_000` 字符；
- diff 本地预算 20ms；
- 超时返回 `diffBudgetExceeded`，不自动应用。

### 5.4 范围验证

`ReviseScopeResolver` 将模型范围转换为确定性的源文本字符范围：

```swift
public enum ReviseScopeResolution: Equatable, Sendable {
    case whole
    case exact([Range<String.Index>])
    case semantic
    case ambiguous(ReviseScopeFailure)
}
```

规则：

- literal 唯一出现：允许；
- literal 多次出现且有合法 ordinal：只选择对应出现；
- literal 多次出现且无 ordinal：拒绝；
- 句子使用确定性句界或 `NLTokenizer(unit: .sentence)`；
- 段落以规范化换行分割，空行只作为间隔；
- 列表项识别 `-`、`*`、`•`、`1.`、`1)`、`1、`；
- ordinal 从 1 开始；
- semantic 不能获得精确范围，只能进入更严格事实保护；
- diff 跨越多个未授权精确范围时拒绝。

### 5.5 受保护事实

`ReviseProtectedFactAnalyzer` 至少提取：

- 阿拉伯数字、时间、日期、金额、百分比；
- URL、邮箱、绝对路径；
- 命令参数和技术标识符；
- 强禁止、绝不、必须、可能等语义关系；
- Markdown 代码围栏、占位符和模板变量；
- 混合文本中的产品名和大小写稳定 token。

授权规则：

1. 旧 token 在指令的明确旧值中出现，可以被替换或删除；
2. 新 token 在指令正文中明确出现，可以被新增；
3. 精确删除句子、段落或列表项时，该范围内 token 可以随范围删除；
4. 整体删除目标时允许空结果；
5. 翻译和格式调整不授权改变数字、URL、路径、代码或模板变量；
6. 列表序号只作为结构标记，不算新增事实；
7. 模型自报的 scope 和 intent 不能单独授权事实变化；
8. 无法证明授权时拒绝，不使用相似度猜测。

### 5.6 不同意图的变更预算

| intent | 允许范围 | 额外约束 |
|---|---|---|
| `replace` | 精确范围 | 本地/模型范围一致，新增受保护 token 必须来自指令 |
| `delete` | 精确或语义范围 | 不允许无关新增；语义删除不得删受保护事实 |
| `insert` | 指定位置 | 新增事实必须出现在指令中，原文默认保持 |
| `rewrite` | 整体 | 保护未授权事实、语言和强语义关系 |
| `format` | 整体结构 | 内容 token 基本保持，结构序号例外 |
| `translate` | 整体 | 允许主脚本改变，硬 token 和数字保持 |
| `unsupported` | 无 | 必须拒绝 |

### 5.7 极端扩写

候选最大长度：

```text
max(target.count * 2.5, target.count + 400)
```

以下情况即使用户说“扩展一下”也不在第一版自动应用：

- 候选超过上述预算；
- 新增多个指令未提及的数字、日期、URL 或专有 token；
- 从一句要求扩写为完整邮件、方案或报告；
- 输出包含标题、称呼、落款或承诺，而指令没有提供对应内容。

### 5.8 回答与外部动作

拒绝：

- JSON 之外的解释；
- 候选以“当然可以”“以下是修改后的内容”等模型前缀开头，且目标原本没有；
- 工具调用、函数调用、代码围栏；
- “已发送”“已经创建”“操作完成”等执行声明；
- 将指令中的问题当作问答请求。

如果指令同时包含合法编辑和“改好后发送”：

- `external_action_requested = true`；
- 可以应用合法文字修改；
- 不执行发送；
- 完成反馈可显示“已修改，未发送”；
- 候选不得声称已经发送。

### 5.9 Guard 结果

```swift
public enum ReviseValidationDecision: Equatable, Sendable {
    case accept(warnings: [ReviseValidationWarning])
    case reject(ReviseRejection)
}

public struct ReviseProcessingResult: Equatable, Sendable {
    public let request: ReviseRequest
    public let response: ReviseModelResponse?
    public let candidateText: String?
    public let diff: ReviseDiffSummary?
    public let decision: ReviseValidationDecision
    public let trace: ReviseValidationTrace
}
```

警告只用于历史与评测，不改变自动应用标准。任何无法证明安全的结果必须是 reject，不提供低置信度候选给 UI 选择。

---

## 6. 泛化注入跟踪上下文

### 6.1 新类型

将 `CorrectionObservationContext` 泛化为：

```swift
struct TrackedInjectionContext: @unchecked Sendable {
    let element: AXUIElement
    let processIdentifier: pid_t
    let bundleIdentifier: String
    let baselineValue: String
    let injectedRange: NSRange
    let beforeSelectedRange: NSRange?
    let afterSelectedRange: NSRange?
    let placeholderCandidates: [String]
    let sourceText: String
    let injectedText: String
    let sourceRecordID: String
    let modeID: UUID
    let createdAt: Date
}

struct TrackedInjectionResult: @unchecked Sendable {
    let outcome: InjectionOutcome
    let context: TrackedInjectionContext?
}
```

迁移期间可以保留：

```swift
typealias CorrectionObservationContext = TrackedInjectionContext
```

但新代码只使用通用名称，最终删除纠错专属别名。

### 6.2 跟踪资格

`RecognitionSession` 计算：

```swift
let shouldTrackInjection = reviseSettings.enabled
    || postInjectionLearningPlan.shouldTrackInjection
```

只要为真，就调用 `injectTracked`。成功后分别消费同一个 context：

- `ReviseCoordinator.registerTarget`：只要改口启用且 App 未排除；
- `PostInjectionLearningCoordinator.begin`：仍只在原学习计划允许时启动。

二者资格完全独立。

### 6.3 注入失败

以下情况不给改口注册目标：

- `.copiedToClipboard`；
- `context == nil`；
- 空文本；
- 安全角色；
- 注入范围无法推断；
- 前后焦点元素不同；
- App 被改口排除；
- 改口运行时开关关闭。

`.inserted` 但 AX blind 的旧兼容路径仍可以完成普通输入，但不会建立改口目标。

### 6.4 注册顺序

推荐顺序：

1. 完成实际注入；
2. 发出普通 `.finalized` UI 事件；
3. 恢复剪贴板；
4. 插入识别历史；
5. 向 `ReviseCoordinator` 注册新目标；
6. 按资格启动用户编辑观察；
7. session 回到 idle。

历史记录 ID 在注入前已生成，因此 context 可以提前携带。注册放在历史 insert 后，避免用户立即改口时产生找不到 parent record 的 revision。此时 session 尚未 idle，改口快捷键会被 busy 门拒绝，不存在可见等待窗口。

---

## 7. 当前目标定位

### 7.1 扩展 Resolver

新增：

```swift
struct LocatedInjectedText: Equatable, Sendable {
    let text: String
    let rawText: String
    let currentRange: NSRange
    let currentFullValue: String
    let confidence: ResolutionConfidence
    let changedInsideInjection: Bool
    let changedOutsideInjection: Bool
}

enum InjectedTextLocator {
    static func locate(
        baseline: String,
        injectedRange: NSRange,
        current: String,
        budget: Duration
    ) -> Result<LocatedInjectedText, InjectedTextResolutionFailure>
}
```

现有 `InjectedTextResolver.resolve` 改为调用 locator 并丢弃范围，保持既有观察器和测试 API。

### 7.2 UTF-16 与可见投影

AX 的范围是 UTF-16。定位实现必须：

- 输入输出范围均使用 `NSRange`；
- 内部 diff 可以使用 `Character`；
- 最终通过真实 `String.Index` 转换回 `NSRange`；
- 不用字符 count 直接当 UTF-16 location；
- 覆盖 emoji、组合音标、代理对、CJK 和 CRLF。

`VisibleTextProjection` 仍用于模型文本和 placeholder/sentinel 过滤，但实际替换必须保留原始 AXValue 范围。若可见投影无法反向映射到唯一原始边界，目标返回 ambiguous。

### 7.3 解析预算

沿用现有两级策略：

1. `.exact` 前后缀路径不受 10ms diff 预算限制；
2. `.anchored` 路径最多 10ms，输入总字符上限 65,536；
3. 超时立即返回 `.budgetExceeded`；
4. 不在超时后继续全文搜索或近似匹配；
5. 不回退为整个输入框。

### 7.4 同一控件验证

`ReviseAccessibilityClient` 返回：

```swift
struct ReviseFocusedControlSnapshot: @unchecked Sendable {
    let element: AXUIElement?
    let processIdentifier: pid_t?
    let bundleIdentifier: String?
    let role: String?
    let subrole: String?
    let value: String?
    let selectedRange: NSRange?
    let placeholderCandidates: [String]
    let isEditable: Bool
    let isSecure: Bool
    let supportsSingleLineOnly: Bool
}
```

激活时要求：

- 当前前台 PID 等于目标 PID；
- Bundle ID 等于目标 Bundle ID；
- `CFEqual(currentElement, target.element)`；
- 可编辑且非安全控件；
- 当前值不是 placeholder；
- locator 返回 exact 或 anchored。

不自动聚焦、激活或切换 App。

### 7.5 重复文本

注入范围和前后锚点优先于全文搜索。locator 不提供“搜索第一处相同文本”路径。

当基线外部变化导致多个候选都可能是原注入片段时返回 `.insufficientAnchor`，即使目标文本在全文中只有肉眼可见的一处，也不使用不受证明的启发式。

---

## 8. ReviseCoordinator

### 8.1 隔离与职责

```swift
actor ReviseCoordinator {
    private var target: ReviseTarget?
    private var transaction: ReviseTransaction?
    private var undoTicket: ReviseUndoTicket?
    private var expiryTask: Task<Void, Never>?
}
```

选择 actor 而不是 `@MainActor`：

- AX 查询可能受目标 App 响应速度影响；
- 目标准备、commit 与 undo 必须串行；
- 不应在主线程执行带 0.5s messaging timeout 的 AX 请求；
- UI 只消费轻量状态事件。

`AXUIElement` 通过窄包装按 `@unchecked Sendable` 传递，所有实际读写只发生在 coordinator 隔离或其受控 detached helper 中。

### 8.2 目标模型

```swift
struct ReviseTarget: @unchecked Sendable {
    let id: UUID
    var revisionGeneration: Int
    var tracking: TrackedInjectionContext
    let sourceRecordID: String
    let sourceModeID: UUID
    let sourceModeKind: ReviseSourceModeKind
    let createdAt: Date
    var expiresAt: Date
    var learningResumePlan: ReviseLearningResumePlan?
}
```

`revisionGeneration` 每次成功改口或撤销后递增。任何异步请求都冻结 id + generation；commit 不匹配时返回 `.staleTransaction`。

### 8.3 事务模型

```swift
struct RevisePreparedTarget: Sendable {
    let transactionID: UUID
    let targetID: UUID
    let targetGeneration: Int
    let sourceRecordID: String
    let currentText: String
    let currentFullValue: String
    let currentRange: NSRange
    let confidence: ResolutionConfidence
    let controlKind: ReviseControlKind
    let sourceModeKind: ReviseSourceModeKind
}

struct ReviseTransaction: Sendable {
    enum Phase: Sendable {
        case reserved
        case recording
        case processing
        case committing
    }

    let prepared: RevisePreparedTarget
    var phase: Phase
    let startedAt: Date
}
```

任意时刻最多一个 transaction。

### 8.4 注册新目标

`registerTarget(context:sourceModeKind:learningResumePlan:)`：

1. 取消旧 expiry task；
2. 清除旧 transaction 和 undo ticket；
3. 创建新 target，generation = 0；
4. expiresAt = createdAt + 10 分钟；
5. 建立带 target ID 的 expiry task；
6. 到期时仅当 ID 和 generation 仍对应才清除。

新普通输出成功注入时立即取代旧目标。失败、取消和只复制不会调用 register。

### 8.5 准备改口

`prepareForRecording()`：

1. 检查 settings enabled 和 runtime flag；
2. 检查当前没有 transaction；
3. 检查 target 或特殊 undo-only tombstone；
4. 检查 expiresAt；
5. 读取当前焦点控件；
6. 验证 App、控件、安全和 placeholder；
7. 调用 locator；
8. 检查目标长度预算；
9. 结算当前 `PostInjectionLearningCoordinator` 观察，reason = `.reviseStarted`；
10. 再读取一次控件并确认结算期间没有变化；
11. 创建 frozen transaction；
12. 返回 `RevisePreparedTarget`。

第 10 步避免观察器 finalization 最后一次读值与 prepared snapshot 之间出现竞态。

### 8.6 取消

`cancel(transactionID:)`：

- 只取消 matching transaction；
- 保留目标和剩余有效期；
- 不写 revision；
- 不写失败历史；
- 若之前结算了学习观察，按当前目标版本重新启动一次观察；
- 清除处理中任务引用和 UI busy 状态。

### 8.7 Commit

`commit(transactionID:candidate:trace:metrics:)`：

1. 校验 transaction ID、target ID 和 generation；
2. 校验 phase == processing；
3. 再次读取前台 App 和焦点控件；
4. 要求当前 AXValue 与 prepared.currentFullValue 完全相等；
5. 要求 prepared.currentRange 当前仍对应 currentText；
6. 调用 `TrackedTextReplacementEngine.replace`；
7. 写后验证成功；
8. 生成新 tracking context；
9. generation += 1，更新 target；
10. 创建 undo ticket；
11. 保存 revision；
12. 以 revision 为 owner 重启用户编辑观察；
13. 清除 transaction。

第 4 步是乐观并发门。处理期间任何用户、输入法、同步或协作者修改都会导致 `.targetChangedDuringProcessing`，不做自动三方合并。

### 8.8 删除到空

候选为空且 Guard 明确允许整体删除时：

- replacement engine 删除选区；
- 成功 revision 正常保存；
- 普通 target 清除；
- 保留一个 `undoOnly` tombstone 与 undo ticket；
- toast 的“撤销”可以直接恢复；
- `fn + R` 仍可开始一次仅允许识别撤销指令的录音；
- 用户说其他编辑指令时返回 `noEditableTarget`。

undo-only 状态沿用原 target 的剩余 10 分钟有效期，不重新延长。

### 8.9 App 终止与关闭设置

Coordinator 订阅 App 终止通知或由 `Type4MeApp` 转发：

- 目标 PID 终止：清除 target、transaction、undo ticket；
- 改口设置关闭：取消 transaction、清除所有内存状态；
- App 加入排除列表：如果命中当前目标 Bundle ID，立即清除；
- 清空历史：清除当前 target，避免 source record 已不存在。

---

## 9. RecognitionSession 接入

### 9.1 RecordingPurpose

新增：

```swift
enum RecordingPurpose: Sendable {
    case input(ProcessingMode)
    case revise(RevisePreparedTarget)
}
```

Session 增加：

```swift
private var recordingPurpose: RecordingPurpose = .input(.direct)
```

保留公共兼容入口：

```swift
func startRecording(mode: ProcessingMode = .direct) async {
    await startRecording(purpose: .input(mode))
}

func startReviseRecording(_ target: RevisePreparedTarget) async {
    await startRecording(purpose: .revise(target))
}
```

### 9.2 共用开始阶段

两种 purpose 共用：

- session idle 与 generation 门；
- ASR provider 和凭证；
- 音频输入选择；
- 麦克风权限；
- ASR client 创建/复用；
- 音频采集与 chunk pipeline；
- 最大录音时长；
- 实时 transcript 和提示音；
- cleanup、volume restore 和连接预热。

改口分支不执行：

- `ProcessingMode` 解析和 current mode 选择；
- Intelli Sense context capture；
- translation target freeze；
- Ask Anything request context；
- `PromptContext` 或剪贴板上下文；
- short-text exemption；
- Mac Action / Selection Ask 分流。

`currentMode` 保持用户原选中模式，只用于普通输入。浮动条通过 activity kind 显示改口，不临时写入 currentMode。

### 9.3 开始时的目标 App

普通输入在录音开始时捕获 `targetBundleId`。改口必须使用 prepared target 的 Bundle ID，且不能因为录音中前台 App 切换而重定向目标。

commit 仍要求原 App 和控件重新成为当前焦点。用户在录音过程中离开目标位置，最终安全失败。

### 9.4 指令文本处理

ASR 最终文本作为 `rawInstruction`：

- 保留 ASR 产生的自然标点；
- 不调用 `SnippetStorage.applyEffective`；
- 不调用 App 级片段替换；
- 不调用普通模式 Prompt；
- 不调用 `TextOutputFormatter`；
- 不做 CJK 空格或直角引号格式化；
- 可以使用 ASR 请求阶段已经配置的 hotwords。

不应用 snippet 的原因：指令可能同时引用错误词和正确词，例如“把 ghosty 改成 Ghostty”。提前把 `ghosty` 替换掉会破坏编辑授权和目标消歧。

### 9.5 Stop 分流

在最终 ASR 文本形成后、普通 `SnippetStorage` 与 LLM mode processing 之前分流：

```swift
switch recordingPurpose {
case .input:
    await completeInput(...)
case .revise(let prepared):
    await completeRevise(prepared: prepared, rawInstruction: effectiveText)
}
```

`completeRevise`：

1. 空指令：取消并提示；
2. 本地 undo 分类：调用 coordinator undo；
3. 检查输入预算和敏感内容；
4. 解析当前 LLM runtime；
5. 构造 `ReviseRequest` 和生产 Prompt；
6. 单次调用 `LLMClient.process`；
7. stripping think tags；
8. strict response parse；
9. Core validator；
10. accept 时调用 coordinator commit；
11. reject 时保留目标并发出结构化失败；
12. 记录 ASR/LLM 本地 metrics；
13. session cleanup 回 idle。

### 9.6 LLM cache

改口调用现有 `resolveLLMRuntime()`，因此与普通输入共享唯一 `LLMClientCache`：

- 相同 provider/config 复用 client 与 URLSession；
- 配置变化时沿用当前 invalidation；
- 不新增 `ReviseLLMClient` 或第二缓存；
- 没有可用 LLM 时返回 `.llmUnavailable`；
- 本地 undo 不要求 LLM。

### 9.7 错误与 generation

所有异步步骤同时检查：

- `sessionGeneration`；
- `recordingPurpose` transaction ID；
- coordinator target generation。

旧 LLM 回调、旧 detached replacement 或强制 reset 后的 zombie 任务不得覆盖新 session 或新 target。

---

## 10. 快捷键架构

### 10.1 Owner 泛化

将 `ModeBinding` 重构为通用 dispatch binding：

```swift
enum HotkeyOwner: Hashable, Sendable {
    case mode(UUID)
    case globalAction(GlobalHotkeyAction)
}

enum GlobalHotkeyAction: String, Codable, Sendable {
    case revise
}

struct HotkeyDispatchBinding {
    let bindingId: UUID
    let owner: HotkeyOwner
    let keyCode: CGKeyCode
    let modifiers: CGEventFlags
    let style: HotkeyStyle
    let onStart: @Sendable () -> Void
    let onStop: @Sendable () -> Void
    let onBusyConflict: @Sendable () -> Void
}
```

可以保留 `typealias ModeBinding` 作为迁移辅助，但状态机必须以 `owner` 而不是 mode ID 比较。

### 10.2 并发按键策略

```swift
enum HotkeyConcurrentPolicy {
    case modeCrossFinish
    case rejectCrossTask
}
```

- mode ↔ mode：继续使用现有跨模式策略；
- revise ↔ revise：同 owner，第二次按键结束录音；
- mode ↔ revise：拒绝，不结束、不切换、不排队；
- revise ↔ Ask Anything/Mac Action：拒绝；
- 任一任务 processing：拒绝新开始。

`HotkeyManager` 不直接展示提示，只调用 binding 的 `onBusyConflict`，由 `Type4MeApp` 发出“请先完成当前输入”。

### 10.3 默认 binding

```swift
static let reviseBindingID = UUID(
    uuidString: "20000000-0000-0000-0000-000000000001"
)!

static let reviseDefaultKeyCode = 15 // ANSI R
static let reviseDefaultModifiers = CGEventFlags.maskSecondaryFn.rawValue
static let reviseDefaultStyle = ProcessingMode.HotkeyStyle.toggle
```

key code 使用物理按键语义，与现有快捷键记录方式一致。显示仍由 `HotkeyRecorderView.keyDisplayName` 生成。

### 10.4 默认冲突迁移

首次创建 `revise-settings.json` 时：

1. 枚举所有 mode hotkey bindings；
2. 如果存在与 `fn + R` 完全等价的 binding，不抢占，改口 hotkey 写为 nil；
3. bare `fn` 与 `fn + R` 的 prefix 关系是预期组合，不视为禁止冲突；
4. 仍由现有 modifier prefix delay 允许用户完成 `fn + R`；
5. 写入 `tf_reviseSettingsMigratedV1`，防止每次启动重新分配；
6. 用户后来清空冲突快捷键时，不自动抢回 `fn + R`。

设置 UI 修改改口快捷键时，必须与全部 mode 和全局动作做完全重复检查；确认转移快捷键时需要明确提示，不静默删除其他 binding。

### 10.5 ESC

`HotkeyManager.onESCAbort` 根据当前 `RecordingPurpose` 分流：

- 普通输入：保持当前“取消注入但继续识别、剪贴板和历史”的语义；
- 改口录音：调用 `session.cancelReviseRecording()`，丢弃本次指令且不修改外部文字；
- 改口 processing：取消尚未提交的 LLM/事务；如果已进入 commit 临界区，不能假装取消成功；
- commit 成功后 ESC 不回滚，用户使用撤销。

UI 必须显示“取消改口”，不能沿用“ESC 取消输入”。

---

## 11. 设置存储

### 11.1 数据模型

建议文件：`~/Library/Application Support/Type4Me/revise-settings.json`

```swift
struct ReviseSettings: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion = currentSchemaVersion
    var enabled = true
    var hotkey: HotkeyBinding?
    var excludedApps: [ReviseExcludedApp] = []
}

struct ReviseExcludedApp: Codable, Equatable, Identifiable, Sendable {
    var bundleIdentifier: String
    var displayName: String
    var id: String { bundleIdentifier }
}
```

不直接复用 `IntelliSenseSettings.blacklistedApps`，避免一个设置页的修改静默改变另一个功能。

### 11.2 Store

`ReviseSettingsStore` actor 沿用 Intelli Sense Store 模式：

- 内存 cache；
- `Data.write(options: .atomic)`；
- pretty + sorted JSON；
- 保存后发送 `.reviseSettingsDidChange`；
- App 排除项按 Bundle ID 去重；
- schema version 未知时进入安全只读 fallback。

损坏文件策略：

- 不覆盖原文件；
- runtime 暂时视为 disabled；
- 设置 UI 显示读取失败并允许用户明确重置；
- 不在损坏状态下突然注册默认全局快捷键。

### 11.3 运行时开关

增加无 UI 的发布止损开关：

```text
tf_reviseRuntimeEnabled
```

语义：

- 缺失时由构建/发布配置决定；
- DEV/Beta 可默认 false，完成验收后正式新安装默认 true；
- false 时不注册快捷键、不建立目标、清除内存状态；
- 不删除 settings 或历史 revision。

产品 `enabled` 与 runtime flag 必须同时为 true 才可用。

### 11.4 设置界面

`GeneralSettingsTab` 新增“全局操作”卡片：

- “改口上一轮”开关；
- 快捷键录制与清除；
- “不可用 App”入口；
- 说明“用语音修改最近一次 Type4Me 输出”；
- LLM 未配置时显示非阻塞提示；
- 不提供有效期、模型、温度、改写强度或确认模式。

同时修改页面头部“快捷键请在处理模式中配置”的文案，使其说明模式快捷键与全局操作快捷键分别配置。

---

## 12. 原子替换引擎

### 12.1 窄接口

```swift
protocol ReviseAccessibilityClient: Sendable {
    func focusedControl() throws -> ReviseFocusedControlSnapshot
    func value(of element: AXUIElement) throws -> String
    func selectedRange(of element: AXUIElement) throws -> NSRange?
    func isAttributeSettable(_ attribute: CFString, on element: AXUIElement) -> Bool
    func setSelectedRange(_ range: NSRange, on element: AXUIElement) throws
    func setSelectedText(_ text: String, on element: AXUIElement) throws
    func pressDelete() throws
    func paste() throws
}
```

生产实现包装 AX API 与 CGEvent；单元测试使用纯内存 fake。

### 12.2 Replacement 请求

```swift
struct TrackedTextReplacementRequest: @unchecked Sendable {
    let element: AXUIElement
    let processIdentifier: pid_t
    let bundleIdentifier: String
    let expectedFullValue: String
    let expectedRange: NSRange
    let expectedText: String
    let replacementText: String
    let placeholderCandidates: [String]
}
```

### 12.3 写前检查

执行替换前再次验证：

- 前台 App、PID、Bundle ID 和 focused element；
- element 可编辑、非 secure；
- 当前 raw AXValue 完全等于 expectedFullValue；
- expectedRange 合法；
- range 内原始文本经过可见投影后等于 expectedText；
- 不处于输入法 marked text；
- 单行控件的 replacement 不含换行；
- replacement 未超过控件/产品预算。

任何失败都不得触发选区或剪贴板写入。

### 12.4 替换策略

优先级：

1. 如果 `kAXSelectedTextAttribute` 可写：设置选区后直接写 selected text；
2. 否则设置选区，通过 transient paste 替换；
3. replacement 为空且 selected text 不可写：设置选区后发送 Delete；
4. 不使用整个 `kAXValueAttribute` 写回全文；
5. 不先删除再异步粘贴；
6. 不调用 App 菜单或 AppleScript。

禁止全量 AXValue 写回的原因：即使写前全文一致，也可能破坏富文本、输入法状态、编辑器内部模型或协作元数据。

### 12.5 剪贴板策略

复用 `TextInjectionEngine.ClipboardSnapshot`，但需要将其提取为 package-private 共享组件：

- 只读取安全文本 pasteboard types；
- replacement 写入 transient 标记；
- 无论替换成功或失败都尝试恢复原剪贴板；
- 仅当 changeCount 仍等于 Type4Me 写入后的值时恢复；
- 用户在处理期间主动改剪贴板时不覆盖；
- 改口失败不把候选留在剪贴板。

这与普通注入失败时保留文本到剪贴板的语义不同，必须由调用参数明确区分。

### 12.6 写后验证

根据 expectedFullValue 和 expectedRange 本地构造唯一 expectedAfterValue。写入后最多进行：

- 首次 100ms 后读取；
- 失败时再等待 200ms 读取一次。

判断：

- actual == expectedAfter：成功；
- actual == expectedBefore：`.noChange`；
- placeholder/空控件且非预期删除：`.controlReset`；
- 其他值：`.verificationMismatch`。

不通过最长公共前后缀把任意 actual 解释为成功。

### 12.7 失败恢复

替换设计避免“先删后写”，因此大多数失败会保留原文。出现 verification mismatch 时：

- 不盲发 Cmd+Z；
- 不写整个 before value；
- 只在候选片段能够被新 locator 唯一定位，且反向选区级替换可证明安全时尝试一次 rollback；
- rollback 也必须写后验证；
- 无法证明时停止进一步修改，返回 `.partialFailure` 并记录无正文诊断。

Beta 发布门要求真实 App 测试中 partial failure 为 0。任何 partial failure 都是阻断发布的高优先级事故。

### 12.8 成功上下文

成功结果返回：

```swift
struct TrackedTextReplacementSuccess: @unchecked Sendable {
    let afterFullValue: String
    let replacementRange: NSRange
    let afterSelectedRange: NSRange?
    let trackingContext: TrackedInjectionContext?
}
```

Coordinator 使用它更新目标，而不是自行猜测新 range。

---

## 13. 撤销设计

### 13.1 Undo ticket

```swift
struct ReviseUndoTicket: @unchecked Sendable {
    let id: UUID
    let targetID: UUID
    let targetGeneration: Int
    let revisionID: String
    let expectedAfterContext: TrackedInjectionContext
    let beforeText: String
    let afterText: String
    let expiresAt: Date
}
```

任意时刻只保留最近一次成功改口的 ticket。新的成功改口、新普通输出、目标过期、App 终止或设置关闭会取代/清除旧 ticket。

### 13.2 Toast 撤销

成功 feedback 的“撤销”直接调用：

```swift
await reviseCoordinator.undo(ticketID: id)
```

不启动录音，不调用 ASR 或 LLM。

### 13.3 语音撤销

用户通过 `fn + R` 录音后，ASR 文本先经过 `ReviseUndoClassifier`。命中后调用同一 `undo` 方法。

没有 ticket 时返回 `.nothingToUndo`。不得把“撤销”发送给 LLM让模型重写文字。

### 13.4 安全条件

undo 要求：

- 当前目标/undo tombstone 与 ticket target ID 一致；
- generation 一致；
- 当前 App 和控件一致；
- 当前可见目标恰好等于 afterText；
- 处理期间没有新手改；
- 反向替换通过写后验证。

成功后：

- `recognition_revisions.status = 'undone'`；
- 写入 `undone_at`；
- target 更新为 beforeText；
- generation + 1；
- ticket 消耗；
- 不创建新的 revision 行；
- 可以从恢复后的版本继续新的改口；
- 第一版不提供 redo。

---

## 14. 数据库设计

### 14.1 开启外键

每个 `HistoryStore` SQLite connection 打开后执行：

```sql
PRAGMA foreign_keys = ON;
```

必须检查返回状态。测试覆盖多 `HistoryStore` 实例连接时的级联行为。

### 14.2 Revision 表

```sql
CREATE TABLE IF NOT EXISTS recognition_revisions (
    id TEXT PRIMARY KEY,
    source_record_id TEXT NOT NULL,
    sequence INTEGER NOT NULL,
    created_at TEXT NOT NULL,
    instruction_text TEXT NOT NULL,
    before_text TEXT NOT NULL,
    after_text TEXT NOT NULL,
    intent TEXT NOT NULL,
    scope_kind TEXT NOT NULL,
    status TEXT NOT NULL,
    undone_at TEXT,
    asr_provider TEXT,
    asr_model TEXT,
    llm_provider TEXT,
    llm_model TEXT,
    asr_duration_seconds REAL,
    llm_duration_seconds REAL,
    validation_trace TEXT,
    user_edited_text TEXT,
    user_edit_status TEXT,
    user_edit_observed_at TEXT,
    user_edit_version INTEGER,
    FOREIGN KEY(source_record_id)
        REFERENCES recognition_history(id)
        ON DELETE CASCADE,
    UNIQUE(source_record_id, sequence)
);

CREATE INDEX IF NOT EXISTS idx_revisions_source_sequence
ON recognition_revisions(source_record_id, sequence ASC);
```

### 14.3 为什么使用独立表

- 一条识别记录可以有多次 revision；
- before/after/instruction 都是 revision 级字段；
- 删除 parent 可以级联；
- revision 不进入普通语音用量统计；
- post-revise 用户手改可以有独立观察 owner；
- undo 只更新对应 revision；
- 未来可以独立扩展词汇候选或评测 trace。

### 14.4 Revision 模型

```swift
struct RecognitionRevisionRecord: Identifiable, Hashable, Sendable {
    let id: String
    let sourceRecordID: String
    let sequence: Int
    let createdAt: Date
    let instructionText: String
    let beforeText: String
    let afterText: String
    let intent: ReviseIntent
    let scopeKind: ReviseScopeDescriptor.Kind
    let status: ReviseRevisionStatus
    let undoneAt: Date?
    let asrProvider: String?
    let asrModel: String?
    let llmProvider: String?
    let llmModel: String?
    let asrDurationSeconds: Double?
    let llmDurationSeconds: Double?
    let validationTraceJSON: String?
    let userEditedText: String?
    let userEditStatus: UserEditObservationStatus?
    let userEditObservedAt: Date?
    let userEditVersion: Int?
}
```

### 14.5 写入事务

`insertRevision` 在 `HistoryStore` actor 内：

1. `BEGIN IMMEDIATE`；
2. 确认 parent 存在；
3. `SELECT COALESCE(MAX(sequence), 0) + 1`；
4. INSERT revision；
5. COMMIT；
6. 发布一次 `.historyStoreDidChange`。

若 parent 不存在：

- rollback；
- 返回 `.missingParent`；
- 不创建孤立 revision。

外部文字已经成功修改但数据库写入失败时，不回滚用户文字。用户目标优先于历史完整性；记录 `revisionHistoryWriteFailed`，继续提供内存 undo。

### 14.6 观察 owner 泛化

新增：

```swift
enum UserEditObservationOwner: Hashable, Sendable {
    case recognition(String)
    case revision(String)
    case ephemeral(UUID)
}
```

`TrackedInjectionContext` 增加或由包装层提供 owner。`PostInjectionLearningCoordinator` 结算时：

- recognition：调用现有 `updateUserEditObservation(recordID:)`；
- revision：调用 `updateRevisionUserEditObservation(revisionID:)`；
- ephemeral：不持久化正文，但仍可按设置生成即时纠错/表达样本。

post-revise 观察以修订后的 afterText 为 injected baseline，改口本身不进入 diff。

### 14.7 批量读取与 UI

接口：

```swift
func fetchRevisions(sourceRecordID: String) -> [RecognitionRevisionRecord]
func fetchRevisions(sourceRecordIDs: [String]) -> [String: [RecognitionRevisionRecord]]
func markRevisionUndone(id: String, at: Date) -> Bool
func updateRevisionUserEditObservation(...) -> Bool
```

HistoryTab 优先在记录展开时按 parent ID 懒加载并缓存。列表滚动不为每行预取 revisions，避免 N+1 查询和不必要正文常驻。

### 14.8 删除与导出

- 删除单条 recognition：SQLite cascade 删除 revisions；
- 批量删除：同样 cascade；
- deleteAll：清空 parent 后 revisions 自动清空；
- 清空完成后通知 coordinator 清除内存 target；
- V1 CSV 导出增加“改口次数”和“最新版本”两列，不把每次完整 instruction/before/after 塞进同一 CSV 单元格；
- 完整修订导出需要独立结构化格式，未设计前不自动加入 CSV，避免意外扩大敏感正文导出范围。

---

## 15. 与用户编辑观察协作

### 15.1 新结束原因

```swift
enum UserEditObservationEndReason: String, Codable, Sendable {
    // existing...
    case reviseStarted
    case reviseApplied
}
```

`reviseStarted` 表示：先结算用户在改口前已经完成的真实手动修改，然后把控件控制权交给改口事务。

### 15.2 改口开始

顺序：

1. coordinator 初次解析当前目标；
2. MainActor 调用 `finalizeBeforeRevise()`；
3. 观察器最后读取并持久化用户手改；
4. coordinator 再次读取并冻结 prepared target；
5. 开始改口录音。

不能先取消观察再解析目标，否则可能丢失最后一次用户编辑证据。

### 15.3 改口应用

替换期间不启动观察器。成功后：

1. revision 已经写入或获得 ephemeral owner；
2. 构造以 afterText 为 baseline 的新 `TrackedInjectionContext`；
3. 重新读取当前 Intelli Sense 设置和 App 排除；
4. 只有原输出属于 Intelli Sense 且当前纠错/表达开关仍开启时重启；
5. 后续用户手改只相对于 afterText 分析。

### 15.4 取消或失败

如果改口录音取消、LLM 失败或 Guard 拒绝：

- 外部文字未变；
- 在目标仍可靠时，以当前版本重新启动观察；
- owner 仍是原 recognition 或最近成功 revision；
- 不把失败指令存为观察文本。

### 15.5 防止自我学习

必须添加回归：

- Type4Me 应用 revision 不触发纠错卡；
- revision before → after 不进入 expression feature；
- revision 的编辑指令不进入 sourceText；
- revision 后用户再手改可以生成正常即时候选；
- post-revise 观察的 baseline 是 afterText；
- 批量推断不把系统 revision 当作用户证据。

### 15.6 批量纠错范围

第一版：

- 改口动作本身不作为批量纠错证据；
- revision 后真实用户手改可以写入 revision observation 字段；
- `BatchCorrectionInference` 是否合并 revision observation 由阶段 C 实现；
- MVP 即时候选和表达观察可以使用 revision owner；
- 未实现统一批量查询前，不能把 revision before/after 作为替代数据。

---

## 16. UI 与事件设计

### 16.1 Activity kind

不增加第二套浮动条和完整平行 phase 枚举。新增：

```swift
enum RecordingActivityKind: Equatable {
    case standard
    case revise
}
```

`AppState` 增加：

```swift
var activityKind: RecordingActivityKind = .standard
var reviseFeedbackAction: ReviseFeedbackAction?
```

现有 `FloatingBarPhase` 继续负责 preparing、recording、processing、done、error。`activityKind` 决定图标、标签、颜色和按钮文案。

### 16.2 AppState 方法

```swift
func startReviseRecording()
func stopReviseRecording()
func showReviseCompleted(message: String, undoTicketID: UUID?)
func showReviseFailed(_ failure: ReviseFailure)
func showReviseCancelled()
func showReviseUndone()
```

这些方法不能调用 `selectModeForRecording`，也不能持久化 last mode ID。

### 16.3 RecognitionEvent

新增结构化事件：

```swift
case reviseProcessing
case reviseCompleted(text: String, message: String, undoTicketID: UUID?)
case reviseFailed(ReviseFailure)
case reviseCancelled
case reviseUndone(text: String)
```

`.ready` 和 `.transcript` 可共用；AppState 根据 activityKind 展示“说说你想怎么改”。

不要用普通 `.finalized(text:injection:)` 表示 revision，因为普通 completion message 和目标注册语义不同。

### 16.4 反馈动作

成功条显示“撤销”时，按钮回调携带 ticket ID。自动隐藏后 ticket 仍可通过语音撤销，直到被取代或过期。

浮动条是 nonactivating panel，撤销按钮不得抢走目标控件焦点。点击回调直接提交 actor task。

### 16.5 错误映射

Core/Coordinator 使用稳定 enum，UI 本地化映射：

| Failure | 中文文案 |
|---|---|
| `noTarget` | 还没有可修改的上一轮输出 |
| `expired` | 上一轮输出已过期 |
| `appChanged` / `controlChanged` | 请回到上一轮输入的位置 |
| `targetMissing` | 上一轮内容已经离开输入区域 |
| `targetAmbiguous` | 无法安全定位上一轮内容 |
| `sensitive` | 此处不支持改口 |
| `excludedApp` | 此 App 已关闭改口 |
| `instructionEmpty` | 没听清想怎么改，请重试 |
| `instructionAmbiguous` | 请说清要修改哪一处 |
| `unsupportedInstruction` | 请直接说要修改什么 |
| `llmUnavailable` | 需要先配置可用的语言模型 |
| `providerFailure` | 改口失败，请重试 |
| `validationRejected` | 为避免改错，已保留原文 |
| `targetChangedDuringProcessing` | 内容发生了变化，请再说一次 |
| `replacementFailed` | 未能应用修改，原文已保留 |
| `partialFailure` | 修改状态异常，请检查当前文字 |
| `nothingToUndo` | 没有可撤销的改口 |

日志记录 enum，不记录本地化字符串。

---

## 17. 敏感数据与隐私

### 17.1 三道门

改口在三个阶段检查敏感性：

1. 目标注册：secure role/subrole 或 excluded App 不建立 target；
2. 激活预检：重新检查当前控件、目标文本和 placeholder；
3. 网络请求前：`ReviseSensitiveTextScanner` 检查 currentText + instruction。

任何一道失败都不发送网络请求。

### 17.2 Scanner

至少覆盖：

- API key、secret、access token、Bearer token；
- private key header；
- 密码字段形态；
- 验证码与系统凭据控件信号；
- Type4Me 既有 Intelli Sense 敏感规则；
- 过长高熵 token。

可以共享底层 pattern 常量，但改口必须有自己的公共 API 和测试，避免未来 Intelli Sense 规则变化无审查地改变改口。

### 17.3 发送给模型的内容

只包含：

- current target text；
- instruction；
- control kind；
- source language profile；
- source mode kind。

不发送：

- 输入框全文；
- 左右锚点；
- AX role 原始描述；
- Bundle ID；
- 历史其他版本；
- 用户表达档案；
- PromptContext；
- 剪贴板。

### 17.4 日志

禁止记录：

- targetText；
- instruction；
- candidate；
- before/after full value；
- anchor；
- API key；
- 模型原始响应。

允许记录：

- request/target UUID 的短哈希或随机 trace ID；
- 长度；
- intent/scope enum；
- diff hunk 数和 ratio；
- resolution confidence；
- failure enum；
- 阶段耗时；
- provider/model 标识。

### 17.5 历史正文

当前产品始终保存识别历史，因此成功 revision 保存 instruction/before/after。删除 parent 时级联删除。

未来如果增加“关闭历史”：

- revision 正文不得落盘；
- 内存 target 和 undo 仍可在 10 分钟内工作；
- validation trace 也不单独创建孤立持久化数据。

---

## 18. Validation Trace 与 Metrics

### 18.1 Trace

```swift
public struct ReviseValidationTrace: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public let version: Int
    public let intent: ReviseIntent?
    public let scopeKind: ReviseScopeDescriptor.Kind?
    public let targetResolution: String
    public let decision: String
    public let rejection: ReviseRejection?
    public let warnings: [ReviseValidationWarning]
    public let diffHunkCount: Int?
    public let changeRatioBucket: String?
    public let externalActionIgnored: Bool
}
```

Trace 不保存正文、selector、Prompt 或模型响应。历史 UI 第一版不展示完整 Guard 细节，只用于开发诊断和评测对齐。

### 18.2 Metrics actor

`ReviseMetrics` 沿用 `UserEditObservationMetrics` 的本地计数模式：

```swift
actor ReviseMetrics {
    static let shared = ReviseMetrics()
    private var counters: [String: Int]
    private var durations: [String: [Double]]
}
```

事件：

- targetRegistered / targetUnavailable；
- activationAttempt / activationPrepared / activationRejected；
- recordingStarted / cancelled；
- modelRequested / parsed / rejected；
- commitStarted / applied / failed / partialFailure；
- undoAttempted / applied / rejected；
- revisionHistoryWriteSucceeded / failed；
- observationResumed / failed。

失败 reason 使用产品设计列出的稳定枚举。

### 18.3 延迟分段

记录：

- target preflight；
- ASR；
- LLM；
- Core parse + validation；
- commit precheck；
- replacement + verification；
- history write；
- stop recording 到外部文字完成替换的端到端耗时。

初始目标：

- preflight P95 ≤ 50ms（AX 正常 App）；
- Core validation P95 ≤ 30ms；
- replacement + verify P95 ≤ 500ms；
- 端到端 P50 ≤ 2.5s、P95 ≤ 7s，按 provider 分组报告。

网络模型不达目标时先优化请求和 provider，不放松写前/写后安全检查。

---

## 19. 历史 UI

### 19.1 展示顺序

原识别记录展开区：

1. 原始文本（现有）；
2. Intelli Sense trace（现有）；
3. Type4Me 初始输出；
4. 改口修订链；
5. 最新 revision 后的用户手改；
6. ASR/LLM 元数据。

### 19.2 Revision 行

每条显示：

- “改口 1 / Revise 1”；
- 时间；
- 指令；
- 结果；
- 已撤销状态；
- 可选 ASR/LLM 来源与耗时。

beforeText 默认不重复展示；点击“查看变化”时才显示 before/after diff。连续 revision 的上一条 result 已经是下一条 before。

### 19.3 搜索

第一版历史主列表搜索仍只覆盖 recognition `rawText/finalText`，避免为 revision 正文加入复杂 SQL/内存 join。

阶段 B 再增加：

- instruction 命中；
- afterText 命中；
- 命中摘要；
- revision table 索引策略。

未实现前文案不声称搜索包含改口历史。

### 19.4 删除

UI 只删除 parent。revision 不提供单独删除按钮，避免线性链断裂和 before/after 语义损坏。用户可以删除整条识别记录或清空历史。

---

## 20. 并发与竞态

### 20.1 单一活动任务

任何时刻只允许一个：

- 普通录音；
- 改口录音；
- Ask Anything 录音/生成；
- Mac Action；
- 改口 commit。

Hotkey 层阻止明显冲突，Session generation 和 Coordinator transaction 再做第二、第三道门。

### 20.2 目标变化竞态

时间线：

```text
T0 prepare 读取 currentFullValue A
T1 用户录制指令
T2 LLM 处理
T3 用户/协作者把输入框改成 B
T4 commit 读取 B
```

T4 必须发现 `B != A` 并放弃。不能把候选与 B 自动 merge，也不能重新对 B 运行原指令。

### 20.3 新普通输出竞态

改口 transaction 活跃期间普通模式 hotkey被拒绝，因此不会出现新输出取代 target 后旧 commit 仍应用。

若代码路径绕过 hotkey直接注册新 target：

- registerTarget 使旧 generation 失效；
- 旧 commit 返回 `.staleTransaction`；
- 新 target 保持不变。

### 20.4 过期竞态

目标在 recording/processing 中到达 10 分钟：

- 已经成功 prepare 的 transaction 可以继续到 commit；
- commit 仍需所有实时验证；
- 不因处理中跨过 expiresAt 单独失败；
- transaction 完成/取消后，不延长原 target 创建时间；
- 成功 revision 更新目标内容但不重置 10 分钟总窗口。

这样避免用户在第 9 分 59 秒开始说话，处理过程中突然失效，同时保持产品的短生命周期。

### 20.5 ESC 与 commit 临界区

Coordinator phase 进入 `.committing` 后：

- ESC 不取消正在发生的 AX 写入；
- UI 继续显示处理；
- commit 完成后可撤销；
- 不能显示“已取消”但实际文字已经改变。

在 `.reserved/.recording/.processing` 阶段可以取消，并使 transaction ID 失效。

### 20.6 App 退出与 AX timeout

- App 退出通知立即清 target；
- AX 查询超时返回 typed failure；
- timeout 不在主线程；
- timeout 后不复用可能失效的 snapshot；
- 不对同一操作无限重试。

---

## 21. 错误类型

### 21.1 产品级 failure

```swift
enum ReviseFailure: String, Error, Codable, Sendable {
    case disabled
    case noTarget
    case expired
    case busy
    case appChanged
    case controlChanged
    case targetMissing
    case targetAmbiguous
    case targetTooLong
    case sensitive
    case excludedApp
    case instructionEmpty
    case instructionTooLong
    case instructionAmbiguous
    case unsupportedInstruction
    case llmUnavailable
    case providerFailure
    case malformedModelResponse
    case validationRejected
    case targetChangedDuringProcessing
    case replacementFailed
    case partialFailure
    case nothingToUndo
    case staleTransaction
}
```

### 21.2 Core rejection

`ReviseRejection` 更细，用于 trace/评测：

- empty/disallowed empty output；
- malformed JSON/schema mismatch；
- model ambiguity；
- unsupported intent；
- intent mismatch；
- scope missing/not found/multiple/ordinal out of bounds；
- change outside authorized scope；
- protected token removed/added；
- strong relation changed；
- language changed without authorization；
- single-line violation；
- answer/explanation；
- claimed execution；
- code fence/tool call；
- sensitive leak；
- extreme expansion；
- diff budget exceeded。

UI 不直接显示 Core 枚举，统一映射到少量可行动文案。

---

## 22. 测试设计

### 22.1 Core 单元测试

新增 `Type4MeReviseCoreTests` 或在根测试 target 中直接测试 public Core：

- JSON 正常/缺字段/未知 schema/尾随说明/code fence；
- undo 正例、否定撤销、引用“撤销”字样；
- replace/delete/insert/rewrite/format/translate intent；
- “只改/其他别动”强约束；
- literal 唯一、多处、ordinal；
- 最后一句、第 N 段、第 N 列表项；
- semantic scope；
- Unicode diff、emoji、组合音标；
- 数字、日期、金额、URL、邮箱、路径；
- 强禁止、绝不、必须等关系；
- 列表序号不是事实；
- 单行结构；
- 翻译授权与非授权整段换语言；
- answer/explanation/tool/execution；
- sensitive scanner；
- 极端扩写和 diff timeout；
- validation trace 无正文。

### 22.2 Locator 测试

扩展 `InjectedTextResolverTests`：

- exact 返回正确 currentRange；
- anchored 外部前缀/后缀编辑后范围正确；
- 内部用户手改范围长度更新；
- 跨边界 ambiguous；
- 两侧锚点不足；
- 65,536 上限；
- 10ms budget；
- emoji、ZWJ、组合字符、CRLF；
- editor sentinel 可见投影与原始范围；
- placeholder 不进入结果；
- 重复文本不搜索第一处。

### 22.3 Coordinator 测试

通过 fake clock、fake accessibility、fake replacement engine、临时 HistoryStore：

- 注册新目标取代旧目标；
- 普通失败不取代；
- 10 分钟过期 generation guard；
- App/control mismatch；
- prepare 前后第二次读取变化；
- 同时 prepare 只有一个成功；
- cancel 保留目标并恢复观察；
- stale transaction；
- commit 期间目标变化；
- 连续 revision；
- deletion tombstone；
- toast undo 和 voice undo 共用路径；
- undo 后手改拒绝；
- 新输出清 undo；
- App termination/settings disable；
- history write failure不回滚文字。

### 22.4 Replacement engine 测试

fake AX/pasteboard：

- selectedText direct replace；
- clipboard paste replace；
- empty delete；
- preflight 失败无任何写；
- single-line 拒绝；
- expected value changed；
- write verified；
- delayed verification；
- noChange；
- mismatch 与安全 rollback；
- rollback 不可证明时 partial failure；
- clipboard 正常恢复；
- 用户改 clipboard 时不恢复；
- 永不写整个 AXValue；
- success context range 更新。

### 22.5 Session 测试

扩展 `RecognitionSessionTests`：

- revise purpose 不改变 currentMode；
- 不捕获 PromptContext/selection/clipboard；
- 不调用 SnippetStorage；
- 复用 LLM cache；
- empty instruction；
- local undo 不调用 LLM；
- malformed response 不注入；
- Guard reject 不注入；
- accepted response只调用 coordinator commit；
- ESC revise cancel 与普通 abort 语义分离；
- generation 防 zombie result；
- cleanup 回 idle、恢复音量、预热连接。

### 22.6 Hotkey 测试

扩展 `HotkeyConflictTests` 和 `HotkeyStateMachineTests`：

- `fn + R` regular key 保留 fn flag；
- bare fn prefix delay 后 fn+R 正确命中；
- mode recording 中 revise 被拒绝且不结束 mode；
- revise recording 中 mode 被拒绝且不结束 revise；
- revise toggle 第二次停止；
- processing 中不排队；
- exact conflict migration 产生 nil hotkey；
- 用户自定义冲突确认；
- ESC route based on owner/purpose；
- event tap reset 不残留 revise owner。

### 22.7 History 测试

- migration 创建表和索引；
- foreign_keys 开启；
- sequence 递增；
- parent missing rollback；
- delete/delete(ids)/deleteAll cascade；
- mark undone 幂等；
- revision observation update 时间/信息 rank；
- 批量 fetch 分组；
- 多连接 cascade；
- validation trace 版本；
- HistoryTab 懒加载与 cache invalidation。

### 22.8 学习隔离测试

- revise application 不生成 correction candidate；
- revise before/after 不进入 expression sample；
- revise instruction 不作为 sourceText；
- post-revise 用户手改以 afterText 为 baseline；
- revision owner 正确持久化；
- cancel/reject 后观察恢复；
- App 黑名单仍只控制 Intelli Sense 学习，不等同改口 excluded Apps。

### 22.9 真实 App 手工矩阵

至少验证：

- TextEdit / Notes / Mail；
- Safari / Chrome 普通输入；
- Slack / Feishu / WeChat 等 Electron/复杂 AX；
- Notion 或富文本 contenteditable；
- VS Code / Xcode；
- Terminal / Ghostty；
- 单行搜索框和标题框；
- 中文输入法 marked text；
- 发送后 placeholder；
- 协作编辑期间远端变化；
- emoji、混合中英文和 Markdown。

每个 App 记录：目标建立率、preflight、替换策略、写后验证、样式损失、撤销和失败类型。

---

## 23. 独立真实模型评测

### 23.1 Package

新增：

```text
Evaluation/ReviseEval/
├── Package.swift
├── README.md
├── Sources/ReviseEvalKit/
├── Sources/ReviseEvalCLI/
├── Tests/ReviseEvalKitTests/
├── Fixtures/
├── Baselines/
└── Runs/                 # gitignored
```

依赖根 package 的 `Type4MeReviseCore` product，禁止复制 Prompt、parser 或 Guard。

### 23.2 案例规模

首版至少 160 条：

- 30 smoke；
- 20 critical；
- precise replace；
- delete/insert；
- style/rewrite；
- structure/format；
- translation；
- technical/mixed language；
- ambiguity/rejection；
- safety/privacy；
- adversarial target/instruction。

### 23.3 CLI

沿用 IntelliSenseEval 体验：

```bash
swift run revise-eval validate
swift run revise-eval run --suite smoke --model product
swift run revise-eval run --suite all --tag protected-facts
swift run revise-eval run --suite all --case rv001 --repeat 3
swift run revise-eval report --run <run-id>
swift run revise-eval compare --baseline approved
```

支持限并发、缓存、断点、`--no-cache`、重试、run.jsonl、diff 和人工 review packet。不自动调用 judge model。

### 23.4 自动断言

自动检查：

- JSON schema；
- Core decision；
- mustApply / mustReject；
- expected intent/scope；
- 必须保留/删除/新增 token；
- 禁止片段；
- 语言和单行约束；
- 外部动作声明；
- 最大 change ratio。

人工审查：

- 是否真正完成指令；
- 局部修改是否越界；
- 风格改写是否保留语义强度；
- semantic scope 是否删错内容；
- 用户是否会立即重试、撤销或手改。

### 23.5 发布门

- critical 自动硬约束 100% 通过；
- 外部动作声明 0；
- 未授权关键事实变化 0；
- mustApply 原样率 0；
- mustReject 误应用 0；
- 关键案例重复三次无随机越界；
- 人工 review 完成并版本化 approved baseline。

---

## 24. 性能与资源

### 24.1 普通输入开销

开启改口后，普通注入新增的主要开销是保留 tracked context。`TextInjectionEngine` 本来已经为 outcome 检测读取注入前后 AX snapshot，因此不应新增第二轮 AX 捕获。

目标只保留一份：

- baseline full value 上限沿用 65,536 字符；
- injected text；
- 少量锚点/范围/元数据；
- 一个 AXUIElement；
- 最多 10 分钟。

新目标注册时立即释放旧引用。

### 24.2 不常驻模型资源

改口不加载新本地模型、不新增 URLSession、不创建第二 LLM cache。Core 是纯规则与字符串处理。

### 24.3 AX timeout

所有 AX call 设置明确 messaging timeout，建议单次 0.3–0.5s。preflight 的正常路径应远低于 timeout；超时直接失败，不在主线程阻塞。

### 24.4 请求取消

ESC 或 session reset 时取消上层 Task。具体 LLM provider 若无法真正中断网络请求，返回后仍会因 session/transaction generation 失效而丢弃，不进入 commit。

---

## 25. 实施阶段

### 25.1 阶段 A：纯 Core 与跟踪基础

1. 新增 `Type4MeReviseCore`；
2. 定义 request/response/intent/scope/trace；
3. 实现 Prompt、strict parser、instruction analyzer、diff、Guard；
4. 实现 Core 单测；
5. 泛化 tracked injection context；
6. 扩展 locator 返回 current range；
7. 实现 settings store 与 runtime flag。

验收：不接入快捷键也可以用纯测试证明编辑协议和目标定位。

### 25.2 阶段 B：事务与实际应用

1. 新增 AX client 和 replacement engine；
2. 实现 `ReviseCoordinator`；
3. 引入 `RecordingPurpose`；
4. 接入 ASR、共享 LLM 和 stop 分流；
5. 泛化 Hotkey owner，注册 `fn + R`；
6. 接入 AppState/FloatingBar；
7. 完成连续改口、删除 tombstone 和 undo；
8. 完成竞态与 ESC 测试。

验收：主流纯文本 App 能完成安全闭环，所有失败保留原文。

### 25.3 阶段 C：历史与观察协作

1. 建 revision table；
2. 插入、撤销、级联删除；
3. 泛化 observation owner；
4. 改口前结算、成功/失败后恢复观察；
5. HistoryTab 懒加载修订链；
6. 设置 App exclusions；
7. 本地 metrics 和 Debug 页面摘要。

验收：没有自我学习，历史删除与观察 owner 全部正确。

### 25.4 阶段 D：评测与 Beta

1. 建立 `Evaluation/ReviseEval`；
2. 完成 160+ 案例和 approved baseline；
3. 完成真实 App 手工矩阵；
4. 记录 target availability 与写后验证结果；
5. 灰度开启 runtime flag；
6. 复核 10 分钟阈值、延迟和撤销率；
7. 满足发布门后新安装默认启用。

---

## 26. 文件改动清单

### 26.1 新增

```text
Type4MeReviseCore/ReviseDomain.swift
Type4MeReviseCore/RevisePrompt.swift
Type4MeReviseCore/ReviseModelResponse.swift
Type4MeReviseCore/ReviseInstructionAnalyzer.swift
Type4MeReviseCore/ReviseScopeResolver.swift
Type4MeReviseCore/ReviseDiff.swift
Type4MeReviseCore/ReviseProtectedFactAnalyzer.swift
Type4MeReviseCore/ReviseOutputValidator.swift
Type4MeReviseCore/ReviseSensitiveTextScanner.swift
Type4MeReviseCore/ReviseValidationTrace.swift

Type4Me/Services/ReviseCoordinator.swift
Type4Me/Services/ReviseSettings.swift
Type4Me/Services/ReviseMetrics.swift
Type4Me/Injection/ReviseAccessibilityClient.swift
Type4Me/Injection/TrackedTextReplacementEngine.swift

Type4MeTests/ReviseCoordinatorTests.swift
Type4MeTests/ReviseSettingsTests.swift
Type4MeTests/TrackedTextReplacementEngineTests.swift
Type4MeTests/ReviseHistoryStoreTests.swift

Evaluation/ReviseEval/...
```

### 26.2 修改

```text
Package.swift
Type4Me/Injection/TextInjectionEngine.swift
Type4Me/Services/InjectedTextResolver.swift
Type4Me/Services/CorrectionLearning.swift
Type4Me/Services/UserEditObservation.swift
Type4Me/Services/BatchCorrectionInference.swift
Type4Me/Session/RecognitionSession.swift
Type4Me/Input/HotkeyManager.swift
Type4Me/Type4MeApp.swift
Type4Me/UI/AppState.swift
Type4Me/UI/FloatingBar/FloatingBarView.swift
Type4Me/UI/Settings/GeneralSettingsTab.swift
Type4Me/UI/Settings/HistoryTab.swift
Type4Me/UI/Settings/ModesSettingsTab.swift
Type4Me/Database/HistoryStore.swift
Type4MeTests/InjectedTextResolverTests.swift
Type4MeTests/RecognitionSessionTests.swift
Type4MeTests/HotkeyConflictTests.swift
Type4MeTests/HotkeyStateMachineTests.swift
docs/README.md
docs/features/revise/product-design.md
```

`ModesSettingsTab` 只调整跨全局动作的快捷键冲突发现，不新增“改口模式”详情。

---

## 27. 兼容与迁移

### 27.1 老用户

- 不改 modes.json；
- 不增加 ProcessingMode；
- 不改变 currentMode 和 last selected mode；
- 不覆盖已有快捷键；
- `fn + R` 无 exact 冲突时可以作为全局动作默认；
- 有冲突时保存 nil，用户自行配置；
- 原历史表字段和 SELECT 顺序保持不变，新 revision 使用独立表。

### 27.2 旧版本回退

旧版本会忽略 `revise-settings.json` 和新 revision 表。它继续读取 `recognition_history`，不会删除新表。

禁止为了兼容旧版本把 revision 字段追加到 parent 的 `SELECT *` 列序中；独立表避免现有 row index 解码漂移。

### 27.3 Core schema

- 模型 response schema 与 history trace schema 独立版本化；
- response 未知版本直接拒绝；
- history trace 未知版本 UI 隐藏细节但保留 revision 正文；
- settings 未知版本安全禁用，不覆盖文件。

---

## 28. 发布、监控与回滚

### 28.1 上线前必须满足

- root `swift test` 全量通过；
- `swift build -c release` 各启用变体通过；
- ReviseEval critical 100%；
- 真实 App 测试 external wrong-target = 0；
- partial replacement failure = 0；
- 未授权关键事实变化 = 0；
- 敏感目标网络请求 = 0；
- 改口不改变 current mode；
- 改口不触发自我纠错/表达学习；
- parent 删除级联通过；
- 关闭 runtime flag 后普通输入完全不受影响。

### 28.2 灰度顺序

1. DEV build：runtime flag 默认 false，手动开启；
2. 内部 Beta：默认开启，收集本地无正文 metrics；
3. 公共 Beta：只对支持 tracked context 的控件开放；
4. 稳定版：新安装默认启用，老用户遵循冲突迁移。

### 28.3 快速回滚

设置 `tf_reviseRuntimeEnabled = false` 后：

- 下一次 binding 重注册移除改口快捷键；
- coordinator 清除 target/transaction/undo；
- 普通 `injectTracked` 仅在学习需要时运行；
- revision 历史保留可读；
- 不修改 modes.json；
- 不回滚数据库 schema；
- 不影响 Intelli Sense 观察与其他模式。

### 28.4 阻断事故

出现以下任一项立即关闭：

- 修改错误控件或错误文本范围；
- 处理期间覆盖用户新编辑；
- 替换失败破坏原文；
- 改口指令被粘贴进输入框；
- 目标全文或锚点进入日志；
- 敏感控件建立目标或发出网络请求；
- 普通模式快捷键被 `fn + R` 错误结束；
- revision 被学习为用户纠错；
- 外部动作被实际执行。

---

## 29. 开发验收检查表

### 29.1 架构

- [ ] 改口没有 `ProcessingMode` ID；
- [ ] `RecordingPurpose.revise` 不改变 currentMode；
- [ ] 只存在一个 AudioCaptureEngine、活动 ASR client 和 LLM cache；
- [ ] Core 与评测共用生产 Prompt/Guard；
- [ ] Coordinator 是唯一 target/transaction 状态源；
- [ ] Hotkey owner 能区分 mode 和 global action。

### 29.2 目标与并发

- [ ] 新成功注入取代旧目标；
- [ ] 失败和取消不取代；
- [ ] 10 分钟 generation-safe 过期；
- [ ] 同 App、同控件、非敏感、非 placeholder；
- [ ] 用户手改后 current revision 优先；
- [ ] LLM 期间任何全文变化阻止 commit；
- [ ] 不自动聚焦/切 App；
- [ ] 不回退全文搜索或整个输入框。

### 29.3 处理与安全

- [ ] 指令不经过 snippet；
- [ ] strict JSON，无纯文本 fallback；
- [ ] local undo 不调用 LLM；
- [ ] 指令授权后的事实保护；
- [ ] “只改/其他别动”局部门；
- [ ] 单行、翻译、代码、路径和外部动作约束；
- [ ] malformed/rejected 结果从不进入 replacement。

### 29.4 替换与撤销

- [ ] 写前 expected full value 一致；
- [ ] 只做选区级替换；
- [ ] 不写整个 AXValue；
- [ ] 写后 exact verification；
- [ ] 改口失败不污染剪贴板；
- [ ] deletion tombstone 可撤销；
- [ ] undo 前验证 afterText 未变化；
- [ ] 不支持 redo 或任意历史恢复。

### 29.5 历史与学习

- [ ] revision 独立表和 parent cascade；
- [ ] DB 失败不回滚已成功文字；
- [ ] HistoryTab 懒加载；
- [ ] 改口主动修改不进纠错/表达学习；
- [ ] post-revise 手改使用 revision baseline；
- [ ] 删除 parent 清 target；
- [ ] 日志和 metrics 无正文。

---

## 30. 最终实现契约

实现完成后，系统必须满足以下不可妥协的技术契约：

> 改口是一种独立录音目的和全局快捷动作，不是模式。Type4Me 只对最近一次成功注入且仍可由原 AX 控件、注入范围和锚点唯一证明的文字建立目标。开始改口时冻结用户手改后的当前版本；模型只返回结构化候选，Core 根据编辑指令授权范围验证事实与 diff；提交前要求控件全文仍与冻结版本完全一致，只通过选区级写入应用并进行写后验证。任何目标、指令、并发状态或写入结果不确定时保留外部文字。成功 revision 归属于原历史记录，并与用户手改观察隔离；撤销只反向应用最近一次仍可证明安全的 revision。

---

## 31. 实施注意事项（评审补充）

以下三点来自设计评审，均为非阻塞项，不影响按阶段 A→D 开工，但实现时必须处理，避免留下枚举缺口或破坏现有注入路径。

### 31.1 补齐失败枚举与文案映射

正文中出现但未纳入 `ReviseFailure`（§21.1）与错误文案表（§16.5）的失败原因，实现时必须统一收敛，不得出现"文中提及但代码无对应 case"的悬空状态：

- `noEditableTarget`（§8.8 删除到空后的 undo-only tombstone，用户说非撤销指令时返回）；
- `responseTooLong` / `responseTooLarge`（§4.4 响应超预算，命名以最终代码为准，需与 `ReviseInputBudget` 一致）；
- `diffBudgetExceeded`（§5.3 本地 diff 计算超时）；
- `targetTooLong` / `instructionTooLong`（§4.4 已在枚举中，需确认预检路径实际抛出）。

要求：

- 每个失败原因都要在 `ReviseFailure` 有稳定 case，并在 §16.5 文案表和 `ReviseMetrics` 失败枚举中一一对应；
- undo-only tombstone 下的非撤销指令应映射为明确可行动文案（例如"上一轮内容已删除，只能撤销"），不复用 `noTarget`；
- 补齐后同步更新产品设计 §20.3 的失败原因指标枚举，保持产品与开发一致。

### 31.2 复杂 AX 应用的替换可行性（实现风险，非设计缺陷）

`TrackedTextReplacementEngine`（§12）依赖 `kAXSelectedTextAttribute` 选区级写入，在 Electron、`contenteditable` 富文本、部分 Web 编辑器中 `kAXSelectedTextAttribute` 常不可写或写后验证不通过。这不是设计缺陷，已由 §22.9 真实 App 手工矩阵与"partial failure = 0"发布门（§12.7、§28.1）前置覆盖。实现时要求：

- 严格执行 §12.4 的策略优先级与 §12.6 写后验证，任何无法证明成功的结果落到 `partialFailure` 并阻断发布，不得放宽写前/写后检查换取覆盖率；
- 对写入策略不被支持的控件，宁可在激活预检或写前检查阶段安全失败（保留原文），也不做不可证明的启发式替换；
- 手工矩阵按 App 记录替换策略命中情况与失败类型，作为 Beta 灰度的准入证据。

### 31.3 剪贴板组件提取不得破坏现有注入路径

§12.5 要求把 `TextInjectionEngine.ClipboardSnapshot` 提取为 package-private 共享组件供替换引擎复用。实现时：

- 提取为重构而非复制，保持普通注入与改口两条路径共用同一实现，避免行为漂移；
- 明确区分两种恢复语义——普通注入失败时可保留文本到剪贴板，改口失败必须不把候选留在剪贴板（§12.5、§13.3），由调用参数显式区分；
- 提取后必须回归现有 `TextInjectionEngine` 相关测试，确认普通输入的剪贴板保存/恢复与 changeCount 守卫行为不变。
