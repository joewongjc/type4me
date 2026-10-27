# 选中纠正（Correct）开发设计

> 文档类型：开发设计
> 文档状态：当前有效（设计完成，待实现）
> 适用平台：Type4Me iPhone 键盘（首版）
> 设计日期：2026-10-27
> 最后校验：2026-10-27
> 上游文档：`docs/features/voice-correction/product-design.md`、`docs/features/mobile-app/design.md`

---

## 1. 设计摘要

- **触发：** 键盘读到宿主输入框里有选中文字时，进入纠正待命；按住说话发起的是纠正，不是听写。
- **通路：** 复用现有的键盘 ↔ 主 App 通路（`iOS/Shared/DictationIPC.swift`）。录音和识别流程不变，只在 `VoiceSession.complete` 里按用途分流：听写走模式处理，纠正走纠正提示词。
- **核心逻辑：** 放进新的跨平台模块 `Type4MeCorrectionCore`，与 `Type4MeTransferCore` 同级，iPhone 的 App 和键盘都链接它，Mac 上用 `swift test` 测试。将来做 Mac 版时可以直接复用。核心逻辑包括：
  - 标出同段文字里的其他相同文字；
  - 构造提示词；
  - 解析和校验模型返回；
  - 规划替换步骤。
- **替换：** 选中的那一处由 `insertText` 直接覆盖选中内容。其他几处从后往前，用移动光标、删除、插入完成，每一步都核对前后文，任何一步不符就停下，只保留已确认的修改。
- **记住热词：** 新增一种键盘指令，由主 App 在后台写入 `VocabularyStore`。主 App 不在后台时，写进 App Group 里的待办文件，下次启动时合并。

## 2. 当前实现基线

| 位置 | 现状 | 本功能的关系 |
|---|---|---|
| `iOS/Shared/DictationIPC.swift` | `KeyboardCommand` 有 start / stop / cancel / ping / delivered；`DictationState` 回传 `finalText`；`FieldContext` 携带前 300、后 100 字 | 增加纠正上下文、纠正结果、记住热词指令 |
| `iOS/Keyboard/KeyboardModel.swift` | 状态机：`idle` / `recording` / `processing`；`deliver` 插入文字并记录撤销；撤销靠 `documentContextBeforeInput` 的后缀核对 | 增加纠正状态、选中检测、多处替换、整组撤销 |
| `iOS/Keyboard/KeyboardViewController.swift` | 只重写了 `textDidChange` | 增加 `selectionDidChange`，触发选中检测 |
| `iOS/Keyboard/KeyboardRootView.swift` | 顶栏为拨盘、收起键盘、设置；底排三键 | 顶栏在纠正状态下换成纠正标签或结果条 |
| `iOS/App/Pipeline/VoiceSession.swift` | `complete(_:)`：片段替换 → 模式处理（含智能感知、翻译校验）→ `finish` | 纠正分支：不做片段替换和模式处理，改用纠正提示词 |
| `iOS/App/Model/VocabularyStore.swift` | 存在主 App 的 Application Support 里，键盘读不到 | 由主 App 写入；待办文件放 App Group |
| `iOS/App/LLM/ChatClient.swift` | `complete(system:user:)` | 直接复用 |
| `Sources/Type4MeIntelliSenseCore` | 敏感文本扫描；只有主 App 链接，键盘不链接 | 敏感扫描在主 App 里做 |
| 录音 | 音频分块直接转发给识别服务，不保留 | 首版不需要原始录音 |

## 3. 模块划分

```text
Sources/Type4MeCorrectionCore/          新增，纯逻辑，无 UIKit 依赖
├── CorrectionRequest.swift             请求模型：前文 / 选中 / 后文 / 纠正原话 / 历次尝试
├── CorrectionOccurrences.swift         在前后文里找出与选中内容相同的其他位置并编号
├── CorrectionPrompt.swift              构造 system / user 提示词
├── CorrectionResponse.swift            解析严格 JSON，校验并给出最终结果
└── CorrectionEditPlan.swift            从结果生成从后往前的替换步骤

iOS/Shared/DictationIPC.swift           扩展指令与状态（见第 5 节）
iOS/Shared/PendingVocabulary.swift      新增，App Group 里的待加热词队列
iOS/Keyboard/KeyboardModel.swift        纠正状态机、选中检测、执行替换、整组撤销
iOS/Keyboard/KeyboardViewController.swift   selectionDidChange
iOS/Keyboard/KeyboardRootView.swift     纠正标签、结果条、说明文字
iOS/App/Pipeline/VoiceSession.swift     纠正分支、记住热词指令
iOS/App/Pipeline/CorrectionRunner.swift 新增，调用模型、敏感检查、无模型时的兜底

Tests/Type4MeTests/CorrectionCoreTests.swift   新增
```

