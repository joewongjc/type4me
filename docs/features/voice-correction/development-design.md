# 选中纠正（Correct）开发设计

> 文档类型：开发设计
> 文档状态：当前有效（设计完成，待实现）
> 适用平台：Type4Me iPhone 键盘（首版）
> 设计日期：2026-10-27
> 最后校验：2026-10-27
> 上游文档：`docs/features/voice-correction/product-design.md`、`docs/features/mobile-app/design.md`

---

## 1. 设计摘要

- **触发：** 键盘读到宿主输入框里选中了 1–50 个字，且内容不敏感时，进入纠正待命；这时按住说话发起的是纠正，不是听写。有选中内容但不能纠正时，麦克风不可用，不会退回普通听写。
- **通路：** 复用现有的键盘 ↔ 主 App 通路（`iOS/Shared/DictationIPC.swift`）。录音和识别流程不变，选中内容不发给识别服务；在 `VoiceSession.complete` 里按用途分流：听写走模式处理，纠正走纠正提示词。
- **核心逻辑：** 放进新的跨平台模块 `Type4MeCorrectionCore`，在 Mac 上用 `swift test` 测试，将来做 Mac 版时可以直接复用。它负责标出同段里的其他相同文字、构造提示词、解析和校验模型返回、规划替换步骤。通信用的数据类型放在 `iOS/Shared` 里，只用基础类型，Widget 不需要依赖这个模块。
- **替换：**
  - 选中的那一处在执行前核对目标指纹，一致才用 `insertText` 覆盖。
  - 再次纠正走光标锚点流程。
  - 其他位置只在用户点"一起改"后修改：每处删除前、插入后都要核对，不符就停下。
- **记住热词：** 新增一种键盘指令，由主 App 在后台写入 `VocabularyStore`。主 App 不在后台时，写进 App Group 里的待办文件，下次启动时合并。
- **隐私：**
  - 选中内容在键盘和主 App 两端都做敏感扫描。
  - 前后文受"读取上下文"开关控制。
  - 授权键升级，让已同意的用户重新确认。
  - 诊断记录只记元数据。

## 2. 当前实现基线

| 位置 | 现状 | 本功能的关系 |
|---|---|---|
| `iOS/Shared/DictationIPC.swift` | `KeyboardCommand` 有 start / stop / cancel / ping / delivered；`DictationState` 回传 `finalText`；`FieldContext` 携带前 300、后 100 字 | 增加纠正请求、纠正结果、记住热词指令 |
| `iOS/project.yml` | `Shared` 目录被 App、键盘、Widget 三个目标一起编译；键盘不链接 `Type4MeIntelliSenseCore` | 键盘新增 `Type4MeIntelliSenseCore` 和 `Type4MeCorrectionCore` 依赖；`Shared` 不引用新模块 |
| `iOS/Keyboard/KeyboardModel.swift` | 状态机：`idle` / `recording` / `processing`；`deliver` 插入文字并记录撤销；撤销靠 `documentContextBeforeInput` 的后缀核对 | 增加纠正状态、选中检测、目标指纹、替换与撤销 |
| `iOS/Keyboard/KeyboardViewController.swift` | 只重写了 `textDidChange` | 增加 `selectionDidChange` |
| `iOS/Keyboard/KeyboardRootView.swift` | 顶栏为拨盘、收起键盘、设置；底排三键 | 顶栏在纠正状态下换成纠正标签或结果条 |
| `iOS/App/Pipeline/VoiceSession.swift` | `complete(_:)`：片段替换 → 模式处理（含智能感知、翻译校验）→ `finish` | 纠正分支：不做片段替换和模式处理，改用纠正提示词 |
| `iOS/App/Model/AIConsent.swift` | 按服务记授权键；文本模型的键是 `llm:<provider>:context`，说明里只列了模式处理和智能感知上下文 | 授权键升级为 `llm:<provider>:correction`，说明补上纠正 |
| `docs/legal/ios-privacy.md` | 文本模型只在模式处理时接收文字；诊断记录不含口述内容 | 补上纠正发送的内容 |
| `iOS/App/Model/VocabularyStore.swift` | 存在主 App 的 Application Support 里，键盘读不到 | 由主 App 写入；待办文件放 App Group |
| `iOS/App/LLM/ChatClient.swift` | `complete(system:user:)` | 直接复用 |
| `Sources/Type4MeIntelliSenseCore` | 敏感文本扫描 `IntelliSenseSensitiveTextScanner`，约 1500 行纯逻辑 | 键盘和主 App 都用它扫描 |
| 录音 | 音频分块直接转发给识别服务，不保留 | 首版不需要原始录音 |

