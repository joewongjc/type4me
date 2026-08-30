# Type4Me Gemini ASR Provider 产品设计

> 文档类型：产品设计
> 文档状态：当前有效（已实现，持续验证）
> 设计日期：2026-08-27
> 最后校验：2026-08-30
> 实现基线：`c82aa2b`
> 对应开发设计：[development-design.md](development-design.md)
> 官方 Live Transcription 文档：https://ai.google.dev/gemini-api/docs/live-api/live-transcribe
> 官方模型说明：https://ai.google.dev/gemini-api/docs/models/gemini-3.5-transcribe
> 官方定价：https://ai.google.dev/gemini-api/docs/pricing
> 官方 Rate Limits：https://ai.google.dev/gemini-api/docs/rate-limits

## 1. 背景

Google 在 2026 年 8 月发布 Gemini 3.5 Transcribe，其中 `gemini-3.5-transcribe-live` 是面向实时语音识别的专用 Live API 模型。它通过 WebSocket 接收持续 PCM 音频，并同时返回低延迟 interim transcript 与 finalized transcript。

Type4Me 当前已经有成熟的多 Provider ASR 架构，也已经具备实时识别文本、热词、录音快捷键、紧凑型实时转写指示器和最终文本处理管线，因此这个能力不需要引入新的产品工作流，适合作为一个新的 BYOK 云端实时 ASR Provider 接入。

本功能的核心产品判断是：

**Gemini 应作为独立的实时 ASR Provider 接入 Type4Me，而不是复用现有的 Google Cloud STT 占位 Provider。**Provider 在 UI 上叫 `Gemini`（厂商名），`gemini-3.5-transcribe-live` 是它下面的模型选项，后续新模型直接在同一 provider 内扩展。

原因是 Gemini Developer API 与 Google Cloud Speech-to-Text 在产品、鉴权、Endpoint、计费和模型语义上均属于不同体系。Type4Me 现有 `.google` 应继续表示传统 Google Cloud STT。

## 2. 产品定位

Gemini 实时转写在 Type4Me 中定位为：

- BYOK 云端实时语音识别；
- 面向日常语音输入和中英混输；
- 支持热词偏置；
- 支持可选 Smart Dictation；
- 支持录音期间实时显示文字；
- 不承担 Agent、LLM 对话或多模态理解能力。

它不是“Antigravity 模式”的复制。Antigravity 产品内部可能结合屏幕和聊天上下文，而 Gemini Transcribe Live API 本身是音频输入的专用转写接口。第一版 Type4Me 只接入公开 API 能力。

## 3. 产品目标

### 3.1 核心目标

1. 新增 `Gemini` 云端实时 ASR Provider，并在其下提供模型选择（首版 `gemini-3.5-transcribe-live`）；
2. 支持按住/切换快捷键录音期间实时显示 interim transcript；
3. 松开快捷键后快速得到 finalized transcript；
4. 默认使用 Smart transcription，优化语音输入文本的可读性；
5. 提供 Verbatim 模式满足逐字转写需求；
6. 将 Type4Me 全局热词映射到 Gemini `custom_vocabulary`；
7. 默认自动检测语言，同时允许用户提供常用语言提示或自定义 BCP-47 code；
8. API Key 使用现有 macOS Keychain；
9. 保持 Direct、Intelli Sense、翻译、自定义 Prompt 等后处理流程不变；
10. 不增加 Type4Me 自有服务端、账号或代理依赖。

### 3.2 成功标准

1. 用户可在「识别引擎」中选择 `Gemini`，并在其下选择模型，且不会显示「非实时 / Batch」标记；
2. 有效 Gemini API Key 可以通过设置页连接测试；
3. 录音开始后能够在浮动栏和紧凑型实时转写区域看到持续更新的文本；
4. 松开快捷键后，最终 transcript 稳定在 **2 秒内**返回（已有实时文本的快速路径为 **1 秒内**）；这是 Type4Me 现有流式 teardown 的硬性预算，超出会退化为约 5 秒的全量等待并可能触发一次多余的兜底识别；
5. 热词能够影响专有名词、技术词汇、产品名等识别；
6. Smart 与 Verbatim 两种模式行为明显且可预测；
7. 中英文及中英 code-switching 可以使用默认 Auto 模式完成；
8. 无效 Key、配额限制、网络错误、服务端关闭等不会被误报为成功；
9. 不记录 API Key、完整 WebSocket URL 或原始音频内容到日志。

## 4. 非目标

第一版不包含：