`Package.swift` 新增库目标 `Type4MeCorrectionCore`，测试目标依赖它。`iOS/project.yml` 新增同名框架目标，`Type4MeiOS` 和 `Type4MeKeyboard` 都依赖它，修改后运行 `xcodegen generate`。

## 4. 核心模块 `Type4MeCorrectionCore`

### 4.1 请求模型

```swift
public struct CorrectionRequest: Codable, Equatable, Sendable {
    public var before: String          // 选中内容之前的文字，最多 300 字
    public var selected: String        // 选中内容，1…50 字
    public var after: String           // 选中内容之后的文字，最多 100 字
    public var spoken: String          // 纠正那句话的识别结果
    public var attempts: [String]      // 本轮纠正里之前替换过的写法，最早的在前
    public var includeContext: Bool    // 敏感时为 false：只发选中内容和原话
}
```

`attempts` 由键盘维护：在"已纠正"状态下再次纠正时，把上一次替换前的原词和每次替换后的写法都放进来，表示"这些都不对"。

### 4.2 其他位置

`CorrectionOccurrences.find(in: before, after:, matching: selected)` 返回按文中顺序编号的位置列表：

- **匹配方式：** 区分大小写的完全匹配，按 `Character` 计数。
- **字母数字边界：** 选中内容以字母或数字开头或结尾时，相邻字符也是字母或数字的位置不算匹配，避免 "AA" 匹配进 "AAA"。中文不做边界限制。
- **数量上限：** 最多 10 处，超出的不处理。

### 4.3 提示词

提示词使用带编号标记的原文，选中的那一处标为 `⟦*⟧`，其他位置标为 `⟦1⟧`、`⟦2⟧` 等：

```text
我们下周跟 ⟦1⟧AA⟦/1⟧ 的人还有 ⟦*⟧AA⟦/*⟧ 开会，AA 制
```

system 提示词要点（中英两版，按 App 语言选择，内容等价）：

1. 语音输入中被选中的 `⟦*⟧` 部分识别错了，用户刚才口头说明了正确内容。
2. 用户的话也经过语音识别，可能同样有误；如果它和被选中的内容一样或读音相近，说明这是同音或近音错误，应该根据上下文推断正确写法，而不是原样返回。
3. 用户的话可能是直接说出正确内容，也可能带有解释（"叹气那个欸""姓张，弓长张""英文缩写"），要提取出最终应写入的文字，不要把解释写进去。
4. `attempts` 里列出的写法都已被用户否定，不能再给。
5. 对每个编号位置判断是否是同一个错误，只有确定是同一个错误时才列入。
6. 只输出 JSON，不输出其他文字。

返回格式：

```json
{"replacement": "欸欸", "also": [1], "confidence": "high"}
```

或者，无法判断时：

```json
{"replacement": null, "reason": "unclear"}
```

### 4.4 解析与校验

`CorrectionResponse.resolve(raw:request:occurrences:)` 返回 `.replace(text, also: [Int])` 或 `.unclear`：

1. 容忍代码块围栏和前后空白，取第一个 JSON 对象。解析失败按 `.unclear` 处理。
2. `replacement` 为空、为 null、去掉首尾空白后与 `selected` 完全相同、或出现在 `attempts` 里时，结果为 `.unclear`。
3. **长度检查：** 长度不超过 `max(selected.count * 3, selected.count + 20)`，超出说明模型在改写整句，结果为 `.unclear`。
4. **换行检查：** 选中内容不含换行时，`replacement` 也不能含换行。
5. `also` 只保留合法编号，去重后升序；`includeContext == false` 时清空。