## 3. 模块划分

```text
Sources/Type4MeCorrectionCore/          新增，纯逻辑，无 UIKit 依赖
├── CorrectionOccurrences.swift         在前后文里找出与选中内容相同的其他位置并编号
├── CorrectionPrompt.swift              构造 system / user 提示词
├── CorrectionResponse.swift            解析严格 JSON，校验并给出最终结果
└── CorrectionEditPlan.swift            选中处、再次纠正、一起改三种替换步骤与撤销步骤

iOS/Shared/CorrectionMessages.swift     新增：通信用的请求与结果类型，只用基础类型
iOS/Shared/DictationIPC.swift           扩展指令与状态（见第 5 节）
iOS/Shared/PendingVocabulary.swift      新增：App Group 里的待加热词队列
iOS/Keyboard/KeyboardModel.swift        纠正状态机、选中检测、目标指纹、执行替换、撤销
iOS/Keyboard/KeyboardViewController.swift   selectionDidChange
iOS/Keyboard/KeyboardRootView.swift     纠正标签、结果条、说明文字
iOS/App/Pipeline/VoiceSession.swift     纠正分支、记住热词指令
iOS/App/Pipeline/CorrectionRunner.swift 新增：敏感检查、调用模型、无模型时的兜底
iOS/App/Model/AIConsent.swift           授权键与说明

Tests/Type4MeTests/CorrectionCoreTests.swift   新增
```

依赖关系：

- `Package.swift` 新增库目标 `Type4MeCorrectionCore`，测试目标依赖它。
- `iOS/project.yml` 新增同名框架目标。`Type4MeiOS` 和 `Type4MeKeyboard` 依赖它和 `Type4MeIntelliSenseCore`；`Type4MeWidgets` 不变。
- `iOS/Shared` 里的文件不 `import` 这两个模块。核心模块的输入输出用自己的类型，由 App 和键盘在两边转换。
- 修改 `project.yml` 后运行 `xcodegen generate`。

## 4. 核心模块 `Type4MeCorrectionCore`

### 4.1 输入

```swift
public struct CorrectionInput: Equatable, Sendable {
    public var before: String          // 选中内容之前的文字，最多 300 字；不发上下文时为空
    public var selected: String        // 选中内容，1…50 字
    public var after: String           // 选中内容之后的文字，最多 100 字；不发上下文时为空
    public var spoken: String          // 纠正那句话的识别结果
    public var attempts: [String]      // 本轮纠正里已被否定的写法，最早的在前
}
```

`attempts` 由键盘维护：在"已纠正"状态下再次纠正时，把最初的原词和之前每次替换的结果都放进来，表示"这些都不对"。

### 4.2 其他位置

`CorrectionOccurrences.find(before:after:matching:)` 返回按文中顺序编号的位置列表：

- **匹配方式：** 区分大小写的完全匹配，按 `Character` 计数。
- **字母数字边界：** 选中内容以字母或数字开头或结尾时，相邻字符也是字母或数字的位置不算匹配，避免 "AA" 匹配进 "AAA"。中文不做边界限制。
- **数量上限：** 最多 10 处，超出的不处理。
- `before` 和 `after` 为空时返回空列表。

### 4.3 提示词

提示词使用带编号标记的原文，选中的那一处标为 `⟦*⟧`，其他位置标为 `⟦1⟧`、`⟦2⟧` 等：

```text
我们下周跟 ⟦1⟧AA⟦/1⟧ 的人还有 ⟦*⟧AA⟦/*⟧ 开会，AA 制
```

没有前后文时，原文只有 `⟦*⟧AA⟦/*⟧`。

system 提示词要点（中英两版，按 App 语言选择，内容等价）：

1. 语音输入中被选中的 `⟦*⟧` 部分识别错了，用户刚才口头说明了正确内容。
2. 用户的话也经过语音识别，可能同样有误；如果它和被选中的内容一样或读音相近，说明这是同音或近音错误，应该根据上下文推断正确写法，而不是原样返回。
3. 用户的话可能是直接说出正确内容，也可能带有解释（"叹气那个欸""姓张，弓长张""英文缩写"），要提取出最终应写入的文字，不要把解释写进去。
4. `attempts` 里列出的写法都已被用户否定，不能再给。
5. 对每个编号位置判断是否是同一个错误，只有确定是同一个错误时才列入。
6. 只输出 JSON，不输出其他文字。