- `gemini-3.5-transcribe` 文件型 Batch Transcription；
- Speaker diarization；
- Word-level timestamps；
- 会议级长录音与 10 分钟以上 session rollover；
- 将截图、当前窗口文本或 Agent chat history 直接发送给 Gemini Transcribe；
- 使用通用 Gemini Live Agent 代替专用 Transcribe 模型；
- 自定义模型 ID；
- 自定义 Gemini Base URL；
- Type4Me Cloud 代理或统一计费；
- 自动根据当前 App/代码仓库生成额外 dynamic vocabulary；
- 将 Gemini 在首版直接加入“推荐 Provider”。

## 5. Provider 命名与分类

### 5.1 用户可见名称

Provider 名在中英文下统一显示为厂商名：

`Gemini`

模型作为 provider 下的一层选择单独呈现，首版下拉里只有一项：

`Gemini 3.5 Transcribe (Live)` → `gemini-3.5-transcribe-live`

这样命名的原因：Gemini 产品线包含 LLM、Live Agent、TTS、Translate 等多类模型，把模型版本塞进 provider 名会在 Google 发布新转写模型时逼我们新增 provider 或改名。选择路径改为「先选 Gemini，再选模型」后，新模型只是下拉里多一行，用户已保存的 API Key 与其他配置不受影响。

与 §5.3 的区分靠的是 `Google Cloud STT` 与 `Gemini` 两个入口本身，以及设置页的说明文案，而不是把模型版本写进 provider 名。

### 5.2 Provider 分类

第一版放入设置页的“其他 / Others”分组，不加入当前“推荐 / Recommended”。

原因：

- 模型刚发布；
- Type4Me 尚未完成真实中英混输、延迟、稳定性和成本评测；
- 推荐状态应基于 Type4Me 自有 Evaluation 结果，而不是官方宣传指标。

### 5.3 与 Google Cloud STT 的边界

保留现有 `Google Cloud STT` 入口语义，不重命名、不复用其 Service Account 配置。

用户应该能够明确区分：

- `Google Cloud STT`：传统 Google Cloud Speech-to-Text；
- `Gemini`：Gemini Developer API 的实时 Transcribe 模型系列。

## 6. 核心交互流程

### 6.1 开始录音

用户开始录音时：

1. Type4Me 建立或复用当前 Gemini WebSocket session；
2. 完成模型 setup；
3. 第一段真实音频到达时声明一次语音活动开始；
4. 持续发送 PCM 音频；
5. 收到 interim transcript 后实时刷新浮动栏。

用户感知为：

`开始录音 → 很快出现文字 → 文字随讲话持续修正`

### 6.2 录音期间

Gemini 会提供两类文本：

- Interim：低延迟、可被后续结果替换；
- Finalized：当前语音段的权威结果。

Type4Me UI 应继续遵守现有原则：

- partial 只替换，不重复追加；
- confirmed segment 只在 final 后提交；
- UI 展示 `confirmed + partial`；
- 不因为 interim 抖动而产生重复文本。

### 6.3 松开快捷键

松开快捷键后：

1. Type4Me 明确声明语音活动结束；
2. Gemini 尽快完成本次 turn finalization；
3. 最终 transcript 替换 interim；
4. 进入现有 Direct / LLM 后处理 / 注入流程；
5. 当前 WebSocket 由现有 session cleanup 逻辑关闭。

第一版采用 Push-to-Talk 的 Manual VAD 语义，避免松开后继续等待服务端自行判断长静音。

## 7. 设置设计

### 7.1 字段

第一版提供：

| 字段 | 类型 | 默认值 | 必填 |
|---|---|---|---|
| API Key | Secure | 空 | 是 |
| 转写模式 | Picker | Smart | 否 |
| 语言提示 | Picker + Custom | Auto | 否 |

模型固定为：

`gemini-3.5-transcribe-live`

不向普通用户暴露 Model 和 Base URL。

### 7.2 转写模式

选项：

- `Smart`：默认；
- `Verbatim`：逐字。

Smart 适合 Type4Me 的“语音输入”定位，会自动处理 filler words、重复、口误、自我纠正、数字、日期、列表、段落、大小写与标点。

Verbatim 适合：

- 会议原话记录；
- 采访；
- 语言学习；
- 需要保留语气词、重复和 false start 的场景。

### 7.3 为什么默认 Smart

Type4Me 的主场景不是法庭逐字稿，而是“说完即可输入”。用户通常期待的是接近书面输入的结果，而不是保留“嗯、呃、那个、我说错了”等口语噪声。

因此：

**Gemini Provider 默认 Smart，但必须允许用户切回 Verbatim。**

### 7.4 语言提示

默认：`Auto Detect`

建议首版预设：

- Auto Detect；
- 中文（普通话，简体）；
- 粤语（繁体，香港）；
- English (US)；
- 日本語；
- 한국어；
- Custom BCP-47。

Auto 不锁定单一语言，并支持跨 utterance 的语言切换，因此仍是绝大多数用户的推荐设置。

不在 Picker 中硬编码全部 85+ 语言，避免设置菜单过长；高级用户可以通过 Custom 输入官方支持的 BCP-47 code。