### 4.5 替换计划

`CorrectionEditPlan.make(...)` 把结果转成键盘可以执行的步骤。所有偏移都以选中内容的起点为基准，按 `Character` 计数：

1. **第一步替换选中的那一处。** `insertText(replacement)` 直接覆盖选中内容，完成后光标在新词后面。
2. **其他位置从后往前处理。** 先处理选中位置之后的，从最远的开始；再处理之前的，从最近的开始。这样每次修改都不会影响还没处理的位置的偏移。
3. **每一步包含三件事：**
   - 光标的相对移动量；
   - 移动后应看到的前文后缀，用于核对光标是否到了预期位置；
   - 要删除的字数和要插入的文字。
4. **最后一步把光标移回第一处新词的后面。**

计划同时生成撤销计划，即每一步的反向操作，用于整组撤销。

## 5. 通信扩展

`DictationIPC.swift` 里的所有新字段都是可选的。App 和键盘总是一起安装、一起更新，不需要考虑新旧版本混用。

```swift
struct KeyboardCommand {
    // …现有字段
    var purpose: Purpose? = nil          // nil 视为 .dictation
    var correction: CorrectionRequest?   // purpose == .correction 时在 start 上携带
    var hotword: String?                 // kind == .rememberHotword

    enum Purpose: String, Codable, Sendable { case dictation, correction }
}

enum Kind { …, case rememberHotword }

struct DictationState {
    // …现有字段
    var correction: CorrectionOutcome?   // 纠正完成时代替 finalText
    var rememberedHotword: String?       // 记住热词的回执
}

struct CorrectionOutcome: Codable, Equatable, Sendable {
    var replacement: String
    var also: [Int]                      // 其他位置的编号
    var usedRawSpeech: Bool              // 没有模型时直接用了识别原文
}
```

**纠正上下文的读取时机：** 在 `start` 时读取并发送，而不是像智能感知那样在 `stop` 时再读一次。录音期间宿主的选中状态不会变化，而且键盘需要按 `start` 时的快照计算替换计划。

## 6. 主 App：`VoiceSession` 与 `CorrectionRunner`

### 6.1 分流

- **`startDictation`：** 把 `command.purpose` 和 `command.correction` 记到 `Run` 上。录音、识别、热词提示完全复用。
- **热词提示：** 识别纠正的话时，在现有热词之外，额外把 `selected` 加入这次请求的识别提示。服务商对热词有数量限制时，加到列表最前面。
- **`complete`：** `run.purpose == .correction` 时交给 `CorrectionRunner`，跳过片段替换和模式处理。识别结果为空时，按现有流程返回"没有听到内容"。

### 6.2 `CorrectionRunner.run(spoken:request:) async -> Result`

1. **敏感检查：** 用 `IntelliSenseSensitiveTextScanner` 扫描 `before + selected + after`。命中时把 `includeContext` 置为 false，并清空 `before` 和 `after`。
2. **没有配置模型时：** 返回 `CorrectionOutcome(replacement: spoken, also: [], usedRawSpeech: true)`。如果 `spoken` 与 `selected` 相同，返回"没听清"的失败。
3. **有模型时：** 构造提示词并调用 `ChatClient.complete`，再用 `CorrectionResponse.resolve` 处理返回。结果为 `.unclear` 时返回失败，错误文案是"没听清要改成什么，再说一次"。
4. **超时：** 与模式处理共用现有的 30 秒处理超时。
5. **诊断记录：** 写入耗时、替换前后的词和处理位置数。不记录前后文。

### 6.3 回传

- **成功：** 写 `state.phase = .done`、`state.correction = outcome`，`finalText` 留空。不写历史记录，见产品设计第 10 节。
- **失败：** 与听写失败相同，写 `.failed` 和 `errorMessage`。

### 6.4 记住热词

- 收到 `.rememberHotword` 时，调用 `VocabularyStore.shared.addHotword`，然后写 `state.rememberedHotword` 回执。
- 词已存在时也写回执，键盘把按钮显示为"已记住"。
- 键盘发出指令后 1.2 秒内没有收到回执（与现有 start 的看门狗时长相同），说明主 App 不在后台。这时键盘把词追加到 `PendingVocabulary`，即 App Group 里的 `pending-hotwords.json`。
- 主 App 在 `AppModel.init` 和 `didBecomeActive` 时合并待加热词，然后清空队列。