返回格式：

```json
{"replacement": "欸欸", "also": [1]}
```

无法判断时：

```json
{"replacement": null, "reason": "unclear"}
```

### 4.4 解析与校验

`CorrectionResponse.resolve(raw:input:occurrenceCount:)` 返回 `.replace(text, also: [Int])` 或 `.unclear`：

1. 容忍代码块围栏和前后空白，取第一个 JSON 对象。解析失败按 `.unclear` 处理。
2. `replacement` 为空、为 null、去掉首尾空白后与 `selected` 完全相同、或出现在 `attempts` 里时，结果为 `.unclear`。
3. 长度不超过 `max(selected.count * 3, selected.count + 20)`，超出说明模型在改写整句，结果为 `.unclear`。
4. 选中内容不含换行时，`replacement` 也不能含换行。
5. `also` 只保留 `1...occurrenceCount` 内的编号，去重后升序。

### 4.5 替换计划

`CorrectionEditPlan` 生成三种计划。偏移都按 `Character` 计数。每个步骤都带上执行前和执行后应看到的前文后缀，键盘据此核对。

**选中处：**

1. 前置条件：目标指纹一致（见 7.3）。
2. 执行 `insertText(replacement)`，覆盖选中内容。
3. 后置条件：前文以 `前文锚点 + replacement` 结尾。
4. 撤销步骤：删除 `replacement.count` 个字符，再插入原文 `selected`；前后都核对前文后缀。

**再次纠正：**

1. 前置条件：没有选中内容，前文以 `前文锚点 + 上次的替换结果` 结尾，后文以 `后文锚点` 开头。
2. 删除上次替换结果的长度，再插入新结果。
3. 后置条件：前文以 `前文锚点 + 新结果` 结尾。
4. 撤销步骤与选中处相同，恢复为上次的替换结果。

**一起改：**

1. 位置顺序：从后往前。先处理选中处之后的位置，从最远的开始；再处理之前的位置，从最近的开始。这样每次修改都不会影响还没处理的位置的偏移。
2. 每一处是一个小事务，包含以下步骤：
   1. 移动光标到这一处的末尾，核对前文以 `该处的前文锚点 + 原词` 结尾；
   2. 删除原词长度，紧接着插入新词，两次调用之间不等待；
   3. 核对前文以 `该处的前文锚点 + 新词` 结尾。
3. 最后一步把光标移回选中处新词的后面。
4. 撤销计划是每一处小事务的反向操作，按相反顺序执行。

## 5. 通信扩展

新增 `iOS/Shared/CorrectionMessages.swift`，只用基础类型。App 和键盘总是一起安装、一起更新，新字段都是可选的。

```swift
struct CorrectionRequest: Codable, Equatable, Sendable {
    var before: String          // 关闭"读取上下文"或敏感时为空
    var selected: String
    var after: String
    var attempts: [String]
}

struct CorrectionOutcome: Codable, Equatable, Sendable {
    var replacement: String
    var also: [Int]             // 其他位置的编号，由键盘按自己保存的位置表查找
    var usedRawSpeech: Bool     // 没有模型时直接用了识别原文
}
```