## 8. 热词

Gemini Live Transcription 支持 `custom_vocabulary`，最多 1,000 个术语，官方建议通常在 100 个以内效果最佳。

Type4Me 第一版直接复用全局 HotwordStorage：

`Type4Me hotwords → trim / 去空 / 去重 → Gemini customVocabulary`

产品要求：

- 不增加 Gemini 独立热词编辑器；
- 不改变现有全局热词语义；
- 不静默添加 Type4Me 自己的营销词或第三方词；
- 最多发送官方允许的 1,000 个词；
- 超过 1,000 个时只发送前 1,000 个，并在 Debug 日志记录数量，不记录词内容。

后续若加入当前 App、文件名、repo symbol 等上下文，应作为独立的“动态词表”功能设计，不与第一版混在一起。

## 9. 标点与文本后处理

Gemini Transcribe 没有与 Type4Me `enablePunc` 一一对应的简单标点开关。

第一版产品规则：

- 不伪造 `enablePunc` 到不存在的 Gemini 参数；
- Smart / Verbatim 决定 Gemini 自身的转写风格；
- Gemini 输出之后仍进入 Type4Me 现有 TextOutputFormatter 和 ProcessingMode 管线；
- 不为 Gemini 增加单独的最终文本注入逻辑。

## 10. 时长限制

官方当前限制：Live Transcription 单个 session 最长 10 分钟。

需要注意的是，这 10 分钟从 Type4Me 与 Gemini 建立连接时开始计时，而不是从用户开口时开始，所以实际可用录音时长会略短于 10 分钟。Type4Me 自身的 600 秒录音上限对 Gemini 不会先生效。

Type4Me 第一版不做自动 session rollover，因此：

- 产品定位仍是短到中等长度的语音输入；
- 不承诺会议级连续转写；
- 对外表述统一为「单次实时识别约 10 分钟」，不承诺精确到秒；
- 选择 Gemini 时，Type4Me 把自身录音上限收紧到 **570 秒（9 分 30 秒）**，抢在服务端关闭之前主动完成本段录音，走既有的「已达最大时长」提示，而不是让录音突然中断；
- 万一服务端仍先关闭，必须显示明确错误并触发恢复，而不是静默丢失后半段录音；
- 后续若真实用户需要长录音，再单独设计「finalize + reconnect + segment merge」。

## 11. Free Tier、成本与配额

截至 2026-08-27，Gemini API 定价页明确显示 `gemini-3.5-transcribe-live` 支持 Free Tier，Free Tier 的输入和输出均为免费。

Paid Tier 官方估算的 Live Transcribe 综合成本约为：

`$0.009 / 分钟`

其中约：

- 音频输入：`$0.005 / 分钟`；
- 文本输出：`$0.004 / 分钟`。

产品文档不能写死“每天免费 X 分钟”，因为 Gemini API Rate Limits 按 Project / Usage Tier 管理，实际配额可能变化，用户应以 Google AI Studio 当前项目显示为准。

## 12. Free Tier 数据使用提醒

Google 当前定价页明确区分：

- Free Tier：内容可能用于改进 Google 产品；
- Paid Tier：内容不用于改进 Google 产品。

第一版不增加强制弹窗，但在 README / Provider 指引或帮助链接中应能让用户访问官方 Pricing / Terms 页面。

如果未来 Type4Me 增加统一的“云端 ASR 隐私说明”组件，应将这一差异纳入统一展示，而不是只为 Gemini 单独设计一次性 UI。

## 13. 设置页链接

建议提供：

1. Live Transcription 接入文档；
2. Gemini API Key 获取入口；
3. Pricing / Rate Limits。

所有链接使用 Google 官方域名。

## 14. 错误体验

至少覆盖：

| 场景 | 用户提示方向 |
|---|---|
| API Key 为空 | 请先配置 Gemini API Key |
| API Key 无效 | API Key 无效或无权访问 Gemini Transcribe |
| WebSocket 建连失败 | 无法连接 Gemini 实时识别服务 |
| Setup 被拒绝 | Gemini Transcribe 初始化失败 |
| Rate limit / quota | 当前项目达到 Gemini API 配额限制，请稍后重试或检查额度 |
| 网络中断 | 连接中断，请重试 |
| 接近 10 分钟上限 | 复用既有「已达最大时长 / Max duration reached」提示（570 秒主动收尾），不新增文案 |
| Session 超过 10 分钟 | Gemini 单次实时识别最长约 10 分钟，请缩短录音 |
| 返回无法解析 | Gemini 返回了无法解析的识别结果 |
| 空音频 | 没有录到有效音频 |

所有用户可见文本必须有中英文版本。

## 15. 测试连接

