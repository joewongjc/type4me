# 选中纠正（Correct）开发设计

> 文档类型：开发设计
> 文档状态：当前有效（已实现，持续验证）
> 适用平台：Type4Me iPhone 键盘（首版）
> 设计日期：2026-10-27
> 最后校验：2026-10-27
> 实现基线：`d8081b71`（PR #392）
> 上游文档：`docs/features/voice-correction/product-design.md`、`docs/features/mobile-app/design.md`

---

## 1. 设计摘要

- **触发：** 键盘读到宿主输入框里有选中文字时，进入纠正待命。此时按住说话发起的是纠正，不是听写。
- **通路：** 复用现有的键盘 ↔ 主 App 通路，见 `iOS/Shared/DictationIPC.swift`。录音和识别流程不变。在 `VoiceSession.complete` 里按用途分流：听写走模式处理，纠正走纠正提示词。
- **核心逻辑：** 放进新的跨平台模块 `Type4MeCorrectionCore`，在 Mac 上用 `swift test` 测试，将来做 Mac 版也能直接用。模块负责：
  - 查找其他相同位置；
  - 构造提示词；
  - 解析模型返回。
- **替换：**
  - 选中的那一处，用 `insertText` 覆盖。
  - 其他位置从后往前处理：移动光标，核对原词还在，再删除、插入，最后把光标移回原处。
- **记住热词：** 键盘发一条指令，由主 App 在后台写入 `VocabularyStore`。

## 2. 现有代码

| 位置 | 现状 | 本功能要做的事 |
|---|---|---|
| `iOS/Shared/DictationIPC.swift` | 指令有 start / stop / cancel / ping / delivered，状态通过 `finalText` 回传 | 增加纠正请求、纠正结果，以及记住热词指令 |
| `iOS/Keyboard/KeyboardModel.swift` | 状态机加上 `deliver`、撤销、重做 | 增加纠正状态、选中检测、替换和整组撤销 |
| `iOS/Keyboard/KeyboardViewController.swift` | 只重写了 `textDidChange` | 增加 `selectionDidChange` |
| `iOS/Keyboard/KeyboardRootView.swift` | 顶栏是拨盘、收起键盘、设置 | 纠正状态下显示纠正标签或结果条 |
| `iOS/App/Pipeline/VoiceSession.swift` | `complete` 依次做片段替换、模式处理、`finish` | 增加纠正分支 |
| `iOS/App/Model/AIConsent.swift` | 文本模型的授权键是 `llm:<provider>:context` | 授权键升级，说明文字补上纠正 |
| `docs/legal/ios-privacy.md` | 文本模型只用于模式处理 | 补上纠正 |

## 3. 模块划分

```text
Sources/Type4MeCorrectionCore/          新增，纯逻辑
├── CorrectionOccurrences.swift         查找其他相同位置并编号
├── CorrectionPrompt.swift              提示词
└── CorrectionResponse.swift            解析模型返回

iOS/Shared/CorrectionMessages.swift     通信用的请求与结果类型，只用基础类型
iOS/Shared/DictationIPC.swift           扩展指令与状态
iOS/Keyboard/KeyboardModel.swift        纠正状态、替换、撤销
iOS/Keyboard/KeyboardViewController.swift   selectionDidChange
iOS/Keyboard/KeyboardRootView.swift     纠正标签、结果条、说明文字
iOS/App/Pipeline/VoiceSession.swift     纠正分支、记住热词
iOS/App/Pipeline/CorrectionRunner.swift 调用模型；没有模型时直接用原话
iOS/App/Model/AIConsent.swift           授权键与说明

Tests/Type4MeTests/CorrectionCoreTests.swift
```

依赖关系：

- `Package.swift` 新增库目标 `Type4MeCorrectionCore`，测试目标依赖它。
- `iOS/project.yml` 新增同名框架，`Type4MeiOS` 和 `Type4MeKeyboard` 依赖它。
- `iOS/Shared` 也会被 Widget 编译，所以 `Shared` 里不引用这个模块。
- 改完后运行 `xcodegen generate`。