`DictationIPC.swift` 的扩展：

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
```

**纠正请求的发送时机：** 在 `start` 时发送，`stop` 不再重新读取。键盘以 `start` 时的快照作为目标，并在执行前核对目标是否还在原位（见 7.3）。

## 6. 主 App：`VoiceSession` 与 `CorrectionRunner`

### 6.1 分流

- **`startDictation`：**
  - 把 `command.purpose` 和 `command.correction` 记到 `Run` 上。
  - 收到纠正请求后，先用 `IntelliSenseSensitiveTextScanner` 扫描 `selected`。命中时立即失败，提示"选中的内容看起来是敏感信息，不会发送"，不打开麦克风。这是键盘检查之外的第二道防线。
  - 其余录音和识别流程完全复用。识别服务只收到声音和用户自己的热词，选中内容不会作为识别提示发送。
- **`complete`：** `run.purpose == .correction` 时交给 `CorrectionRunner`，跳过片段替换和模式处理。识别结果为空时，按现有流程返回"没有听到内容"。

### 6.2 `CorrectionRunner.run(spoken:request:) async -> Result`

1. **敏感检查：**
   - 再次扫描 `selected`，命中时直接失败，不外发。
   - 扫描 `before + selected + after`，命中时清空 `before` 和 `after`。
2. **上下文开关：** `SharedSettings.intelliSenseContext` 关闭时，键盘本来就不会读取前后文；主 App 这里再清空一次，作为保险。
3. **没有配置模型：** 返回 `CorrectionOutcome(replacement: spoken, also: [], usedRawSpeech: true)`。如果 `spoken` 与 `selected` 相同，返回"没听清"的失败。
4. **有模型：** 用 `CorrectionPrompt` 构造提示词，调用 `ChatClient.complete`，再用 `CorrectionResponse.resolve` 处理返回。结果为 `.unclear` 时返回失败，错误文案是"没听清要改成什么，再说一次"。
5. **超时：** 与模式处理共用现有的 30 秒处理超时。
6. **诊断记录：** 只记录耗时、结果类型（替换、没听清、敏感拦截、无模型）、`also` 的数量、是否带了前后文，不记录任何文字。

### 6.3 回传

- **成功：** 写 `state.phase = .done`、`state.correction = outcome`，`finalText` 留空。不写历史记录，见产品设计第 10 节。
- **失败：** 与听写失败相同，写 `.failed` 和 `errorMessage`。

### 6.4 记住热词

- 收到 `.rememberHotword` 时，调用 `VocabularyStore.shared.addHotword`，然后写 `state.rememberedHotword` 回执。
- 词已存在时也写回执，键盘把按钮显示为"已记住"。
- 键盘发出指令后 1.2 秒内没有收到回执（与现有 start 的看门狗时长相同），说明主 App 不在后台。这时键盘把词追加到 `PendingVocabulary`，即 App Group 里的 `pending-hotwords.json`。
- 主 App 在 `AppModel.init` 和 `didBecomeActive` 时合并待加热词，然后清空队列。
- 诊断记录只写"已加入 1 个热词"，不写词本身。

### 6.5 授权

- `AIConsent.recipients` 里文本模型的授权键改为 `llm:<provider>:correction`，已同意过的用户会重新确认一次。识别服务的键和说明不变，因为它收到的内容没有变化。
- 文本模型的说明文字补上："选中纠正时，接收选中的文字、你说的话，以及开启「读取上下文」时选中内容附近的文字"。英文同步。
- `docs/legal/ios-privacy.md` 中英文两段同步更新。
- "读取上下文"开关的说明改为同时覆盖智能感知和选中纠正。

## 7. 键盘

### 7.1 选中检测

- `KeyboardViewController` 重写 `selectionDidChange(_:)` 和现有的 `textDidChange(_:)`，两者都调用 `model.refreshSelection()`。`appeared()` 里也调用一次，处理用户先选中、再切换到 Type4Me 键盘的情况。
- `refreshSelection` 读取 `proxy.selectedText`，按顺序判断：
  1. `phase` 不是 `idle` 时：只更新目标指纹的有效性（见 7.3），不改变状态。
  2. 没有选中内容：如果当前是纠正待命，就退出纠正。
  3. 输入框敏感（复用 `fieldContext` 的规则：敏感内容类型和数字键盘）：进入"不可纠正"，原因是敏感输入框。
  4. 选中内容去掉首尾空白后超过 50 字：进入"不可纠正"，原因是太长。
  5. `IntelliSenseSensitiveTextScanner` 命中选中内容：进入"不可纠正"，原因是敏感。
  6. 其他情况：进入纠正待命，记下目标。
- **"不可纠正"状态：** 麦克风不可用，按下时只显示原因提示，不发送任何指令。普通听写不会在有选中内容时启动。

### 7.2 状态

```swift
enum CorrectionStage: Equatable {
    case none
    case blocked(Reason)              // 有选中但不能纠正：太长、敏感输入框、敏感内容
    case armed(Target)                // 有选中内容，等待按住
    case corrected(Target, Applied)   // 刚替换完，光标停在新词后面
}

struct Target {
    var request: CorrectionRequest
    var occurrences: [Occurrence]     // 其他位置：相对选中处的偏移与各自的前文锚点
    var fingerprint: Fingerprint
    var valid = true                  // 录音和处理期间选区变化时置为 false
}