Gemini 的 `connect()` 会实际进行 WebSocket 握手和 setup，因此通用 Provider 连接验证可以真正检查：

- API Key 是否有效；
- 模型是否可访问；
- WebSocket 是否可建立；
- setup 是否被服务端接受。

测试连接不需要发送真实音频，也不应该创建一段伪造录音。

## 16. 隐私与安全

- API Key 使用现有 Keychain；
- 非安全字段保存转写模式和语言提示；
- 原始音频只在用户主动选择 Gemini Provider 并录音时发送给 Google；
- 不持久化 WebSocket audio payload；
- 不记录完整 API Key；
- 不记录包含 API Key 的完整 WebSocket URL；
- 不记录完整音频 Base64；
- transcript 是否进入历史记录继续遵循 Type4Me 现有历史设置。

## 17. 可观测性

建议记录：

- WebSocket connect latency；
- setup complete latency；
- 首个 audio chunk 时间；
- 首个 interim transcript latency；
- activity end 到 final transcript latency；
- session duration；
- sent audio bytes / chunk count；
- hotword count；
- transcript character count；
- WebSocket close code；
- error category。

不得记录 API Key、完整 URL、完整热词内容或音频内容。

## 18. 验收场景

### 18.1 中文语音输入

- Auto + Smart；
- 连续说 5~15 秒中文；
- 实时文字持续出现；
- 松开后 final 在 2 秒内返回；
- Smart 能合理处理口语停顿和自我纠正；
- 最终文本正常注入。

### 18.2 中英混输

使用 Auto 输入中英文、代码名、产品名混合内容，确认不会因语言切换明显丢词。

### 18.3 热词

加入如 `Type4Me`、`WebSocket`、`SwiftUI` 等热词，比较启用前后的识别效果。

### 18.4 Verbatim

切换 Verbatim，确认 filler words、重复和 false start 不再被 Smart 清理。

### 18.5 实时 UI

验证：

- 普通浮动栏；
- 紧凑型实时转写指示器；
- partial 更新不重复；
- final 结果不会闪回旧 partial。

### 18.6 ProcessingMode

验证：

- Direct；
- 快速模式；
- Intelli Sense；
- 翻译；
- 自定义 Prompt。

Gemini 只替换 ASR 层，不改变 ProcessingMode 定义。

### 18.7 错误

至少验证：

- 无效 Key；
- 断网；
- 429 / quota；
- WebSocket 异常关闭；
- 超长 session；
- 只按下快捷键但没有说话时，不应出现任何错误提示。

### 18.8 界面语言

在中文与英文之间切换 `tf_language`，确认：

- Gemini 的转写模式与语言提示字段文案立即随之切换，无需重启；
- 已选中的模式与语言设置不因语言切换而改变；
- Provider 名称 `Gemini` 与模型 id 在两种语言下保持一致，不被翻译。

## 19. 发布策略

第一版作为普通“其他 / Others”实时 Provider 发布。

发布后重点评测：

- 中文 WER / CER；
- 英文 WER；
- 中英混输；
- 代码和产品术语；
- 首字延迟；
- 首个 interim 延迟；
- 松手到 final 延迟；
- Smart 模式的过度改写率；
- WebSocket 稳定性；
- 429 / quota 发生率；
- 实际分钟成本。

在真实 Evaluation 结果稳定后，再决定是否进入 Recommended。

## 20. 后续演进

可能的后续能力：

- 接入 `gemini-3.5-transcribe` Batch 文件转写；
- 10 分钟 session 自动 rollover；
- 从当前 App / repo / 文件名动态生成 custom vocabulary；
- 根据 ProcessingMode 自动选择 Smart / Verbatim；
- 针对会议模式增加 timestamps / diarization 的独立工作流；
- 将 Gemini 与 Type4Me ASR Evaluation 自动基准体系集成。

## 21. 第一版产品决策汇总

| 项目 | 决策 |
|---|---|
| Provider | 独立 Gemini Provider |
| 用户名称 | Gemini（模型在其下单独选择） |
| Capability | 实时 Streaming |
| 模型 | provider 下可选，默认 `gemini-3.5-transcribe-live`，支持手填新模型 |
| 默认模式 | Smart |
| 可选模式 | Verbatim |
| 语言 | Auto 默认 + 常用预设 + Custom BCP-47 |
| 热词 | 复用 Type4Me 全局 HotwordStorage |
| VAD | Push-to-Talk Manual VAD |
| Batch 模型 | 首版不接入 |
| 长录音 rollover | 首版不做 |
| 推荐状态 | 首版不推荐 |
| API Key | Keychain |
| Free Tier | 支持，但额度以 Google 项目实际 Rate Limits 为准 |
| 单次时长 | 约 10 分钟，接近上限时提示，不自动续接 |
| Final 延迟目标 | 松手后 2 秒内（快速路径 1 秒内） |