## 4. 核心模块

### 4.1 其他位置

`CorrectionOccurrences.find(before:after:matching:)` 在前后文里做完全匹配，按文中顺序编号，按 `Character` 计数。是不是同一个错误由模型判断，这里不做任何过滤。

### 4.2 提示词

原文里，选中的那一处标为 `⟦*⟧`，其他相同的位置依次标为 `⟦1⟧`、`⟦2⟧`：

```text
我们下周跟 ⟦1⟧AA⟦/1⟧ 的人还有 ⟦*⟧AA⟦/*⟧ 开会，AA 制
```

system 提示词要点如下。中英两版内容等价，按 App 语言选择。

1. `⟦*⟧` 部分识别错了，用户刚才口头说明了正确内容。
2. 用户的话也经过语音识别。如果它和选中内容相同或读音相近，说明是同音或近音错误，要根据上下文推断正确写法。
3. 用户可能直接说出正确内容，也可能附带解释，比如"叹气那个欸""姓张，弓长张"。只返回最终要写入的文字，不要写入解释。
4. 用户也可能把整句完整地重新说一遍。这时直接返回这句话。
5. `attempts` 里的写法用户都已经否定过，不能再给。
6. 对每个编号位置，判断它是不是同一个错误。
7. 只输出 JSON：

```json
{"replacement": "欸欸", "also": [1]}
```

无法判断时，输出 `{"replacement": null}`。

### 4.3 解析

`CorrectionResponse.resolve(raw:selected:attempts:)` 的处理：

- 能容忍代码块围栏和多余的空白，取第一个 JSON 对象。
- 以下情况返回 `.unclear`：
  - 解析失败；
  - `replacement` 为空；
  - `replacement` 与选中内容相同；
  - `replacement` 出现在 `attempts` 里。
- `also` 中不合法的编号直接丢弃。

## 5. 通信

新增 `iOS/Shared/CorrectionMessages.swift`：

```swift
struct CorrectionRequest: Codable, Equatable, Sendable {
    var before: String          // 关闭"读取上下文"时为空
    var selected: String
    var after: String
    var attempts: [String]
}

struct CorrectionOutcome: Codable, Equatable, Sendable {
    var replacement: String
    var also: [Int]
}
```

`DictationIPC.swift` 的扩展：

```swift
struct KeyboardCommand {
    // …现有字段
    var correction: CorrectionRequest?   // 在 start 上携带；不为 nil 即表示这是一次纠正
    var hotword: String?                 // kind == .rememberHotword
}

enum Kind { …, case rememberHotword }

struct DictationState {
    // …现有字段
    var correction: CorrectionOutcome?   // 纠正完成时代替 finalText
    var rememberedHotword: String?       // 记住热词的回执
}
```

## 6. 主 App

- **`startDictation`：** 把 `command.correction` 记到 `Run` 上，其余流程完全复用。
- **`complete`：** 有纠正请求时交给 `CorrectionRunner`，跳过片段替换和模式处理。
- **`CorrectionRunner`：**
  - 没有配置文本模型时，直接返回识别原文；
  - 有模型时，构造提示词，调用 `ChatClient.complete`，再解析返回；
  - 结果为 `.unclear` 时，返回失败，提示"没听清要改成什么，再说一次"。
- **前后文：** 沿用智能感知的规则。
  - 键盘在关闭"读取上下文"或输入框敏感时，不读取前后文；
  - 主 App 用现有的敏感扫描检查前后文，命中就去掉前后文。
- **回传：**
  - 成功时写 `state.correction`；
  - 失败时与听写失败相同。
  - 纠正不写入历史记录。
- **诊断记录：** 只记录耗时、结果，以及一共改了几处。
- **记住热词：**
  - 收到 `.rememberHotword` 时调用 `VocabularyStore.shared.addHotword`，然后写回执。
  - 纠正刚刚完成，主 App 一定还在后台，所以不另做待办队列。
  - 万一没收到回执，提示"没能记住，打开 Type4Me 再试"。
