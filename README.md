<p align="center">
  <a href="#中文">中文</a> | <a href="#english">English</a>
</p>

---

# 中文

> update：官方[词库管理Skill](https://github.com/joewongjc/type4me-vocab-skill)，帮你大幅提高识别准确率

<p align="center">
  <img src="docs/images/header-combined.svg" width="100%" alt="Type4Me - macOS 语音输入法" />
</p>


- **语音识别**：内置本地识别引擎、媲美云端引擎准确率；支持 14 家云端语音识别服务商，覆盖实时与批量识别，支持边说边出字、说完快速完成；
- **8 种默认模式**：内置快速模式、智能感知、翻译、随便问、Mac 操作、语音润色、Prompt 优化与代办模式，可自定义添加任意处理模版；
- **Intelli Sense**：根据当前 App、输入控件和有限上下文安全润色文字；还可按需学习稳定的纠错、表达和列表结构偏好；
- **Ask Anything**：围绕选中文本直接提问，并把连续追问保存为会话，随时搜索、恢复或继续追问；
- **统一翻译**：自动识别输入语言，支持 18 种目标语言翻译与输出校验重试；
- **Mac 操作**：用语音直接执行常用 macOS 系统操作与 Type4Me 功能控制；
- **语音改口**：刚打出的文字有误或想换个说法？按下快捷键直接语音说出修改指令，精准替换、局部微调、支持一键撤销；
- **多快捷键**：每个模式可绑定多个全局快捷键，支持按住说话与点按开关；
- **菜单栏控制中心**：直接查看运行状态，切换模式、麦克风、ASR 与翻译目标，并快速控制录音、历史、改口、权限和更新；
- **Liquid Glass 录音与外观控制**：常规录音条支持深色与浅色原生毛玻璃主题、多种液态玻璃视觉或静态节能样式；外观页面可实时预览，并可按需显示操作提示和取消按钮；
- **紧凑实时文本**：紧凑型录音指示条可在固定宽度内显示实时识别文本，处理完成后自动恢复为更小的占屏高度；
- **首页使用概览与模式管理**：在首页集中查看输入时长、字数、效率和活跃热力图，并直接管理各模式的快捷键与排序；
- **模型接入**：支持主流厂商API接入；文本处理支持使用Ollama接本地模型；
- **词汇管理**：支持热词、映射词，2种模式。热词用于校正语音识别引擎，映射词可作为兜底或个性化场景使用（如 Web coding -> Vibe Coding, "我的邮箱地址" -> xxx@gmail.com）；
- **历史记录**：存储所有历史识别记录，包括原始文本、处理后文本与实际识别模型；支持标记识别质量、查看统计并导出 CSV；
- **配套Skill**：真正做到100%准确率，打造只属于你的输入法，[点这里安装Skill](https://github.com/joewongjc/type4me-vocab-skill)后跟你的agent说"Qwen3.5 不要识别成 Queen 3.5"，他就能自动帮你管理热词和映射词，同类错误不再犯
- **URL Scheme**：支持从 Stream Deck、快捷指令、Raycast / Alfred、终端、浏览器或脚本直接控制录音（开始、结束、切换）；后台调用不抢前台焦点，注入目标无法确认时安全保留文本到剪贴板；同样可打开设置、管理词库、静默写入热词与片段替换规则；

## 立即体验

**方式一：直接下载DMG（推荐）**

两个版本，共享配置文件，可随时替换安装：

| 版本                                                         | 说明                                                         | 安装包大小   |
| ------------------------------------------------------------ | ------------------------------------------------------------ | ------ |
| ✨推荐：**[云端版本（点击下载）](https://github.com/joewongjc/type4me/releases/download/v2.4.0/Type4Me-v2.4.0-cloud.dmg)** | 支持云端识别 (Intel + Apple Silicon)，需配置语音、大模型API Key。语音识别推荐火山-豆包语音/Soniox、体验最好。火山注册有送额度，单价都十分便宜。[配置指引](https://my.feishu.cn/wiki/QdEnwBMfUi0mN4k3ucMcNYhUnXr) | ~10MB  |
| **[本地版本（点击下载）](https://github.com/joewongjc/type4me/releases/download/v2.4.0/Type4Me-v2.4.0-local-apple-silicon.dmg)** | 内嵌 SenseVoice + Qwen3-ASR 本地识别引擎 (Apple Silicon only，约占用8GB内存，建议32GB以上)，大模型依旧需要配置 API Key 或 Ollama 本地服务。 | ~700MB |

系统要求：macOS 14+ (Sonoma)


## 界面预览

<p align="center">
  <img src="docs/images/screenshot-1.webp" width="400" />
  <img src="docs/images/screenshot-2.webp" width="400" />
</p>
<p align="center">
  <img src="docs/images/screenshot-3.webp" width="400" />
  <img src="docs/images/screenshot-4.webp" width="400" />
</p>


[查看演示视频](#演示视频)


## 为什么做Type4Me

市面上语音输入法，至少命中以下问题之一：贵（$30/月）、封闭（不可导出记录）、扩展性差（不能自定义Prompt）、慢（强制优化及网络延迟）  

作为某最贵识别工具曾经的粉丝，心路历程就是：**「它怎么可以这么好用，但又这么难用」**
以及也不必所有的话都说的这么工工整整规规矩矩。
## 使用Tips

- 语音识别：
  - 推荐使用云端模型，成本极低（我高强度用说了5w字=5小时，对应5块人民币，豆包语音注册送40小时，[配置指引](https://my.feishu.cn/wiki/QdEnwBMfUi0mN4k3ucMcNYhUnXr)）
  - 尽管本地模型效果还不错，但十分占用内存，内嵌Sense Voice用于流式识别（2GB内存占用）、Qwen3 ASR做校准（8GB内存占用），你也可以单独开其中一个，但体验不佳，Sense Voice中文不错、但英文单词十分拉垮。
- 文本处理（接入LLM）：
  - 依旧推荐使用云端模型，接入Coding Plan API，这类轻量文本处理Token消耗肉眼不可见；
  - LLM本地跑的内存占用比语音识别还高，而且效果相比云端模型相去甚远；
  - **不要**使用思考模式，推荐轻量模型。作者自己用的是Seed-2.0-lite。例如Minimax M2.7无法关闭思考，处理时间会非常长。对于我们这种轻量文本处理完全没有必要，牺牲体验也换不到效果。
    - 如果你发现你的处理时间很长，请把你使用的厂商和模型告诉我，我看看代码里是否成功关闭思考（目前没有遍历测试所有API）
- **强烈建议**搭配[配套Skill](https://github.com/joewongjc/type4me-vocab-skill)使用：市面上所有的语音输入法，专有名词均无法做到很好的识别（例如：Qwen 3.5），搭配Skill使用1-2天，你将彻底迈入100%识别准确率



## 详细功能介绍

### 不只是语音转文字：8 种默认输入模式

Type4Me 不只是把语音识别成文字。

同一段语音，可以直接转写、智能整理、翻译、提问，也可以让 AI 帮你生成成品，甚至直接操作 Mac。

当前版本新安装默认提供 8 种模式：

| 模式            | 适合做什么                | 默认快捷键                         |
| ------------- | -------------------- | ----------------------------- |
| **快速模式**      | 最快的纯语音输入，不经过 LLM 后处理 | `Fn`                          |
| **智能感知**      | 日常主力输入，根据场景智能整理表达    | `Fn + Control` / `Option + 1` |
| **翻译模式**      | 边说边翻译成指定语言           | `Fn + Shift` / `Option + 2`   |
| **随便问**       | 对选中文字提问，或直接用语音问 AI   | `Fn + Space` / `Option + 3`   |
| **Mac 操作**    | 用语音执行常用 macOS 操作     | `Option + 4`                  |
| **语音润色**      | 把自然口语稳定整理成清晰书面文字     | `Option + 5`                  |
| **Prompt 优化** | 把一句模糊需求扩展成高质量 Prompt | 默认未绑定                         |
| **代办模式**      | 直接让 AI 根据口述需求交付成品    | 默认未绑定                         |

所有快捷键均可自行修改。一个模式可以绑定**多个全局快捷键**，并且每个快捷键都可以独立设置为：

- **按住说话**：按住录音，松开结束
- **开关模式**：按一下开始，再按一下结束

<p align="center">
  <img src="docs/screenshots/screenshot-modes.png" width="480" alt="模式快捷键设置" />
</p>

<!-- SCREENSHOT TODO: 多快捷键绑定配置截图（若需进一步展示多个 hold/toggle 快捷键细节） -->

---

### ⚡ 快速模式：只管说，最快出字

这是最接近传统输入法的模式。

语音识别完成后直接输入到当前光标位置，**不经过 LLM 文本处理**，因此延迟最低，也不会擅自修改你的表达。

适合：

- 搜索关键词
- 聊天、短句输入
- 输入网址、代码术语、专有名词
- 已经想好怎么说，只希望快速打出来
- 不希望 AI 改写原话的场景

例如你说：

> 明天下午三点开会记得把用户增长的数据也带上

快速模式就直接输入识别结果，不负责重新组织你的表达。

**一句话理解：传统语音输入法的增强版。**

---

### ✨ 智能感知：日常主力模式

如果说快速模式负责“听清你说了什么”，那么智能感知负责的是：

**听懂你想怎么表达。**

它首先会像语音润色一样处理口语中的停顿、重复、改口、错别字和断句；开启相应的感知能力后，还可以进一步参考：

- 当前正在使用的 App
- 当前输入位置附近的上下文
- 你的长期表达习惯
- 你输入后经常手动修改的内容

同一句话，在聊天框、邮件、文档里，可以采用不同程度的整理方式。

例如你口述：

> 嗯那个我觉得这个方案吧整体上没啥大问题但是上线时间可能还是得往后推一下因为测试这边还没跑完

智能感知可能整理成：

> 我觉得这个方案整体没什么问题，但上线时间可能还是要往后推一下，因为测试还没有跑完。

它的目标不是“把所有话都改得像公文”，而是在**尽量保留你本人说话方式的前提下，让文字更像你认真打出来的内容**。

适合：

- 微信、Slack、飞书等日常聊天
- 写邮件
- 写文档
- 写需求和 Issue
- 日常几乎所有长句输入

<p align="center">
  <img src="docs/screenshots/screenshot-intelli-sense-history.png" width="480" alt="Intelli Sense 偏好与历史" />
</p>

**一句话理解：如果你不知道该用哪个模式，优先用智能感知。**

> 智能感知中的应用感知、上下文感知、表达习惯学习等能力可以单独开启或关闭，默认不会静默学习。

---

### 🌍 翻译模式：直接说，直接得到目标语言

翻译模式不是简单地把识别结果逐字翻译，而是先理解你真正想表达的意思，再生成自然的目标语言。

例如你说：

> 我这周五临时有点事情，要不我们下周再约吧

目标语言设为英语，可以直接得到：

> Something came up this Friday. How about we reschedule for next week?

它会自动处理：

- 口语中的停顿和重复
- “不是周五，周六”之类的中途改口
- 明显的语音识别错误
- 不同语言的自然表达习惯

支持自动识别口述语言，并可选择 **18 种目标语言**，包括英语、简体中文、繁体中文、日语、韩语、西班牙语、法语、德语等。在输出语言不符时会自动进行校验与重试。

新安装默认目标语言为**英语**。

<!-- SCREENSHOT TODO: 翻译目标语言选择器截图；在正式构建上截取并隐藏敏感信息 -->

适合：

- 中文直接说成英文
- 英文直接说成中文
- 写英文邮件和消息
- 与海外同事沟通
- 小语种输入

**一句话理解：把“先语音输入，再复制去翻译”变成一个快捷键。**

---

### 💬 随便问：看到什么，直接问什么

“随便问”不是输入模式，而更像一个随时可以通过语音唤出的 AI 问答窗口。

你可以先选中屏幕上的一段文字，然后按快捷键直接提问：

> 这段代码有什么问题？

> 帮我总结一下

> 这句话是什么意思？

> 翻译成中文

> 他的核心观点是什么？

Type4Me 会把**选中的文字 + 你的语音问题**一起交给模型，并在独立窗口中返回答案。

没有选中文字也没关系，可以直接问：

> Python 的 list 和 tuple 有什么区别？

> 帮我想三个产品名字

> 这个报错一般是什么原因？

它还支持连续追问，会保留当前问答的上下文；所有会话都会保存到历史记录中，支持在设置中搜索、恢复、重命名或删除。

<p align="center">
  <img src="docs/screenshots/screenshot-askit.png" width="480" alt="Ask Anything 会话历史" />
</p>

这意味着你在浏览网页、看文档、读代码、看邮件时，不需要复制内容、打开 ChatGPT、粘贴、再打字提问。

**选中 → 按快捷键 → 直接说。**

**一句话理解：系统级的“选中内容问 AI”。**

---

### 🖥️ Mac 操作：用语音控制电脑

Mac 操作模式不会把你的语音变成文字，而是尝试把它理解成一个 macOS 操作并直接执行。

例如：

> 打开 Safari

> 音量调到 30

> 切换深色模式

> 截个图

> 搜一下 SwiftUI 教程

> 锁屏

> 最小化窗口

> 关闭这个窗口

> 提醒我两分钟后检查邮件

> 往下滚

甚至可以操作 Type4Me 自己：

> 打开热词

> 打开片段替换

> 把选中的词加到热词

只有匹配到 Type4Me 已支持的操作时才会执行；它不是一个可以任意控制电脑的通用 Agent。

**一句话理解：把一些原本要点几下鼠标的操作，变成一句话。**

---

### 📝 语音润色：稳定地把“说出来的话”变成“写出来的话”

语音润色是一个更明确、更可预测的文字整理模式。

它不会回答你说的问题，也不会替你继续创作，职责只有一个：

**把语音识别得到的自然口语整理成清晰、可读的文字。**

它会处理：

- “嗯、啊、那个、就是说”等无意义口头语
- 重复和废弃半句
- 中途改口
- 错别字和断句
- 中文口述数字
- 多个要点的结构化整理
- 正式内容和日常聊天不同的排版方式

例如你说：

> 我们这周主要三个事情哦不两个事情第一把新版上线第二把那个文档补完

可能整理为：

> 这周主要有两件事：
>
> 1. 上线新版。
> 2. 补完文档。

和“智能感知”相比，**语音润色更像一套固定的文字整理规则**；智能感知则可以进一步结合当前场景和你的表达习惯。

如果你希望输出风格稳定、可预测，或者正在写比较正式的内容，语音润色仍然非常好用。

**一句话理解：忠实于原意的“口语 → 成文”。**

---

### 🧠 Prompt 优化：一句话变成高质量 Prompt

有时候你知道自己想让 AI 做什么，但懒得写一大段 Prompt。

直接说：

> 帮我分析一下我们这个季度用户留存是不是有问题

Prompt 优化不会直接回答这个问题，而是把它扩展成一个真正适合交给 LLM 执行的 Prompt，例如补充：

- 专业角色
- 分析维度
- 执行步骤
- 需要交叉验证的内容
- 输出结构和格式

对于简单任务，它会保持简单；对于研究、分析、方案类任务，则会主动补足专业框架。

因此它尤其适合配合：

- ChatGPT
- Claude
- Codex
- Cursor
- Claude Code
- 各类 AI Agent

工作流可以变成：

**按快捷键 → 说一句需求 → Type4Me 生成完整 Prompt → 自动粘贴到当前 AI 对话框。**

**一句话理解：你负责说“我要什么”，它负责把需求写专业。**

---

### 🚀 代办模式：别帮我写 Prompt，直接把东西做出来

Prompt 优化负责“帮你写一份更好的任务说明”。

代办模式更进一步：

**不用给我 Prompt，直接给我结果。**

比如你说：

> 写封邮件跟供应商说我们付款流程出了点问题可能要晚三天麻烦他理解一下

它会直接生成可以发送的邮件。

你也可以说：

> 回复老板，下午三点的周会我能参加

> 写一个 Python 函数计算第 n 个斐波那契数

> 把我选中的这句话翻译成自然的英文

> 根据剪贴板里的内容帮我写个回复

代办模式可以结合：

- 你的语音需求
- 当前选中的文字
- 剪贴板内容

直接生成最终可用的内容，并输入到当前应用。

它和“随便问”的区别是：

|      | 随便问           | 代办模式      |
| ---- | ------------- | --------- |
| 核心用途 | 问问题、理解内容、连续讨论 | 直接生成最终成品  |
| 输出位置 | 独立问答窗口        | 当前输入位置    |
| 支持追问 | 是             | 否，以单次交付为主 |
| 典型场景 | “这段什么意思？”     | “帮我回复这段话” |

**一句话理解：Prompt 优化是“帮我把任务说清楚”，代办模式是“你直接帮我做掉”。**

---

### 应该用哪个模式？

懒得研究的话，记住这张表就够了：

| 我现在想……                         | 用这个           |
| ------------------------------ | ------------- |
| 原样快速输入                         | **快速模式**      |
| 日常聊天、邮件、文档输入                   | **智能感知**      |
| 把口语稳定整理成书面文字                   | **语音润色**      |
| 说一种语言、输出另一种语言                  | **翻译模式**      |
| 看着一段内容问 AI                     | **随便问**       |
| 用一句话控制 Mac                     | **Mac 操作**    |
| 给 ChatGPT / Claude 写一个好 Prompt | **Prompt 优化** |
| 不想写 Prompt，只想直接拿结果             | **代办模式**      |

---

### 还不够？自己创建模式

除了默认模式之外，你还可以自己添加任意文本处理模式。

例如：

- “把我的话改成更正式的商务语气”
- “自动翻译成日语”
- “整理成小红书文案”
- “转换成 GitHub Issue”
- “把口述需求整理成产品需求文档”
- “根据选中的代码生成 Commit Message”

自定义 Prompt 可以使用三个变量：

| 变量            | 内容           |
| ------------- | ------------ |
| `{text}`      | 本次语音识别得到的文字  |
| `{selected}`  | 开始录音时选中的文字   |
| `{clipboard}` | 开始录音时剪贴板中的内容 |

例如：

```text
下面是用户当前选中的内容：

{selected}

用户通过语音说出的修改要求：

{text}

请按照用户要求修改选中的内容，只输出修改后的结果。
```

这样 Type4Me 就不再只是一个“语音输入法”，而是可以把任意 LLM 文本工作流绑定到一个全局快捷键上。

#### 最终文本格式化

最终文本可按需应用中英文盘古空格和中文直角引号；英文撇号会被保留。

---

### 词汇管理与配套 Skill

- **ASR 热词**：添加专有名词（如 `Claude`、`Kubernetes`），提升识别准确率
- **片段替换**：语音说「我的邮箱」，自动替换为实际邮箱地址

配套 Skill 可通过 Type4Me 的词汇命令打开词汇管理并刷新词表，帮助把反复出现的专有名词错误固化为热词或片段替换规则。

<p align="center">
  <img src="docs/screenshots/screenshot-vocabulary.png" width="480" alt="词汇管理" />
</p>

---

### URL Scheme / 外部自动化

Type4Me 提供 URL Scheme，可以从浏览器、终端、macOS 快捷指令、Raycast、Alfred、脚本或 AI Agent 调用常用功能。

#### Scheme 名称

不同构建默认注册不同的 Scheme；**单个安装包只接受自己实际注册的 Scheme**：

| 构建 | 默认 Scheme | 示例 |
| --- | --- | --- |
| 正式版 / Public | `type4me://` | `type4me://settings` |
| Dev 开发版 | `type4me-dev://` | `type4me-dev://settings` |
| Personal / CtriXin | `type4me-ctrixin://` | `type4me-ctrixin://settings` |

下面示例统一使用正式版 `type4me://`。开发版或个人版只需要替换 Scheme 前缀。

#### 录音控制（Recording Commands）

为 Stream Deck、Raycast、Alfred、BetterTouchTool、Hammerspoon、macOS 快捷指令等自动化工具提供免模拟键盘事件的直接控制接口：

##### 开始录音
```text
type4me://start
```
- 使用 Type4Me 当前选中的模式（`AppState.currentMode`）开始录音；
- 幂等命令：若已经在准备中或录音中，不会重复触发或中断当前录音；
- 在处理中（processing）或恢复中（recovering）安全忽略，不会并发开启第二轮录音。

##### 结束录音
```text
type4me://stop
```
- 结束当前录音并正常进入后续语音识别、LLM 处理与文本注入流程；
- 仅在准备中（preparing）或录音中（recording）生效；空闲或处理中安全忽略；
- 不等价于取消（cancel），会完整保留已录音内容。

##### 录音开关（Toggle）
```text
type4me://toggle
```
- 空闲时开始录音，录音中结束录音；适合 Stream Deck 单键绑定；
- 在处理中或恢复中安全忽略。

> **最佳实践（推荐使用 `-g` 后台调用）**：
> - 在终端、脚本或第三方工具（Stream Deck、Raycast、Alfred、BetterTouchTool、Hammerspoon、快捷指令等）中触发时，推荐使用 **`open -g 'type4me://toggle'`**（`-g` / `--background` 选项）；
> - `-g` 会让系统直接在后台传递事件，**完全不激活 Type4Me 也不会抢占前台焦点**，彻底消除前台界面切换与光标抖动，实现 100% 丝滑无感的录音与文本注入体验。
>
> 说明：
> - 录音控制命令默认使用 Type4Me 当前选中的模式，第一版不接受 `?mode=` 等 query 参数（带有未知参数将被拒绝）；
> - 通过 URL 启动的录音是标准的 Type4Me 录音会话，可以随时通过浮动条、菜单栏或键盘快捷键正常结束或取消。

#### 打开设置

```text
type4me://settings
```

`preferences` 是等价别名：

```text
type4me://preferences
```

#### 热词（Hotwords）

打开热词管理：

```text
type4me://vocabulary/hotwords
```

预填一个热词并打开设置：

```text
type4me://vocabulary/hotwords?word=Ghostty
```

中文或特殊字符需要进行 URL 编码，例如：

```text
type4me://vocabulary/hotwords?word=%E9%98%B6%E8%B7%83%E6%98%9F%E8%BE%B0
```

静默添加热词，不打开 Settings：

```text
type4me://vocabulary/hotwords?word=Ghostty&silent=true
```

`silent=1` 同样有效。静默模式下 `word` 为必填参数；已存在的热词会按大小写不敏感方式去重。

#### 片段替换（Snippets）

打开片段替换：

```text
type4me://vocabulary/snippets
```

只预填 trigger：

```text
type4me://vocabulary/snippets?trigger=ghosty
```

同时预填 trigger 和 replacement：

```text
type4me://vocabulary/snippets?trigger=ghosty&replacement=Ghostty
```

静默添加片段替换：

```text
type4me://vocabulary/snippets?trigger=ghosty&replacement=Ghostty&silent=true
```

静默模式下 `trigger` 和 `replacement` 都是必填参数。若同名 trigger 已存在且 replacement 相同，则视为已存在；若 replacement 不同，则不会静默覆盖原规则。

#### 重新加载词表

```text
type4me://reload-vocabulary
```

该命令会刷新 Hotwords / Snippets 缓存、发送词汇变更通知，并触发本地热词同步与相关服务刷新。

#### 已废弃：`auth`

```text
type4me://auth
```

这个入口仅为历史兼容保留。认证流程已经改为 code-based auth，因此当前 `auth` 是 **no-op**，新集成不应再使用。

#### 参数限制

Vocabulary URL 会执行严格校验：

- URL 最大 **8 KB**；
- `word` 最大 **256 字符**；
- `trigger` 最大 **256 字符**；
- `replacement` 最大 **4096 字符**；
- 不接受空值或控制字符；
- 不接受未知 query 参数；
- 同名 query 参数不能重复；
- `silent` 只接受 `true` / `1` / `false` / `0`；
- Vocabulary 路径只支持 `/hotwords` 与 `/snippets`。

#### Terminal 示例

```bash
open 'type4me://settings'
open 'type4me://vocabulary/hotwords?word=Ghostty'
open 'type4me://vocabulary/snippets?trigger=ghosty&replacement=Ghostty&silent=true'
```

> 对带有空格、中文、`&`、`?` 等特殊字符的参数，请先进行 URL 编码。

---

### 语音改口（Revise）

对最近一次仍可可靠定位的 Type4Me 输入，按下改口快捷键（默认 `Fn + R`）并说出修改指令；Type4Me 只替换授权范围，目标已变化或无法定位时会安全失败。成功后可一键或语音撤销。

<!-- SCREENSHOT TODO: 真实 Revise 工作流截图（展示原文、改口状态与撤销效果）；目前暂时展示原型示意图 -->

<p align="center">
  <img src="docs/screenshots/prototype-revise.png" width="480" alt="Type4Me 语音改口（原型示意图）" />
</p>

- **智能槽位定位**：说「改成下午 2 点」、「不是 Jerry 是 Tom」，系统自动匹配修改目标并精准替换，其余内容保持不变；
- **安全保护与强防篡改**：严格保护未授权的数字、金额、日期等事实，避免大模型幻觉篡改原文事实；
- **一键撤销**：修改后浮条展示「撤销」胶囊按钮，或再次语音说「撤销」/「恢复上一版」，秒回原文字。


## 架构概览

| 模块 | 说明 |
|------|------|
| `Type4Me/ASR/` | ASR 引擎抽象层，可插拔 Provider 架构 |
| `Type4Me/Audio/` | 音频采集 (16kHz mono PCM) |
| `Type4Me/Session/` | 核心状态机：录音 → ASR → 注入 |
| `Type4Me/Services/` | 凭证存储、热词、模型管理、Python 服务管理 |
| `Type4Me/LLM/` | LLM 文本处理 (14 个 provider) |
| `Type4Me/Input/` | 全局快捷键管理 |
| `Type4Me/Injection/` | 文本注入 (剪贴板 Cmd+V) |
| `Type4Me/Bridge/` | SherpaOnnx C API Swift 桥接 (可选) |
| `Type4Me/UI/` | SwiftUI 界面：浮窗 + 设置 |
| `Type4MeIntelliSenseCore/` | Intelli Sense 上下文感知与偏好学习核心 |
| `Type4MeReviseCore/` | 语音改口追踪、槽位定位与替换核心 |
| `qwen3-asr-server/` | Python Qwen3-ASR 校准服务 (Apple Silicon, MLX) |

ASR Provider 架构设计为可插拔：实现 `ASRProviderConfig`（定义凭证字段）和 `SpeechRecognizer`（实现识别逻辑），注册到 `ASRProviderRegistry` 即可添加新引擎。


## 参与贡献

欢迎提交 PR/Issue，这个项目是我全部自己用 Claude Code 写的。

开发与设计文档统一从 [`docs/README.md`](docs/README.md) 进入；历史方案已单独归档，避免误用旧文档。

对于 PR，即便有 bug/代码质量不好，我最常跟 Claude 说的一句话就是不要漏了人家的贡献。你大不了合完再改。


## 致谢

- [SenseVoice](https://github.com/FunAudioLLM/SenseVoice) - Alibaba FunAudioLLM
- [streaming-sensevoice](https://github.com/pengzhendong/streaming-sensevoice) - @pengzhendong
- [asr-decoder](https://github.com/pengzhendong/asr-decoder) - @pengzhendong
- [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) - k2-fsa
- [Qwen3-ASR](https://github.com/QwenLM/Qwen3-ASR) - Alibaba Qwen
- [mlx-qwen3-asr](https://github.com/moona3k/mlx-qwen3-asr) - @moona3k


## 演示视频

<video src="https://github.com/user-attachments/assets/d5ad6da9-b924-4fd6-9812-d0d9868563a4" width="600" title="demo" controls>demo</video>


## 许可证

[MIT License](LICENSE)

---

# English

> Update: Official [Vocabulary Management Skill](https://github.com/joewongjc/type4me-vocab-skill) to dramatically improve recognition accuracy

<p align="center">
  <img src="docs/images/header-combined-en.svg" width="100%" alt="Type4Me - macOS Voice Input" />
</p>


- **Speech Recognition**: Built-in local recognition engine with accuracy rivaling cloud engines; supports 14 cloud ASR providers across streaming and batch recognition, with instant text output while speaking and fast completion after recording;
- **8 Default Modes**: Built-in Quick Mode, Intelli Sense, Translation, Ask Anything, Mac Actions, Voice Polish, Prompt Optimization, and Task Delegation; fully customizable with user-defined templates;
- **Intelli Sense**: Safely polishes text using the current app, input control, and limited context; optionally learns stable corrections, expression preferences, and list structure;
- **Ask Anything**: Ask questions about selected text, save follow-ups into conversation history, and search, resume, or continue conversations anytime;
- **Unified Translation**: Automatically detects source language, translates into one of 18 selectable target languages, with output validation and retry;
- **Mac Actions**: Execute common macOS system actions and Type4Me controls directly by voice;
- **Voice Revise**: Made a typo or want to rephrase? Press a hotkey to speak revisions directly—precision replacement, local slot targeting, and one-click undo;
- **Multiple Hotkeys**: Bind multiple global shortcuts per mode with hold-to-talk or toggle behavior;
- **Menu Bar Control Center**: View runtime status, switch modes, microphones, ASR providers, and translation targets, and quickly control recording, history, revise, permissions, and updates;
- **Liquid Glass Recording & Appearance Controls**: Choose a dark or light native frosted-glass theme, a Liquid Glass visual, or a static power-saving style for the regular recording bar; preview it live in Appearance settings and choose whether to show operation hints and the cancel button;
- **Compact Live Transcript**: Show live recognition text in the fixed-width compact recording indicator, which returns to its smaller height once processing is complete;
- **Home Activity Overview & Mode Management**: See input time, word count, efficiency, and an activity heatmap, then manage each mode's hotkeys and order directly from Home;
- **Model Integration**: Supports mainstream provider APIs; text processing works with Ollama local models;
- **Vocabulary Management**: Two modes: hotwords and snippet replacements. Hotwords improve ASR accuracy for proper nouns; snippets enable personalized substitutions (e.g., "Web coding" -> "Vibe Coding", "my email" -> xxx@gmail.com);
- **History**: Stores raw and processed recognition records with the ASR model used; mark transcription quality, review aggregates, and export CSV;
- **Companion Skill**: Achieve 100% recognition accuracy. [Install the Skill](https://github.com/joewongjc/type4me-vocab-skill) and tell your agent "Don't recognize Qwen3.5 as Queen 3.5" to automatically manage hotwords and snippets. Same mistakes won't happen again.
- **URL Scheme**: Control recording directly (start, stop, toggle) from Stream Deck, Shortcuts, Raycast / Alfred, Terminal, or scripts without simulating keystrokes; background calls keep the foreground app intact and fall back safely to the clipboard when an injection target cannot be confirmed; open Settings, manage vocabulary, and silently write hotwords/snippets.

## Get Started

**Option 1: Download DMG (Recommended)**

Two editions, sharing the same config files. You can switch between them at any time:

| Edition | Description | Size |
| ------- | ----------- | ---- |
| ✨Recommended: **[Cloud Edition (Download)](https://github.com/joewongjc/type4me/releases/download/v2.4.0/Type4Me-v2.4.0-cloud.dmg)** | Cloud recognition (Intel + Apple Silicon). Requires ASR and LLM API keys. Recommended: Volcano/Doubao or Soniox for best experience. [Setup Guide](https://my.feishu.cn/wiki/QdEnwBMfUi0mN4k3ucMcNYhUnXr) | ~10MB |
| **[Local Edition (Download)](https://github.com/joewongjc/type4me/releases/download/v2.4.0/Type4Me-v2.4.0-local-apple-silicon.dmg)** | Bundled SenseVoice + Qwen3-ASR local recognition (Apple Silicon only, ~8GB RAM, 32GB+ recommended). LLM still requires API key or local Ollama. | ~700MB |

System requirements: macOS 14+ (Sonoma)

**DMG shows "damaged" or app won't open?**

> Solution:
>
> - Step 1: Open Terminal and run:
>
>   xattr -d com.apple.quarantine /Applications/Type4Me.app
>
>   ```bash
>   spctl --master-disable
>   ```
>
> - Step 2: Go to System Settings > Privacy & Security > "Allow applications from", select "Anywhere"
>
> - Step 3: Open the DMG and drag Type4Me to the Applications folder.
>
> - Step 4 (Optional): Revert "Allow applications from" back to its previous setting.

> Apple Developer certification is still pending. This is a normal macOS Gatekeeper prompt that can be resolved with the steps above.

**Option 2: Give this repo link to your AI agent and let it deploy for you**

## Screenshots

<p align="center">
  <img src="docs/images/screenshot-1.webp" width="400" />
  <img src="docs/images/screenshot-2.webp" width="400" />
</p>
<p align="center">
  <img src="docs/images/screenshot-3.webp" width="400" />
  <img src="docs/images/screenshot-4.webp" width="400" />
</p>


[Watch demo video](#demo-video)


## Why Type4Me

Every voice input tool on the market hits at least one of these: expensive ($30/month), walled garden (can't export history), inflexible (no custom prompts), slow (forced optimization + network latency).

As a former fan of the most expensive transcription tool out there, the journey was: **"How can it be this good and this frustrating at the same time?"**
And honestly, not everything you say needs to sound perfectly polished.

## Usage Tips

- Speech Recognition:
  - Cloud models recommended. Extremely affordable (50k characters = 5 hours of heavy use costs ~$0.70 USD. Volcano/Doubao gives 40 free hours on signup, [setup guide](https://my.feishu.cn/wiki/QdEnwBMfUi0mN4k3ucMcNYhUnXr))
  - Local models work well but are memory-intensive: SenseVoice for streaming (2GB RAM), Qwen3-ASR for calibration (8GB RAM). You can run just one, but the experience is compromised. SenseVoice handles Chinese well but struggles with English words.
- Text Processing (LLM):
  - Cloud models still recommended. Token cost for lightweight text processing is negligible;
  - Running LLM locally uses more memory than ASR and the quality gap vs. cloud models is significant;
  - **Do NOT** use reasoning/thinking mode. Use lightweight models. The author uses Seed-2.0-lite. Some models (e.g., Minimax M2.7) can't disable reasoning, resulting in very long processing times. For lightweight text processing, it's completely unnecessary.
    - If your processing time is long, tell me which provider and model you're using so I can check if reasoning is properly disabled in the code (not all APIs have been tested)
- **Strongly recommended**: Use with the [companion Skill](https://github.com/joewongjc/type4me-vocab-skill). No voice input tool handles proper nouns perfectly (e.g., "Qwen 3.5"). After 1-2 days with the Skill, you'll achieve 100% recognition accuracy.



## Feature Details

### More Than Speech-to-Text: 8 Default Input Modes

Type4Me is more than just transcribing speech to text.

From a single voice clip, you can transcribe directly, intelligently polish, translate, ask questions, have AI generate ready-to-use deliverables, or even execute macOS system actions.

New installations include 8 default modes out of the box:

| Mode | Best For | Default Shortcut |
| ---- | -------- | ---------------- |
| **Quick Mode** | Fastest raw speech input without LLM post-processing | `Fn` |
| **Intelli Sense** | Daily primary input, adapts expression based on context | `Fn + Control` / `Option + 1` |
| **Translation** | Real-time speech translation into target language | `Fn + Shift` / `Option + 2` |
| **Ask Anything** | Ask about selected text or ask AI voice queries | `Fn + Space` / `Option + 3` |
| **Mac Actions** | Execute common macOS actions by voice | `Option + 4` |
| **Voice Polish** | Reliably refine natural speech into clear written prose | `Option + 5` |
| **Prompt Optimization** | Turn vague ideas into high-quality LLM prompts | Unbound by default |
| **Task Delegation** | Let AI deliver finished work directly from spoken requests | Unbound by default |

All shortcuts are fully customizable. Each mode can bind **multiple global shortcuts**, and each shortcut can be independently set to:

- **Push-to-Talk (Hold)**: Press and hold to record, release to finish
- **Toggle Mode**: Press once to start, press again to finish

<p align="center">
  <img src="docs/screenshots/screenshot-modes.png" width="480" alt="Mode Shortcut Settings" />
</p>

<!-- SCREENSHOT TODO: Multiple hotkey bindings configuration screenshot (if needed to illustrate multiple hold/toggle shortcuts in detail). -->

---

### ⚡ Quick Mode: Just Speak, Fastest Text Output

This is the mode closest to traditional input methods.

Direct text injection into the current cursor position upon speech recognition completion, **bypassing LLM processing** for minimum latency without altering your wording.

Best for:

- Search keywords & queries
- Instant messaging & short chats
- Entering URLs, code terms, and proper nouns
- When you already know exact phrasing and just want fast typing
- Any scenario where AI rephrasing is unwanted

For example, when you say:

> Remember to bring the user growth data to tomorrow's 3 PM meeting

Quick Mode injects the transcribed text directly without reorganizing your phrasing.

**In a nutshell: A modern enhancement of traditional voice dictation.**

---

### ✨ Intelli Sense: Your Daily Workhorse

If Quick Mode is responsible for "hearing what you said", Intelli Sense is responsible for:

**Understanding how you want to express it.**

It first handles pauses, filler words, repetitions, mid-sentence corrections, typos, and sentence breaking just like Voice Polish. When awareness features are enabled, it further references:

- The active application
- Context around the current cursor position
- Your long-term expression preferences
- Corrections you frequently make manually after typing

The same sentence can be adapted with different levels of refinement across chat apps, emails, and technical documents.

For example, when you say:

> Um, so I think overall this proposal has no big issues, but the launch date might need to be pushed back a bit because testing hasn't finished running yet.

Intelli Sense refines it to:

> I think the proposal looks good overall, but we may need to push back the launch date as testing is still in progress.

Its goal is not to make everything sound like rigid formal prose, but to **keep your personal voice while making the text look like something you carefully typed yourself**.

Best for:

- Daily messaging in Slack, Teams, WeChat, Lark
- Drafting emails
- Writing documentation
- Authoring specs, PR descriptions, and GitHub issues
- Almost all everyday long-form voice typing

<p align="center">
  <img src="docs/screenshots/screenshot-intelli-sense-history.png" width="480" alt="Intelli Sense Preferences & History" />
</p>

**In a nutshell: If you're not sure which mode to use, default to Intelli Sense.**

> App awareness, context awareness, and habit learning in Intelli Sense can be toggled independently and are never silently enabled by default.

---

### 🌍 Translation: Speak in One Language, Output in Another

Translation mode does not simply translate word-by-word. It understands your underlying intent first, then generates natural, idiomatic phrasing in the target language.

For example, when you say (in Chinese):

> 我这周五临时有点事情，要不我们下周再约吧

With English set as the target language, you directly get:

> Something came up this Friday. How about we reschedule for next week?

It automatically handles:

- Oral pauses and filler repetitions
- Mid-sentence corrections (e.g. "not Friday, Saturday")
- Obvious ASR misrecognitions
- Natural colloquial idioms across different languages

Supports automatic source language detection and translating into **18 target languages**, including English, Simplified Chinese, Traditional Chinese, Japanese, Korean, Spanish, French, German, and more. If the output language does not match the target, it automatically validates and retries once.

The default target language for new installations is **English**.

<!-- SCREENSHOT TODO: Translation target-language selector; capture on a release build, redact credentials, and supply matching zh/en alt text. -->

Best for:

- Speaking Chinese directly into English
- Speaking English directly into Chinese
- Writing foreign-language emails and messages
- Communicating with international colleagues
- Multilingual and minority language typing

**In a nutshell: Turn "voice input → copy → paste into translator" into a single hotkey.**

---

### 💬 Ask Anything: See Anything, Ask Right Away

"Ask Anything" is not a direct text injection mode; it is an on-demand voice AI Q&A window always ready to be invoked.

You can select a snippet of text on screen, press the hotkey, and ask directly by voice:

> What's wrong with this code?

> Summarize this for me

> What does this sentence mean?

> Translate this to Chinese

> What is the core takeaway here?

Type4Me submits the **selected text + your spoken question** together to the model, returning the answer in a standalone floating window.

It works great without selecting text too—just ask directly:

> What's the difference between a Python list and tuple?

> Give me 3 creative product names

> What usually causes this error?

It also supports continuous follow-ups, retaining full conversation context. All sessions are saved in history, allowing you to search, resume, rename, or delete past conversations from Settings.

<p align="center">
  <img src="docs/screenshots/screenshot-askit.png" width="480" alt="Ask Anything Conversation History" />
</p>

This means when browsing web pages, reading documentation, reviewing code, or reading emails, you never need to copy text, open ChatGPT, paste, and type out your question.

**Select → Press Hotkey → Speak.**

**In a nutshell: System-wide "Select text & Ask AI".**

---

### 🖥️ Mac Actions: Control Your Mac by Voice

Mac Actions mode does not turn your speech into text; it interprets your voice as a macOS system action and executes it directly.

For example:

> Open Safari

> Set volume to 30

> Toggle dark mode

> Take a screenshot

> Search for SwiftUI tutorials

> Lock screen

> Minimize window

> Close this window

> Remind me to check email in two minutes

> Scroll down

You can even control Type4Me itself:

> Open hotwords

> Open snippet replacement

> Add selected word to hotwords

Actions execute only when matched against supported Type4Me commands; it is a safe, focused assistant rather than an unconstrained arbitrary agent.

**In a nutshell: Turn multi-click mouse operations into a single spoken phrase.**

---

### 📝 Voice Polish: Reliably Turn Spoken Words into Written Prose

Voice Polish is a deterministic, predictable text formatting mode.

It will not answer your questions or continue creative writing—its sole responsibility is:

**Organizing conversational speech into clear, readable written text.**

It handles:

- Filler words like "um, uh, you know, like"
- Repeated and abandoned half-sentences
- Mid-sentence corrections
- Typos and sentence segmentation
- Spoken numbers into standard digits
- Multi-point bullet structuring
- Differentiated formatting for formal documents vs. casual chat

For example, when you say:

> We have mainly three things this week oh wait no two things first launch the new release second finish the documentation

It organizes the text into:

> We have two main tasks this week:
>
> 1. Launch the new release.
> 2. Complete the documentation.

Compared to Intelli Sense, **Voice Polish functions like a fixed set of text cleanup rules**; Intelli Sense further adapts to the active app and your personal habits.

If you prefer consistent, highly predictable output, or are writing formal copy, Voice Polish is an excellent choice.

**In a nutshell: Faithful "spoken words → written prose" transformation.**

---

### 🧠 Prompt Optimization: Turn a Single Sentence into a High-Quality Prompt

Sometimes you know what you want AI to do, but don't feel like typing a lengthy, structured prompt.

Just say:

> Analyze whether we have a user retention issue this quarter

Prompt Optimization does not answer the question directly. Instead, it expands your brief idea into a comprehensive prompt ready for LLM execution, adding:

- Professional persona/role
- Analytical dimensions
- Step-by-step execution plan
- Cross-validation checkpoints
- Structured output format

For simple tasks, it keeps things concise; for research, analysis, and architectural tasks, it injects structured domain frameworks.

It is an ideal companion for:

- ChatGPT
- Claude
- Codex
- Cursor
- Claude Code
- Any AI Agent

Your workflow becomes:

**Press Hotkey → Speak your requirement → Type4Me generates a structured Prompt → Auto-pasted into your AI dialogue.**

**In a nutshell: You specify "what you want"; it crafts the professional prompt.**

---

### 🚀 Task Delegation: Skip the Prompt, Deliver the Finished Result

Prompt Optimization writes a better task specification for you.

Task Delegation goes one step further:

**Skip the prompt—give me the final deliverable directly.**

For instance, say:

> Write an email to the vendor explaining our payment process has a slight delay and will take 3 more days, asking for their understanding

It directly generates the complete email ready to send.

You can also say:

> Reply to boss that I can make the 3 PM sync

> Write a Python function calculating the nth Fibonacci number

> Translate this selected sentence into natural English

> Draft a reply based on what's in my clipboard

Task Delegation combines:

- Your spoken requirement
- Text currently selected on screen
- Clipboard contents

It generates the finished product and injects it directly into your active application.

Difference between Ask Anything and Task Delegation:

| | Ask Anything | Task Delegation |
| --- | --- | --- |
| Core Purpose | Inquiries, understanding, multi-turn discussion | Direct delivery of final content |
| Output Target | Dedicated floating Q&A window | Current cursor position |
| Follow-ups | Yes, preserves conversation context | No (single-shot deliverable) |
| Typical Scenario | "What does this mean?" | "Reply to this message" |

**In a nutshell: Prompt Optimization says "help me explain the task"; Task Delegation says "just do it for me".**

---

### Which Mode Should I Use?

If you want a quick decision guide, this table covers it all:

| What I want to do right now... | Use this |
| ----------------------------- | -------- |
| Fast raw typing as-is | **Quick Mode** |
| Daily chat, email, and document input | **Intelli Sense** |
| Predictably polish spoken words into written prose | **Voice Polish** |
| Speak in one language, output in another | **Translation** |
| Ask AI about content on my screen | **Ask Anything** |
| Control my Mac with a single phrase | **Mac Actions** |
| Generate a professional prompt for ChatGPT / Claude | **Prompt Optimization** |
| Skip the prompt and get the final result directly | **Task Delegation** |

---

### Need More? Create Your Own Custom Modes

Beyond the 8 default modes, you can add any custom LLM text processing mode you need.

For example:

- "Rewrite my words into formal corporate tone"
- "Auto-translate into Japanese"
- "Format as social media post"
- "Convert into a structured GitHub Issue"
- "Turn spoken requirements into a Product Requirement Document (PRD)"
- "Generate a Git Commit Message based on selected code"

Custom Prompts support three template variables:

| Variable | Description |
| -------- | ----------- |
| `{text}` | The recognized speech text from the current recording |
| `{selected}` | Text selected on screen when recording started |
| `{clipboard}` | Content in clipboard when recording started |

Example template:

```text
Below is the text currently selected by the user:

{selected}

User's spoken modification instruction:

{text}

Please modify the selected content according to the user's instruction. Output only the revised result.
```

This transforms Type4Me from just a "voice input method" into a universal global hotkey trigger for any LLM text workflow.

#### Final Output Formatting

Final output can optionally apply Pangu-style CJK/Latin spacing and Chinese corner quotes while preserving English apostrophes.

---

### Vocabulary Management & Companion Skill

- **ASR Hotwords**: Add proper nouns (e.g., `Claude`, `Kubernetes`) to improve recognition accuracy
- **Snippet Replacement**: Say "my email" and it auto-replaces with your actual email address

The companion Skill can use Type4Me vocabulary commands to open vocabulary management and reload the vocabulary, helping turn recurring proper-name errors into hotword or snippet-replacement rules.

<p align="center">
  <img src="docs/screenshots/screenshot-vocabulary.png" width="480" alt="Vocabulary Management" />
</p>

---

### URL Scheme / External Automation

Type4Me exposes a URL Scheme for browsers, Terminal, macOS Shortcuts, Raycast, Alfred, scripts, and AI agents.

#### Registered Schemes

Different builds register different schemes, and **each installed app accepts only the scheme actually registered in its bundle**:

| Build | Default Scheme | Example |
| --- | --- | --- |
| Public release | `type4me://` | `type4me://settings` |
| Dev build | `type4me-dev://` | `type4me-dev://settings` |
| Personal / CtriXin build | `type4me-ctrixin://` | `type4me-ctrixin://settings` |

Examples below use `type4me://`. For Dev or Personal builds, replace only the scheme prefix.

#### Recording Control Commands

Direct, deterministic recording control for Stream Deck, Raycast, Alfred, BetterTouchTool, Hammerspoon, and macOS Shortcuts without simulating keyboard events:

##### Start Recording
```text
type4me://start
```
- Starts recording using the currently active mode in Type4Me (`AppState.currentMode`);
- Idempotent: repeated calls while preparing or recording do not interrupt the active session;
- Safely ignored while processing or recovering.

##### Stop Recording
```text
type4me://stop
```
- Finishes the active recording and proceeds through transcription, LLM processing, and text injection;
- Active only during `preparing` or `recording`; safely ignored when idle or processing;
- Does not cancel: all recorded speech is preserved and processed.

##### Toggle Recording
```text
type4me://toggle
```
- Starts recording when idle, and finishes recording when preparing or active; ideal for single-button Stream Deck actions;
- Safely ignored while processing or recovering.

> **Best Practice (Recommended `-g` Background Flag)**:
> - When invoking from terminals, scripts, or automation utilities (Stream Deck, Raycast, Alfred, BetterTouchTool, Hammerspoon, Shortcuts, etc.), use **`open -g 'type4me://toggle'`** (the `-g` / `--background` option);
> - The `-g` flag delivers the URL event purely in the background without activating Type4Me or stealing foreground focus, completely avoiding any window flicker or cursor disruption for a completely seamless dictation and text injection experience.
>
> Note:
> - Recording commands operate on Type4Me's currently active mode. Version 1 does not accept query parameters such as `?mode=` (unknown parameters are rejected);
> - Sessions started via URL Scheme are standard Type4Me sessions and can be finished or cancelled via the floating bar, menu bar, or global hotkeys.

#### Open Settings

```text
type4me://settings
```

`preferences` is an equivalent alias:

```text
type4me://preferences
```

#### Hotwords

Open Hotword management:

```text
type4me://vocabulary/hotwords
```

Open Settings and prefill a hotword:

```text
type4me://vocabulary/hotwords?word=Ghostty
```

Silently add a hotword without opening Settings:

```text
type4me://vocabulary/hotwords?word=Ghostty&silent=true
```

`silent=1` is also accepted. In silent mode, `word` is required; existing hotwords are deduplicated case-insensitively.

#### Snippet Replacements

Open snippet management:

```text
type4me://vocabulary/snippets
```

Prefill only the trigger:

```text
type4me://vocabulary/snippets?trigger=ghosty
```

Prefill both trigger and replacement:

```text
type4me://vocabulary/snippets?trigger=ghosty&replacement=Ghostty
```

Silently add a snippet rule:

```text
type4me://vocabulary/snippets?trigger=ghosty&replacement=Ghostty&silent=true
```

In silent mode, both `trigger` and `replacement` are required. An identical existing rule is treated as already present; a conflicting replacement is not silently overwritten.

#### Reload Vocabulary

```text
type4me://reload-vocabulary
```

This refreshes Hotword / Snippet caches, posts vocabulary-change notifications, and triggers local hotword synchronization and related service refreshes.

#### Deprecated: `auth`

```text
type4me://auth
```

Retained for backward compatibility only. Authentication now uses a code-based flow, so this endpoint is currently a **no-op** and should not be used by new integrations.

#### Validation Limits

Vocabulary URLs are strictly validated:

- Maximum URL size: **8 KB**;
- `word`: up to **256 characters**;
- `trigger`: up to **256 characters**;
- `replacement`: up to **4096 characters**;
- empty values and control characters are rejected;
- unknown query parameters are rejected;
- duplicate query parameters are rejected;
- `silent` accepts only `true` / `1` / `false` / `0`;
- vocabulary paths are limited to `/hotwords` and `/snippets`.

#### Terminal Examples

```bash
open 'type4me://settings'
open 'type4me://vocabulary/hotwords?word=Ghostty'
open 'type4me://vocabulary/snippets?trigger=ghosty&replacement=Ghostty&silent=true'
```

> URL-encode spaces, CJK text, `&`, `?`, and other special characters in query values.

---

### Voice Revise

For the most recent Type4Me insertion that can still be located reliably, press the Revise shortcut (default `Fn + R`) and speak an edit instruction. Type4Me limits changes to the authorized scope and fails safely when the target changed or cannot be found. Successful revisions can be undone by button or voice.

<!-- SCREENSHOT TODO: Real Revise workflow screenshot showing source text, revise status, and undo result; currently showing prototype mockup. -->

<p align="center">
  <img src="docs/screenshots/prototype-revise.png" width="480" alt="Type4Me Voice Revise (Prototype)" />
</p>

- **Smart Slot Targeting**: Say "change it to 2 PM" or "Tom instead of Jerry"—the engine automatically targets and replaces only the intended slot while preserving the rest of your text;
- **Fact Protection Guard**: Enforces strict protection on unauthorized numbers, amounts, and dates to prevent LLM hallucinations from modifying unmentioned facts;
- **One-Click & Voice Undo**: After revising, a floating "Undo" capsule appears; you can also simply say "undo" or "revert" by voice to restore the original text instantly.


## Architecture Overview

| Module | Description |
|--------|-------------|
| `Type4Me/ASR/` | ASR engine abstraction layer, pluggable provider architecture |
| `Type4Me/Audio/` | Audio capture (16kHz mono PCM) |
| `Type4Me/Session/` | Core state machine: record > ASR > inject |
| `Type4Me/Services/` | Credential storage, hotwords, model management, Python service management |
| `Type4Me/LLM/` | LLM text processing (14 providers) |
| `Type4Me/Input/` | Global hotkey management |
| `Type4Me/Injection/` | Text injection (clipboard Cmd+V) |
| `Type4Me/Bridge/` | SherpaOnnx C API Swift bridge (optional) |
| `Type4Me/UI/` | SwiftUI interface: floating window + settings |
| `Type4MeIntelliSenseCore/` | Intelli Sense context awareness and preference learning core |
| `Type4MeReviseCore/` | Voice Revise tracking, slot targeting, and replacement core |
| `qwen3-asr-server/` | Python Qwen3-ASR calibration service (Apple Silicon, MLX) |

The ASR provider architecture is fully pluggable: implement `ASRProviderConfig` (define credential fields) and `SpeechRecognizer` (implement recognition logic), register with `ASRProviderRegistry`, and you have a new engine.


## Contributing

Start with the [`docs/README.md`](docs/README.md) documentation index. Historical plans and reviews are archived separately from current specifications.

PRs and Issues are welcome. This entire project was built by the author using Claude Code.

Regarding PRs: even if there are bugs or code quality issues, the number one rule is to never drop anyone's contribution. You can always fix things after merging.


## Acknowledgments

- [SenseVoice](https://github.com/FunAudioLLM/SenseVoice) - Alibaba FunAudioLLM
- [streaming-sensevoice](https://github.com/pengzhendong/streaming-sensevoice) - @pengzhendong
- [asr-decoder](https://github.com/pengzhendong/asr-decoder) - @pengzhendong
- [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) - k2-fsa
- [Qwen3-ASR](https://github.com/QwenLM/Qwen3-ASR) - Alibaba Qwen
- [mlx-qwen3-asr](https://github.com/moona3k/mlx-qwen3-asr) - @moona3k


## For AI Agents

If you're an AI agent (Claude Code, Cursor, Copilot, etc.) tasked with building, deploying, or contributing to Type4Me, here's everything you need.

### Read these files first

1. `AGENTS.md` - full architecture guide, credential storage, key files, development patterns, and how to add new ASR/LLM providers
2. `Package.swift` - Swift Package Manager dependencies and build targets
3. `scripts/deploy.sh` - the build & deploy pipeline (calls `scripts/package-app.sh`)

### Prerequisites

- macOS 14.0+ (Sonoma)
- Xcode Command Line Tools: `xcode-select --install`
- Python 3.12: `brew install python@3.12` (for local ASR servers)
- CMake: `brew install cmake` (only if building SherpaOnnx punctuation engine)

### Build & deploy

```bash
# 1. Clone
git clone https://github.com/joewongjc/type4me.git && cd type4me

# 2. (Optional) Build SherpaOnnx punctuation engine (~5 min, needs cmake)
bash scripts/build-sherpa.sh

# 3. (Optional) Setup Qwen3-ASR server (needs python3.12, Apple Silicon only)
cd qwen3-asr-server && python3.12 -m venv .venv && source .venv/bin/activate && pip install -r requirements.txt && cd ..

# 4. Dev deploy (builds, signs, installs /Applications/Type4Me Dev.app, launches)
# Complete the one-time Xcode signing setup below before the first run.
bash scripts/dev-run.sh

# Subsequent updates
git pull && bash scripts/dev-run.sh
```

Steps 2-3 are optional. Skipping them disables local ASR, but cloud ASR works fine.

### Code signing & permissions

Stable development signing is required to preserve Keychain, Accessibility, and
Microphone permissions across rebuilds. Complete this one-time setup before the
first Dev deploy:

1. Install and open the full Xcode application. Xcode Command Line Tools alone
   cannot configure the signing account.
2. Open **Xcode > Settings > Accounts**, click **+**, choose **Apple Account**,
   and sign in. A paid Apple Developer membership is not required; Xcode can use
   the account's **Personal Team** for local development signing.
3. Select the account and confirm that a Team is listed. You may create the
   certificate manually through **Manage Certificates... > + > Apple
   Development**, or let the repository setup script request it from Xcode:

   ```bash
   bash scripts/setup-dev-signing.sh
   ```

4. Confirm that macOS Keychain contains a valid signing identity:

   ```bash
   security find-identity -v -p codesigning
   ```

   The output must include an `Apple Development: ...` identity. If multiple
   Xcode teams are configured, select one explicitly:

   ```bash
   DEVELOPMENT_TEAM=<team-id> bash scripts/setup-dev-signing.sh
   ```

5. Build and install the development app:

   ```bash
   bash scripts/dev-run.sh
   ```

`dev-run.sh` uses `/Applications/Type4Me Dev.app` and the dedicated
`com.type4me.dev` bundle ID. On the first signed deploy it may ask once for the
Login Keychain password to migrate existing Type4Me credential access from
changing binary hashes to the stable Apple Team ID. The password is held in
memory only and is never stored.

After first launch, grant Microphone and Accessibility access to **Type4Me Dev**
once in **System Settings > Privacy & Security**. Subsequent Dev builds reuse the
same Apple identity, Team ID, bundle ID, and install path, so these permissions
remain valid.

> Here, "development/self signing" means an Xcode-managed **Apple Development**
> certificate associated with the developer's Apple Account. It is not ad-hoc
> signing (`-`). Dev deploys intentionally fail when no stable identity is
> available. `ALLOW_ADHOC_SIGNING=1 bash scripts/dev-run.sh` is an emergency-only
> fallback and may cause macOS to request permissions again after every rebuild.

For non-Dev packaging, a signing identity can be supplied explicitly with
`CODESIGN_IDENTITY="Your Cert" bash scripts/deploy.sh`.

### Key architecture points

- **Swift Package Manager** project, no `.xcodeproj` needed
- **Local ASR**: dual-engine design. SenseVoice (streaming partial results) + Qwen3-ASR (final calibration via MLX/Metal). Both run as Python WebSocket servers managed by `SenseVoiceServerManager`
- **Cloud ASR**: 14 providers implemented (Volcano, StepFun streaming, StepFun batch, MiMo batch, OpenAI, Deepgram, Cartesia, AssemblyAI, ElevenLabs, Gemini, Grok, Soniox, Bailian, Baidu)
- **Credentials**: stored at `~/Library/Application Support/Type4Me/credentials.json` (mode 0600), never in code or environment variables. GUI apps cannot read shell env vars from `~/.zshrc`
- **ASR provider architecture**: plugin-based. To add a new provider: implement `ASRProviderConfig` + `SpeechRecognizer` protocol, register in `ASRProviderRegistry.all`. See `AGENTS.md` for details
- **Audio format**: 16kHz mono PCM16-LE, 200ms chunks (6400 bytes)
- **Text injection**: clipboard-based Cmd+V paste with save/restore


## Demo Video

<video src="https://github.com/user-attachments/assets/d5ad6da9-b924-4fd6-9812-d0d9868563a4" width="600" title="demo" controls>demo</video>


## Star History

<a href="https://star-history.dera.page/#joewongjc/type4me&type=date&legend=top-left">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://star-history.dera.page/svg?repos=joewongjc%2Ftype4me&type=date&theme=dark&legend=top-left" />
   <source media="(prefers-color-scheme: light)" srcset="https://star-history.dera.page/svg?repos=joewongjc%2Ftype4me&type=date&legend=top-left" />
   <img alt="Star History Chart" src="https://star-history.dera.page/svg?repos=joewongjc%2Ftype4me&type=date&legend=top-left" />
 </picture>
</a>

## License

[MIT License](LICENSE)