struct Fingerprint {
    var documentID: UUID?
    var beforeAnchor: String          // 选中内容前 24 个字
    var selected: String
    var afterAnchor: String           // 选中内容后 24 个字
}

struct Applied {
    var original: String              // 最初被选中的原词
    var replacement: String
    var pendingAlso: [Occurrence]     // 等用户点"一起改"的位置
}
```

**与现有状态的关系：**

- `phase` 仍然管录音和处理，`correctionStage` 独立存放。
- `micPressed` 在 `armed` 或 `corrected` 时发出 `purpose: .correction` 的 `start`，在 `blocked` 时只显示提示。

**退出纠正：** 以下情况调用 `exitCorrection()`：

- 点 ×；
- 选中内容消失，且当前不是 `corrected` 状态；
- 在 `corrected` 状态下，前文不再以 `beforeAnchor + replacement` 结尾，说明光标离开了；
- 键盘消失或 `documentIdentifier` 变化。

### 7.3 目标指纹

- **记录：** 进入纠正待命时，从 `documentContextBeforeInput` 和 `documentContextAfterInput` 取前后各 24 个字作为锚点，与 `documentIdentifier`、选中内容一起组成指纹。这是 `start` 时的快照。
- **录音和处理期间：** `refreshSelection` 每次被调用都核对当前的选中内容和锚点。任何一项不一致，就把 `target.valid` 置为 false，之后不再恢复为 true。
- **执行替换前：** 再完整核对一次指纹。`valid == false` 或核对不一致时：
  - 不修改宿主的文字；
  - 把替换结果复制到剪贴板；
  - 提示"选中的位置变了，结果已复制"。

  这与现有 `deliver` 处理输入框变化的方式一致。

### 7.4 执行替换

**选中处与再次纠正：** 按 4.5 的计划执行一步，然后等待前文变成预期内容（最多 300 毫秒）。现有撤销代码已经注意到，前文在修改生效之后才更新。

- 后置核对通过：进入 `corrected`，触发成功的触感反馈，显示结果条。
- 后置核对不通过：说明宿主没有按预期处理这次修改。这时尝试执行这一步的撤销步骤，并提示"没能改好，已恢复"；撤销步骤也核对失败时，提示"没能改好，请检查这段文字"，同时把原词复制到剪贴板。

**一起改：** 用户点"还有 N 处，一起改"后，按 4.5 的计划逐处执行。

- 每处执行前，核对光标位置和前文锚点。不符就停下：把光标移回选中处新词后面，提示"其他几处没能一起改"。
- 每处执行后核对，不符时执行这一处的撤销步骤，然后停下。
- 只有前后都核对通过的位置，才计入"已改 N 处"和撤销记录。
- 唯一无法保证恢复的情况是：删除已经生效、插入却被宿主丢弃。这种情况下，撤销步骤会把原词插回去，原词也会复制到剪贴板作为保底。

### 7.5 撤销与重做

- 现有的 `lastInsertion` / `Redo` 只适合"在光标前插入一段文字"这一种操作。改为在 `KeyboardModel` 里维护一个 `UndoEntry`，它有三种情况：
  - 现有的插入；
  - 一次纠正（选中处或再次纠正）；
  - 一次"一起改"。
- **撤销纠正：** 执行对应的撤销计划，每一步都核对。核对不符时停下，提示"光标位置变了，没法撤销"。
- **重做：** 重新执行原计划。

### 7.6 界面

- `KeyboardRootView` 顶栏中部按 `correctionStage` 显示：
  - 模式拨盘；
  - 纠正标签：文字加 ×，强调色胶囊；
  - 原因提示：`blocked` 时显示；
  - 结果条：成功色胶囊，后面跟"记住"按钮；有待改的其他位置时，再加"还有 N 处，一起改"。
- 拨盘在纠正状态下淡出，沿用 `modeBarOpen` 时的淡出方式。
- 麦克风图标和说明文字按状态替换，录音和处理时沿用现有的隐藏规则。
- 标签里的选中内容超过 8 个字时，只显示前 8 个字加省略号。
- 所有文案在 `L(_, _)` 里同时给中英文，见产品设计第 11 节。
- 无障碍：
  - 纠正标签读作"纠正 AA，按钮，退出纠正"；
  - 麦克风读作"按住说出正确内容"；
  - `blocked` 时麦克风读作原因提示。

## 8. 隐私汇总

| 数据 | 去向 | 条件 |
|---|---|---|
| 纠正录音 | 识别服务 | 与普通听写相同 |
| 选中的文字 | 文本模型 | 不在敏感输入框、键盘和主 App 两端扫描都未命中 |
| 前后文 | 文本模型 | "读取上下文"开启，且前后文扫描未命中 |
| 纠正的话、已否定的写法 | 文本模型 | 每次纠正 |
| 任何文字 | 诊断记录 | 不记录 |

## 9. 测试

### 9.1 自动测试（`Tests/Type4MeTests/CorrectionCoreTests.swift`）

| 用例 | 覆盖 |
|---|---|
| 其他位置查找 | 中文、英文边界（AA 不匹配 AAA）、上限 10 处、选中内容在开头或结尾、没有前后文 |
| 提示词 | 标记位置正确；没有前后文时只有选中标记；`attempts` 写入；中英两版结构一致 |
| 返回解析 | 围栏代码块、多余文字、非法 JSON、null、与选中相同、命中 attempts、过长、含换行、非法编号 |
| 替换计划 | 选中处、再次纠正、一起改三种计划；前后都有其他位置；偏移按 Character 计算（含 emoji 和中英混排）；每种计划执行后再执行撤销，能还原原文 |

主 App 和键盘里与宿主交互的部分无法在 Mac 上自动测试，由真机清单覆盖。

### 9.2 真机清单（写进 `iOS/README.md` 的验证清单）

1. 在备忘录、信息、微信、邮件、Safari 的 `textarea` 和 `contenteditable` 里分别试：单处替换、一起改、两步撤销、再次纠正。
2. 录音和处理期间改选另一处同样的文字，结果复制到剪贴板，原文不变。
3. 选中一段 API Key 或银行卡号：不进入纠正，诊断记录里看不到任何请求。
4. 选中超过 50 字：麦克风不可用，原文不被覆盖。
5. 关闭"读取上下文"：纠正可用，但没有"一起改"。
6. 已同意授权的用户升级后，首次使用会看到新的授权说明。
7. 主 App 不在后台时点"记住"，打开 App 后热词出现在列表里。
8. 记录 `selectedText` 返回 nil，或 `adjustTextPosition` 行为异常的 App。
9. 在中英文界面下分别截图检查。

## 10. 风险

| 风险 | 影响 | 对策 |
|---|---|---|
| 部分 App 的 `selectedText` 返回 nil | 进不了纠正状态，键盘按普通听写处理 | 真机清单记录；必要时增加键盘内输出卡片点选 |
| `adjustTextPosition` 在 emoji 或组合字符处计数不一致 | 一起改时偏到错误位置 | 每处执行前核对锚点，不符即停；一起改需要用户点按钮 |
| 前文更新有延迟 | 核对误判 | 每步等待前文变成预期内容，最多 300 毫秒 |
| 删除生效但插入被宿主丢弃 | 原词丢失 | 撤销步骤插回原词，原词同时放进剪贴板 |
| 模型把解释性的话写进替换结果 | 替换成整句话 | 提示词约束，加上长度和换行校验 |
| 纠正的话被识别成别的错误写法 | 改错 | 用户可以继续纠正，`attempts` 逐步排除；撤销一步回到原样 |

## 11. 范围外的已知问题

现有听写在有选中内容时，`insertText` 会覆盖选中内容，而 `undoLastInsertion` 只删除新插入的文字，恢复不了被覆盖的原文。本功能上线后，有选中内容时不会再走普通听写，这个问题在键盘上不再出现。但在本功能实现之前它仍然存在，需要单独修复。

## 12. 实现步骤

1. **核心模块：** 新建 `Type4MeCorrectionCore` 与单元测试，覆盖其他位置查找、提示词、返回解析、三种替换计划。
2. **通信与主 App：**
   - 新增 `CorrectionMessages`，扩展 `DictationIPC`；
   - 在 `VoiceSession` 中增加纠正分支、`CorrectionRunner` 和记住热词指令；
   - 新增 `PendingVocabulary`；
   - 授权键升级，更新授权说明和隐私政策。
3. **键盘状态：**
   - 选中检测、`blocked` 状态、目标指纹；
   - 选中处替换、再次纠正、撤销；
   - 纠正标签、结果条和说明文字。
4. **一起改：** 逐处事务执行、失败停止与恢复、撤销与重做。
5. **补充与验证：** 更新"读取上下文"的设置说明，更新 `iOS/README.md` 的真机清单，在中英文界面下检查。