- **授权：**
  - 文本模型的授权键改为 `llm:<provider>:correction`；
  - 说明文字补上"选中纠正时，接收选中的文字、你说的话，以及开启「读取上下文」时附近的文字"；
  - 隐私政策中英文两段同步修改。

## 7. 键盘

### 7.1 选中检测

- `selectionDidChange`、`textDidChange` 和 `appeared()` 都调用 `refreshSelection()`。
- `refreshSelection()` 读取 `proxy.selectedText`：
  - 有选中内容，并且输入框不属于敏感类型（复用 `fieldContext` 的规则）时，进入纠正待命；
  - 没有选中内容，并且当前不是"已纠正"状态时，退出纠正。

### 7.2 状态

```swift
enum CorrectionStage: Equatable {
    case none
    case armed(selected: String, request: CorrectionRequest, occurrences: [Occurrence])
    case corrected(original: String, replacement: String, attempts: [String])
}
```

- **发起纠正：** `micPressed` 在 `armed` 或 `corrected` 状态下发出带 `correction` 的 `start`。
- **退出纠正：** 以下情况回到 `none`：
  - 点 ×；
  - 键盘消失；
  - 在 `corrected` 状态下，前文不再以新词结尾。

### 7.3 替换

- **选中处：**
  1. 确认 `selectedText` 仍然是原来的选中内容；
  2. 调用 `insertText(replacement)`；
  3. 如果选中内容已经变了，就把结果复制到剪贴板。这和现有 `deliver` 在输入框变化时的处理一样。
- **再次纠正：**
  1. 确认前文以上次的结果结尾；
  2. 删除上次结果的长度；
  3. 插入新结果。
- **其他位置：** 从后往前，逐处执行：
  1. 用 `adjustTextPosition` 把光标移到这一处的末尾；
  2. 确认前文以原词结尾，不符就跳过这一处；
  3. 删除原词，插入新词。

  全部处理完后，把光标移回选中处新词的后面。提示里的"共 N 处"只统计实际改成的位置。
- **等待：** 前文要等修改生效后才会更新，所以每一步之后，最多等 300 毫秒，直到前文变成预期内容。

### 7.4 撤销

- 把撤销记录扩展为两种：
  - 现有的"插入一段文字"；
  - "一次纠正"，记录每一处的原词和新词。
- 撤销一次纠正时，按相反的顺序逐处恢复原词，方法和替换相同。
- 重做时重新执行一遍替换。

### 7.5 界面

- 顶栏中部按状态显示：
  - 普通：模式拨盘；
  - 纠正待命：纠正标签，即文字加 ×，强调色胶囊；
  - 已纠正：结果条，成功色胶囊加"记住"按钮。
- 拨盘的淡出沿用 `modeBarOpen` 的方式。
- 麦克风图标和说明文字按状态替换。录音时上下两排照旧隐藏。
- 标签里的选中内容超过 8 个字时，截断加省略号。
- 所有文案都用 `L(_, _)` 同时提供中英文，见产品设计第 10 节。

## 8. 测试

- **自动测试：** `CorrectionCoreTests` 覆盖以下内容：
  - 其他位置的查找，包括中英文、emoji、选中内容在开头或结尾；
  - 提示词的标记；
  - 返回解析，包括围栏、非法 JSON、null、与选中相同、命中 attempts、不合法的编号。
- **真机验证：**
  - 在备忘录、信息、微信、邮件、Safari 里试：单处、多处、撤销、再次纠正、记住热词；
  - 中英文界面各检查一遍。
  - 遇到哪个 App 的 `selectedText` 或移动光标不正常，就在 `iOS/README.md` 里记下来。

## 9. 实现步骤

1. 核心模块和单元测试。
2. 通信、主 App 的纠正分支、记住热词、授权和隐私政策。
3. 键盘：选中检测、纠正状态、选中处替换、再次纠正、撤销、界面。
4. 一起改其他位置。
5. 在真机上验证。
