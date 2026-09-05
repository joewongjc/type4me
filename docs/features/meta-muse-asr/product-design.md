# Type4Me Meta Muse Voice Transcribe 产品设计

> 分支：`feat/meta-muse-asr`
> 文档类型：产品设计
> 文档状态：当前有效（已实现，持续验证）
> 最后校验：2026-09-05
> 实现基线：`6fdfb8d`
> 设计日期：2026-09-03
> 目标版本：Type4Me 2.x
> 官方研究发布：https://research.meta.ai/blog/introducing-muse-voice-transcribe
> 模型：Meta Muse Voice Transcribe

## 1. 背景

Meta 于 2026-09-01 发布 Muse Voice Transcribe，定位为 Meta Superintelligence Labs 的首个实时音频感知模型。Meta 官方研究说明确认其同时具备：

- real-time streaming ASR；
- 原生 speaker diarization，支持 20+ speakers；
- 原生 endpointing；
- 70+ 语言训练覆盖，其中 25 种在首发阶段经过重点验证；
- seamless code-switching；
- language、keyword、context biasing；
- 模型内部以 80 ms 音频块工作，并通过 adaptive delay 平衡准确率与延迟；
- 可通过 Meta Model API 使用，并已用于 Meta AI for Mac 与 Muse Code 的语音输入。

对于 Type4Me，最重要的不是 diarization，而是它与现有产品形态高度一致：Muse 本身已经被 Meta 用于 macOS 全局听写，而 Type4Me 的核心也是“全局快捷键 + 实时 ASR + 文本处理 + 注入”。

因此本功能不是增加一个会议转写子系统，而是增加一个新的高质量实时 ASR Provider。

## 2. 产品目标

### 2.1 核心目标

1. 将 Muse Voice Transcribe 作为标准实时云端 ASR Provider 接入 Type4Me；
2. 在录音过程中持续显示实时识别文本，而不是松开后再批量识别；
3. 保留 Type4Me 当前按住/切换快捷键决定录音边界的交互语义；
4. 将 Type4Me 现有 HotwordStorage 映射到 Muse keyword biasing；
5. 优先发挥中文、英文和中英句内 code-switching 能力；
6. 不因为 Muse 额外支持 diarization / endpointing 而扩大第一版产品范围；
7. API Key 继续使用 BYOK 模式和 macOS Keychain；
8. 不改变现有 Direct、Intelli Sense、翻译、Revise 等后处理模式。

### 2.2 成功标准

1. 用户可在 ASR Provider 设置中选择 `Meta Muse`；
2. 配置有效 Meta Model API Key 后能完成真实远程连接验证；
3. 开始录音后，Muse 能在用户说话期间持续产生 partial transcript；
4. 松开快捷键后完成当前转写并产生 final transcript；
5. 中英文混输无需手动切换语言即可正常工作；
6. Type4Me 热词能作为 Muse keyword bias 输入，并在技术词汇测试中可观察到正向作用；
7. Muse 的 endpointing 不会擅自结束 Type4Me 的录音；
8. Muse 的 speaker labels 不会污染普通听写文本；
9. 失败时不会注入未完成或错误的 partial text；
10. 中英文设置、错误和说明文案完整。

## 3. 非目标

第一版不包含：

- 会议转写界面；
- 多说话人 transcript 数据模型；
- 用户身份与 speaker label 绑定；
- 自动根据 Muse endpointing 停止 Type4Me 录音；
- Voice Agent 自动轮次控制；
- 录音文件批量转写入口；
- 本地部署 Muse Voice Transcribe；
- 自定义模型名称；
- 自动把窗口内容、剪贴板或历史记录发送给 Meta 做 context biasing；
- 词级 timestamp、confidence score 或字幕导出；
- 将 Muse 在首版直接设为默认 Provider。

## 4. Provider 定位

### 4.1 用户可见名称

中文：`Meta Muse`

英文：`Meta Muse`

设置说明中使用完整模型名：`Muse Voice Transcribe`。

不建议把 Provider 名称写成单独的 `Muse`，避免未来 Muse 家族增加其他 Voice 模型后产生歧义。