## 7. 键盘

### 7.1 选中检测

- `KeyboardViewController` 重写 `selectionDidChange(_:)` 和现有的 `textDidChange(_:)`，两者都调用 `model.refreshSelection()`。
- `refreshSelection` 读取 `proxy.selectedText`，满足以下条件时进入纠正待命：
  1. `phase == .idle`；
  2. 选中内容去掉首尾空白后为 1…50 字；
  3. 输入框不敏感（复用 `fieldContext` 里的规则：敏感内容类型和数字键盘）。
- 选中内容超过 50 字时不进入纠正，每次选中只提示一次"选中内容太长"。
- **键盘出现时：** 在 `appeared()` 里也调用一次 `refreshSelection`，处理用户先选中、再切换到 Type4Me 键盘的情况。

### 7.2 状态

```swift
enum CorrectionStage: Equatable {
    case none
    case armed(Target)               // 有选中内容，等待按住
    case corrected(Target, Applied)  // 刚替换完，光标停在新词后面
}

struct Target {
    var request: CorrectionRequest   // 不含 spoken
    var occurrences: [Occurrence]
    var documentID: UUID?
}

struct Applied {
    var replacement: String
    var undo: CorrectionEditPlan.Undo
    var anchor: String               // 新词后面应有的前文后缀，用于判断光标是否离开
}
```

- **与现有状态的关系：** `phase` 仍然管录音和处理；`correctionStage` 独立存放。`micPressed` 在 `correctionStage != .none` 时发出 `purpose: .correction` 的 `start`。
- **从"已纠正"再次纠正：** 构造一个新的 `CorrectionRequest`。`selected` 是上次的替换结果，`before` 和 `after` 是当前前后文，`attempts` 在原来的基础上追加上次替换前的原词和这次的替换结果。这次只处理新词所在的一处，因为其他几处在上一轮已经一起改过。如果再次纠正成功，同样用新结果覆盖那几处：键盘仍记得上一轮改过的位置，按同样方法替换。
- **退出纠正：** 以下情况调用 `exitCorrection()`：
  - 点 ×；
  - `refreshSelection` 发现选中内容消失，且当前不是 `corrected` 状态；
  - 在 `corrected` 状态下，前文后缀与 `anchor` 不符，说明光标离开了；
  - 键盘消失、`documentIdentifier` 变化，或在普通状态下开始一次听写。

### 7.3 执行替换

`applyCorrection(_ outcome:)` 依次执行替换计划：

1. **执行前核对：** `documentIdentifier` 与 `start` 时相同，`selectedText` 仍等于 `selected`。不符时把结果复制到剪贴板并提示，与现有 `deliver` 的输入框变化处理一致。
2. **替换选中的那一处：** 执行 `insertText(replacement)`。
3. **处理其他位置：** 逐步执行 `adjustTextPosition`、`deleteBackward`、`insertText`。每一步前读取 `documentContextBeforeInput`，核对后缀与计划一致。
   - **等待前文更新：** 现有撤销代码已经注意到，前文在删除生效之后才更新。因此每一步之后等待前文变成预期内容，最多等 300 毫秒。
   - **任何一步不符就停止：** 把光标移回第一处新词后面，提示"其他几处没能一起改"。已完成的替换保留，并纳入撤销计划。
4. **收尾：** 进入 `corrected` 状态，触发成功的触感反馈，显示结果条。

### 7.4 撤销与重做

- 现有的 `lastInsertion` / `Redo` 只适合"在光标前插入一段文字"这一种操作。纠正改成在 `KeyboardModel` 里维护一个 `UndoEntry`，它有两种情况：现有的插入，或者一次纠正的撤销计划。
- **撤销纠正：** 执行撤销计划，从前往后逐步恢复，并同样逐步核对。核对不符时停下，提示"光标位置变了，没法撤销"。
- **重做：** 重新执行替换计划。

### 7.5 界面