### 4.2 Provider 分类

Muse 属于国际云端实时 ASR Provider。

第一版进入普通 Provider 列表，不立即加入 Recommended Providers。推荐资格需要基于 Type4Me 自己的中文、中英混输、技术词汇和真实 macOS 麦克风测试，而不是只依据发布 benchmark。

### 4.3 与现有 Provider 的差异

Muse 的产品价值主要来自：

- 真正实时的音频输入和文本输出；
- 原生 code-switching；
- keyword biasing 与 Type4Me hotwords 高度匹配；
- 模型原生 endpointing，可为未来 Agent Mode 使用；
- 单模型同时具备 diarization，为未来会议/多人场景留下空间。

第一版刻意只消费其中与个人听写直接相关的能力。

## 5. 第一版核心产品决策

### 5.1 使用 Push-to-Talk 语义

Type4Me 的录音边界由用户控制：

- 按住式：按下开始，松开结束；
- 切换式：第一次触发开始，再次触发结束。

Muse 的 API 被公开开发资料描述为支持 Push-to-Talk、Endpointing 和 Diarization 等会话模式。第一版应选择与 Type4Me 现有行为一致的 Push-to-Talk 语义。

即使 Muse 检测到一个 speech endpoint，也不能因此自动停止录音或触发注入。

### 5.2 Diarization 默认关闭

普通 Type4Me 听写默认只有一个说话人。启用 diarization 会引入没有产品价值的 speaker metadata，并要求修改 `RecognitionTranscript` 数据模型。

因此第一版：

- 不展示 diarization 开关；
- 不把 speaker label 写入用户文本；
- 不新增会议模式。

### 5.3 Endpointing 不控制录音生命周期

如果 Push-to-Talk 模式仍返回 utterance/turn boundary，可把它用于内部 segment finalization；但用户快捷键仍是唯一的录音结束信号。

未来 Agent Mode 可以单独设计“自动对话轮次”能力，再启用 endpointing 作为核心信号。

### 5.4 Hotwords 直接映射 Keyword Biasing

Type4Me 已经维护全局 ASR hotwords。Muse 官方明确支持 keyword biasing，因此第一版应自动复用这些词。

要求：

- 不增加第二套 Muse 专属热词库；
- 不把 boosting table 等其他 Provider 专属字段硬映射到 Muse；
- 不在日志里输出完整 hotword 内容；
- 若 API 对数量或长度有上限，客户端按官方限制截断并记录非敏感计数。

### 5.5 Context Biasing 第一版关闭

Muse 支持 context biasing，但 Type4Me 的上下文可能包含：

- 当前窗口文本；
- 剪贴板；
- 历史输入；
- 联系人、文件名、项目内容。

这些信息比普通 hotwords 更敏感。第一版不自动发送任何 Intelli Sense Context 给 Meta。

未来若验证收益明显，应作为独立功能，提供清晰的数据范围和隐私说明。

## 6. 用户流程

### 6.1 首次配置

1. 用户进入 ASR 设置；
2. 选择 `Meta Muse`；
3. 输入 Meta Model API Key；
4. 可选设置语言提示；
5. 点击“测试连接”；
6. Type4Me 完成真实 WebSocket 鉴权/握手后显示成功；
7. 用户开始正常使用快捷键听写。

### 6.2 录音过程

```text
按下快捷键
    ↓
建立/准备 Muse realtime session
    ↓
持续发送 PCM
    ↓
收到 partial transcript
    ↓
浮动栏实时更新
    ↓
松开快捷键
    ↓
发送输入结束信号
    ↓
收到 final transcript
    ↓
进入 Direct / LLM / Revise 等现有流程
```

### 6.3 用户感知

Muse 必须表现为真正的实时 Provider：

`录音中 + 实时文本 → 松开 → 短暂 finalization → 完成`

不能退化成：

`录音中 → 松开 → 等待整段上传 → 文本出现`

## 7. 设置设计

### 7.1 第一版字段

| 字段 | 类型 | 默认值 | 必填 |
|---|---|---|---|
| API Key | Secure | 空 | 是 |
| 语言提示 | Picker | Auto | 否 |