- `KeyboardRootView` 顶栏中部按 `correctionStage` 显示：
  - 模式拨盘；
  - 纠正标签：文字加 ×，强调色胶囊；
  - 结果条：成功色胶囊，后面跟"记住"按钮。
- 拨盘在纠正状态下淡出，沿用 `modeBarOpen` 时的淡出方式。
- 麦克风图标和说明文字在纠正状态下替换，录音和处理时沿用现有的隐藏规则。
- 标签里的选中内容超过 8 个字时，只显示前 8 个字加省略号。
- 所有文案在 `L(_, _)` 里同时给中英文，见产品设计第 11 节。
- 无障碍：
  - 纠正标签读作"纠正 AA，按钮，退出纠正"；
  - 麦克风读作"按住说出正确内容"。

## 8. 隐私

- **前后文：** 纠正上下文不受 `SharedSettings.intelliSenseContext` 开关控制，因为纠正必须有上下文。设置页"读取上下文"的说明文字需要补一句"选中纠正始终会发送选中内容附近的文字"。
- **敏感输入框：** 在键盘上就挡住，不会进入纠正状态。
- **敏感文本：** 在主 App 里扫描后去掉前后文。
- **诊断记录：** 只记录替换前后的词，不记录前后文。

## 9. 测试

### 9.1 自动测试（`Tests/Type4MeTests/CorrectionCoreTests.swift`）

| 用例 | 覆盖 |
|---|---|
| 其他位置查找 | 中文、英文边界（AA 不匹配 AAA）、上限 10 处、选中内容在开头或结尾 |
| 提示词 | 标记位置正确；`includeContext == false` 时不含前后文；`attempts` 写入 |
| 返回解析 | 围栏代码块、多余文字、非法 JSON、null、与选中相同、命中 attempts、过长、含换行、非法编号 |
| 替换计划 | 只有选中处；前后都有其他位置；偏移按 Character 计算（含 emoji 和中英混排）；撤销计划可逆 |
| 中英文 | 两种语言的 system 提示词都能生成，结构一致 |

### 9.2 真机清单（写进 `iOS/README.md` 的验证清单）

1. 在备忘录、信息、微信、邮件、Safari 的 `textarea` 和 `contenteditable` 里分别试：
   - 单处替换；
   - 多处替换；
   - 整组撤销；
   - 继续纠正。
2. 记录 `selectedText` 返回 nil，或 `adjustTextPosition` 行为异常的 App，用于决定是否针对个别情况退回到只改一处。
3. 主 App 不在后台时，点"记住"会进入待办；打开 App 后，热词出现在列表里。
4. 在中英文界面下分别截图检查。

## 10. 风险

| 风险 | 影响 | 对策 |
|---|---|---|
| 部分 App 的 `selectedText` 返回 nil | 进不了纠正状态 | 真机清单记录；首版接受，必要时增加键盘内输出卡片点选 |
| `adjustTextPosition` 在 emoji 或组合字符处计数不一致 | 多处替换时偏到错误位置 | 每步核对前文后缀，不符即停 |
| 前文更新有延迟 | 核对误判 | 每步等待前文变成预期内容，最多 300 毫秒 |
| 模型把解释性的话写进替换结果 | 替换成整句话 | 提示词约束，加上长度和换行校验 |
| 纠正的话被识别成别的错误写法 | 改错 | 用户可以继续纠正，`attempts` 逐步排除；撤销一步回到原样 |

## 11. 实现步骤

1. **核心模块：** 新建 `Type4MeCorrectionCore` 与单元测试，覆盖其他位置查找、提示词、返回解析、替换计划。
2. **通信与主 App：** 扩展 `DictationIPC`，在 `VoiceSession` 中增加纠正分支、`CorrectionRunner` 和记住热词指令，以及 `PendingVocabulary`。
3. **键盘状态：** 实现选中检测、纠正状态机、单处替换和撤销，界面加上纠正标签、结果条和说明文字。
4. **多处替换：** 实现逐步核对和失败回退，整组撤销与重做。
5. **补充与验证：** 在设置页补充说明文字，更新 `iOS/README.md` 的真机清单，在中英文界面下检查。