模型固定为当前 Meta Model API 的 Muse Voice Transcribe 首发模型，不向用户提供任意 model 字符串。

### 7.2 语言提示

Muse 原生支持 code-switching，因此默认使用 `Auto / No Bias`。

如果官方开发文档提供稳定 language bias code，Picker 可提供 Meta 当前重点验证语言。具体 code 必须在实现阶段按官方 reference 生成，不在产品基线中自行猜测。

对 Type4Me 来说至少要验证：

- Auto；
- Mandarin Chinese；
- English；
- 中文 + 英文句内切换。

### 7.3 Provider 说明

中文建议：

`实时语音识别，支持中英混输和关键词增强。Muse 的说话人分离与自动端点能力首版不用于控制 Type4Me 录音。`

英文建议：

`Realtime transcription with code-switching and keyword biasing. Muse diarization and automatic endpointing do not control Type4Me recording in the first release.`

## 8. 实时文本与最终文本

Muse 的 partial hypothesis 可能随更多音频到达而修订，因此 Type4Me 必须继续遵循现有 streaming ASR 规则：

- confirmed segments 与 current partial 分离；
- partial 只能替换，不可盲目 append；
- final segment 才进入 confirmed text；
- 最终 authoritative text 只在 Provider 明确完成后冻结。

浮动栏可以显示不断修订的 partial，但 Direct 注入和后续 LLM 输入只使用最终结果。

## 9. Audio 与延迟体验

Type4Me 当前内部音频格式是 16 kHz、mono、signed 16-bit PCM，200 ms 一块。公开的 Muse API 资料一致指向 realtime endpoint 接受 16/24 kHz mono PCM，因此 Type4Me 当前格式原则上无需转码。

Muse 模型内部按 80 ms 音频块推理，不代表客户端必须把每个 WebSocket frame 精确切成 80 ms。

第一版不为了 Muse 修改全局 AudioCaptureEngine chunk size。先使用现有 200 ms capture chunk 做真实延迟测试；只有确认它显著限制首字延迟时，才单独设计 provider-aware chunking 或全局采集粒度调整。

## 10. 价格、可用性与产品承诺

发布期公开资料普遍给出 Muse Voice Transcribe 的 Meta Model API 价格为 `$3 / 1000 audio minutes`，约 `$0.18 / hour`。

该价格、免费额度、区域开放和 rate limit 都属于可能快速变化的服务条款。Type4Me：

- 不在长期 UI 文案中硬编码价格；
- README 如需展示价格必须标注查询日期；
- 发布前重新核对 Meta 官方控制台；
- 不承诺某个国家或账号一定可开通。

Meta 官方研究材料声称其在 2026-09-01 的 Artificial Analysis streaming STT 排名第一。这个结果只能作为评测动机，不能替代 Type4Me 自己的中文 benchmark。

## 11. 隐私与安全

- API Key 存入 macOS Keychain；
- 音频只在 Muse 被选为当前 Provider 时发送给 Meta；
- 第一版不发送 Intelli Sense 上下文；
- Hotwords 会作为识别 bias 数据发送，因此设置说明应视其为云端 ASR 请求的一部分；
- 日志不得记录 API Key、认证 frame、完整 PCM、完整 transcript 或完整 hotword 列表；
- 发布前必须核对 Meta Model API 当前数据保留、训练使用、地区与企业隐私条款；
- 在条款未核实时，不对用户宣称“零保留”或“不会用于训练”。

## 12. 错误体验

至少覆盖：

| 场景 | 用户体验 |
|---|---|
| API Key 为空 | 配置无效 |
| 鉴权失败 | API Key 无效或没有 Muse 权限 |
| 区域/账号不可用 | 当前 Meta 账号或地区暂不可使用该模型 |
| WebSocket 握手超时 | 连接 Meta Muse 超时 |
| WebSocket 意外关闭 | Muse 连接已中断，请重试 |
| 发送速度/积压超限 | 音频流无法及时处理，请重试 |
| Session 达到服务限制 | 结束当前录音并提示重新开始 |
| 无最终文本 | 未识别到有效语音 |
| 服务端 schema 无法解析 | Muse 返回了无法解析的结果 |

所有用户可见错误必须中英文对应。

## 13. 测试连接

“测试连接”必须验证真实远程能力，而不是只检查 API Key 非空。

理想行为：

1. 建立 realtime WebSocket；
2. 完成 Meta 要求的认证和 session configuration；
3. 等待明确的 ready/session-created ack；
4. 正常关闭；
5. 只有完成上述步骤才显示“连接成功”。

如果 Meta 的认证机制要求发送首个配置 frame，测试连接必须覆盖这个 frame。

## 14. Type4Me 自有评测

在把 Muse 加入 Recommended Providers 前，至少比较：

- Muse；
- Volcano；
- Soniox；
- Deepgram；
- Gemini realtime ASR（若当时仍作为对照）。

测试集应包含：

1. 普通中文；
2. 普通英文；
3. 中英句内 code-switching；
4. Swift / GitHub / API / macOS 等技术词汇；
5. 含 Type4Me 热词与不含热词的 A/B；
6. 安静内置麦克风；
7. AirPods / 蓝牙麦克风；
8. 中等环境噪音；
9. 短命令与 1~3 分钟连续口述。

核心指标：

- 首个可见 partial 延迟；
- 松手到 final 延迟；
- 中文 CER / 人工错误计数；
- 英文 WER；
- 专有名词命中率；
- 连接失败率；
- partial 抖动程度。

## 15. 验收场景

### 15.1 中文实时听写

选择 Auto，录制中文，确认说话过程中出现 partial，松开后得到 final 并正常注入。

### 15.2 中英混输

说出类似：

`这个 pull request 的 implementation 有一个 regression。`

确认语言切换不会产生明显断句或整段错误语言识别。

### 15.3 Hotword

加入产品名、代码库名或人名热词，分别比较启用与禁用 hotword 的识别结果。

### 15.4 长停顿

录音过程中自然停顿数秒后继续说话，确认 Muse endpointing 不会提前结束 Type4Me 录音。

### 15.5 Direct 与 LLM 模式

分别验证 Direct、快速模式、Intelli Sense、翻译和 Revise。Muse 只替换 ASR 层，不改变后续模式语义。

### 15.6 错误凭证

无效 API Key 必须在测试连接或首次真实连接时失败，不能出现假成功。

## 16. 发布策略

第一阶段：作为普通实时云端 Provider 发布，不设默认、不进推荐。

第二阶段：收集内部 benchmark 与早期用户反馈，重点观察中文、code-switching、hotword 和连接稳定性。

第三阶段：只有在 Type4Me 自有测试中持续优于或至少达到当前推荐 Provider，才考虑加入 Recommended Providers。

## 17. 后续演进

- Agent Mode 使用 Muse endpointing 自动判断用户说完；
- Meeting / Conversation 模式消费 diarization 和 turn timestamps；
- 用户明确授权后，把 Intelli Sense Context 映射到 context biasing；
- 支持 Meta file transcription endpoint；
- provider-aware 80~100 ms audio chunking；
- 如果 Meta 发布本地权重，再单独评估 Local Provider。

## 18. 调研依据与证据等级

### 官方已确认

Meta Research 发布页确认：实时 ASR、80 ms 内部音频块、adaptive delay、endpointing、20+ speaker diarization、70+ 训练语言 / 25 个重点验证语言、code-switching、language/keyword/context biasing、长音频能力，以及 Meta Model API / Meta AI for Mac / Muse Code 可用性。

### 交叉资料确认、实现前需官方 Reference 复核

多个对 Meta 开发文档的同步/引用资料一致给出：模型 ID `muse-voice-transcribe-1.0`、realtime WebSocket 与 file transcription 两类 endpoint、16/24 kHz mono PCM 输入、realtime session 时长限制、Push-to-Talk / Endpointing / Diarization 模式和发布期价格。

这些字段会快速变化，且当前 Meta Developer reference 对自动抓取不稳定，因此技术实现不得仅凭本文复制 wire schema；开发开始时必须在 Meta 官方开发者控制台再次核对。
