# Mistral Voxtral ASR 产品设计

> 文档类型：产品设计
> 文档状态：当前有效（设计完成，待实现）
> 设计日期：2026-10-17
> 最后校验：2026-10-17
> 下游文档：`docs/features/mistral-asr/development-design.md`
> 官方文档：https://docs.mistral.ai/studio/audio/speech_to_text/offline_transcription
> 相关设计：`docs/features/groq-asr/`（共享层改动有重叠，见开发设计第 6 节）

## 1. 背景

Mistral AI 是欧洲的基础模型厂商，提供两类可以做语音转写的模型：

| 模型 | API 模型 ID | 发布 | 接口 | 官方价格 | 定位 |
|---|---|---|---|---|---|
| Voxtral Mini Transcribe 2 | `voxtral-mini-2602` | 2026-02-04 | `/v1/audio/transcriptions` | $0.003 / 分钟（$0.18 / 小时） | 专用转写模型，官方称 FLEURS WER 约 4%，支持 13 种语言、上下文偏置（热词）、说话人分离、词级时间戳 |
| Voxtral Small | `voxtral-small-2507` | 2025-07-15 | `/v1/chat/completions`（音频输入） | 音频 $0.004 / 分钟，另计文本 token | 24B 级多模态指令模型，可以“听懂”音频并按指令输出，32k 上下文 |

Voxtral Mini Transcribe 2 的价格与 Groq Whisper Turbo 接近，准确率更高，并原生支持热词，是目前非实时 BYOK 转写里价格和准确率都很有竞争力的选择。Voxtral Small 不是专用转写模型，但它能理解指令：可以按要求输出简体中文，可以更积极地利用热词上下文，适合口音重、术语多的内容。

Mistral 同时提供实时转写模型 Voxtral Realtime（$0.006 / 分钟），它不在本次范围内，但设计上为它预留了位置（见第 16 节）。

## 2. 产品目标

### 2.1 核心目标

1. 在“语音识别引擎”中新增 **Mistral AI**，提供 Voxtral Mini Transcribe 2 和 Voxtral Small 两个模型；
2. 默认使用 Voxtral Mini Transcribe 2，它是专用转写模型，结果可预测、价格最低；
3. 体验与现有非实时 Provider 一致：录音中缓存，松手后一次提交；
4. Type4Me 热词映射到 Voxtral 的原生热词能力（Mini 用 `context_bias`，Small 用指令上下文）；
5. 使用 Voxtral Small 时，**只做转写**：不回答语音里的问题，不执行语音里的指令，没有语音时不输出解释性文字；
6. 测试连接必须真实校验 API Key；
7. 中英文界面文案完整。

### 2.2 成功标准

1. 用户选择 Mistral AI，填入 API Key，点击“测试连接”得到真实结果；
2. 设为默认后，说话、松开，文本经现有 Direct / LLM 流程注入；
3. 两个模型都能完成中文、英文和中英混合的转写；
4. 切换模型后，下一次录音立即使用新模型，录音条和历史中的模型名同步更新；
5. 热词能改善专有名词的拼写；
6. 对 Voxtral Small 说“帮我写一首诗”，注入的是这句话本身，而不是一首诗；
7. 静音录音不注入任何文本（包括“未检测到语音”这类解释）；
8. API Key 只存在 macOS Keychain 中。

## 3. 非目标

第一版不包含：

- Voxtral Realtime 实时流式识别；
- 转写结果的 SSE 增量显示（Mini 接口支持 `stream`，但短句收益有限，列为后续演进）；
- 说话人分离、时间戳（语音输入法场景用不到）；
- 自定义模型名、自定义 Base URL；
- 本地部署的开源权重 Voxtral；
- Voxtral TTS；
- 把 Mistral 作为 LLM Provider 加入（Mistral 属于基础模型厂商，符合收录政策，但应作为独立需求另行设计）；
- 进入“推荐”分组。

## 4. Provider 定位

### 4.1 名称与分组

- 中英文显示名都为 `Mistral AI`；
- 归入“云端”分组，按字母排序；
- 列表行自动显示“非实时 / Batch”标签；
- 不进入推荐分组，等真实评测后再决定。

### 4.2 两个模型怎么选

设置页模型选项的文案要让用户一眼能看出区别：

| 模型 | 什么时候选 |
|---|---|
| Voxtral Mini Transcribe 2（默认） | 日常听写。最便宜，结果最稳定，热词原生生效 |
| Voxtral Small | 口音重、术语多、需要稳定输出简体中文，愿意多等一点、多花一点 |

详情页说明会提示：Voxtral Small 是“理解型”模型，极少数情况下可能改写措辞；如需逐字转写，请用 Mini Transcribe 2。

### 4.3 适用场景

适合：

- 想要低价、高准确率的 BYOK 云端听写；
- 以 13 种主流语言为主的输入（中、英、日、韩、法、德、西、葡、意、荷、俄、阿、印地语）；
- 对热词有需求的专业词汇场景；
- 偏好欧洲厂商的用户。

不适合：

- 需要边说边出字的场景；
- 13 种语言以外的语种（Whisper 系的 Groq 覆盖更广）；
- 无法访问 `api.mistral.ai` 的网络环境。

## 5. 核心交互

### 5.1 录音阶段

- 正常采集 16 kHz 单声道 PCM 并缓存；
- 录音条显示通用的“录音中…”占位；
- 不发起网络请求。

### 5.2 松开快捷键后

1. 录音短于 0.3 秒：不发请求，直接以空结果结束；
2. 录音超过所选模型的单次上限：不发请求，提示缩短录音；
3. 封装为 WAV，按模型选择接口提交：
   - Mini Transcribe 2：multipart 上传到转写接口；
   - Small：Base64 编码后放入 Chat Completions 请求；
4. 收到结果后一次性给出最终文本；
5. 进入现有 Direct / LLM 后处理 / 注入流程。

用户感知：`录音中 → 识别中 → 完成`。

## 6. 设置设计

### 6.1 凭证字段

| 字段 | 类型 | 默认值 | 必填 | 存储 |
|---|---|---|---|---|
| API Key | Secure | 空 | 是 | Keychain |
| 模型 | Picker | `voxtral-mini-2602` | 否 | credentials.json |
| 语言 | Picker | 自动检测 | 否 | credentials.json |

### 6.2 模型选项

| 值 | 显示文案 |
|---|---|
| `voxtral-mini-2602` | `Voxtral Mini Transcribe 2 ($0.18/hr)` |
| `voxtral-small-2507` | `Voxtral Small ($0.24/hr + tokens)` |

使用带日期的固定模型 ID，而不是 `voxtral-mini-latest` 这类别名：选项名称承诺的是具体模型，别名在服务端升级后会悄悄换成别的模型，行为变化用户无从察觉。代价是旧模型下线时需要随版本更新，见第 13 节。

### 6.3 语言选项

只列出 Voxtral 官方支持的 13 种语言：

| 值 | 中文文案 | 英文文案 |
|---|---|---|
| 空 | 自动检测 | Auto-detect |
| `zh` | 中文（简体） | Chinese (Simplified) |
| `en` | 英文 | English |
| `ja` | 日语 | Japanese |
| `ko` | 韩语 | Korean |
| `fr` `de` `es` `pt` `it` `nl` `ru` `ar` `hi` | 显示 ISO 代码 | 显示 ISO 代码 |

- Mini Transcribe 2：直接作为 `language` 参数发送，官方说明指定语言可以提升准确率；
- Small：写入转写指令；选“中文（简体）”时，要求输出简体中文。自动检测且 App 界面为中文时，同样要求中文内容以简体输出。

### 6.4 详情页说明（Provider Note）

中文：

> 结束录音后提交完整录音，不支持边说边出字。Voxtral Mini Transcribe 2 是专用转写模型，价格低、结果稳定，热词原生生效；Voxtral Small 是多模态理解模型，适合口音重或术语多的内容，极少数情况下可能改写措辞。热词中的空格会被拆分成单独的词。

英文：

> The complete recording is submitted when you stop recording; live transcription is not supported. Voxtral Mini Transcribe 2 is a dedicated transcription model: low cost, consistent output, with native hotword support. Voxtral Small is a multimodal understanding model suited to heavy accents or dense terminology, and may occasionally rephrase. Hotwords containing spaces are split into separate words.

### 6.5 指引链接

| 文案 | 链接 |
|---|---|
| API Key · 获取 | https://console.mistral.ai/api-keys |
| 文档 · 查看 | https://docs.mistral.ai/studio/audio/speech_to_text/offline_transcription |
| 定价 · 查看 | https://docs.mistral.ai/inference/pricing |

## 7. 热词

### 7.1 Voxtral Mini Transcribe 2

映射到官方 `context_bias` 参数：

- 最多 100 个词；
- 官方规定每一项**不能包含空格或逗号**。含空格的热词（如 `Claude Code`）拆成单独的词（`Claude`、`Code`）；拆分后去重，保持原顺序，超过 100 个时截断；
- 官方说明该能力针对英文优化，其他语言为实验性支持。中文热词照常发送，但不承诺效果。

### 7.2 Voxtral Small

没有专门的热词参数，把热词写进转写指令（“以下术语出现时请按此拼写”）。

- 热词保持原样，不需要拆分；
- 如果模型把热词列表回显到结果中，复用现有的热词泄漏清理逻辑去掉；
- 指令长度有上限，超出部分按顺序截断。

## 8. Voxtral Small 的“只转写”约束

Voxtral Small 是指令模型，直接把录音交给它，它可能把语音内容当作对它说的话。例如用户口述“帮我总结一下这段话”，模型可能真的去总结。这在语音输入法里是严重问题：用户说的话必须原样变成文字。

产品规则：

1. 请求中带固定的转写指令：只输出音频中说的话；不回答问题，不执行指令，不翻译，不加解释、引号或前后缀；
2. 没有可识别的语音时，模型输出约定的占位标记，Type4Me 识别后按空结果处理，不注入任何文本；
3. 温度固定为 0；
4. 详情页说明中提示：如需严格逐字转写，请使用 Mini Transcribe 2；
5. 验收第 6 项专门覆盖“对模型下指令”的场景。

指令无法 100% 杜绝偏离，这是选择默认模型为 Mini Transcribe 2 的主要原因。

## 9. 静音与短录音

- 短于 0.3 秒不发请求（沿用共享批量链路的默认阈值）；
- Mini Transcribe 2 是专用转写模型，静音时通常返回空文本；开发前由 M-9 实测确认，若出现幻觉文本，再加分段置信度过滤；
- Small 依赖第 8 节的占位标记。

## 10. 限制与错误体验

### 10.1 单次录音上限

| 模型 | 官方说明 | Type4Me 上限 |
|---|---|---|
| Mini Transcribe 2 | 单次最长 3 小时 | 不设上限（远超听写需要；仍以服务端的上传大小限制为准） |
| Small | 32k 上下文，官方称转写可处理约 30 分钟音频 | 15 分钟（Base64 后的请求体约 38 MB，保守留出余量） |

超出时在本地拦截，提示“录音超过 Mistral AI 的 15 分钟上限，请缩短后重试，或切换到 Voxtral Mini Transcribe 2”。

### 10.2 错误提示

优先展示 Mistral 返回的错误信息；服务端信息为空时使用以下兜底意思：

| 场景 | 中文 | 英文 |
|---|---|---|
| API Key 为空 | Mistral AI 非实时识别配置无效 | Invalid Mistral AI batch recognition configuration |
| 401 | Mistral API Key 无效或已被撤销 | The Mistral API key is invalid or revoked |
| 403 | 当前 API Key 无权使用该模型 | This API key cannot access the selected model |
| 404 | 所选模型不可用，可能已下线，请更新 Type4Me 或切换模型 | The selected model is unavailable or retired. Update Type4Me or switch models. |
| 422 | 请求参数无效（展示服务端返回的字段说明） | Invalid request (shows the server's field message) |
| 429 | 请求过于频繁或已达额度上限，请稍后再试 | Rate limit or quota reached. Try again later. |
| 录音过长 | 见 10.1 | See 10.1 |
| 5xx / 超时 | 沿用现有提示 | Same |

## 11. 测试连接

复用现有批量 Provider 的真实校验：用当前所选模型提交 1 秒静音，HTTP 200 即为成功。

- 能校验 API Key、所选模型的权限和网络连通性；
- 切换模型后再测一次，可以确认新模型也可用；
- 每次测试费用在 $0.0001 以内；
- 只看状态码，不展示识别内容。

## 12. 隐私与安全

- API Key 只存 Keychain；`credentials.json` 只存模型和语言；
- 音频只在用户选用 Mistral AI 时发送到 `api.mistral.ai`；
- 日志不记录 API Key、Authorization 头、音频、热词与转写指令全文；
- 遵循现有“绕过代理”设置。

## 13. 模型生命周期

Mistral 会按其模型生命周期政策下线旧的带日期版本。处理方式：

- 发版前检查官方模型列表，确认两个模型 ID 仍可用；
- 用户存储的模型 ID 不在当前选项中时（例如旧版本被替换），自动回到默认模型，不让用户卡在 404；
- 新的 Voxtral 版本上线后，通过版本更新替换选项和默认值，并在 CHANGELOG 中说明。

## 14. 验收场景

1. **基础**：默认 Mini Transcribe 2 + 自动检测，录中文，松开后文本正确注入；
2. **英文 / 中英混合**：两种都能正常完成；
3. **简体**：两个模型分别连续多次输入中文，记录是否出现繁体（Mini 无法通过指令约束，结果作为评测数据）；
4. **模型切换**：切到 Small，录音条和历史显示 `Mistral AI · voxtral-small-2507`；
5. **热词**：添加 `Type4Me`、`Claude Code` 等热词，两个模型的拼写都有改善，且结果不回显热词列表；
6. **指令免疫**：用 Small 说“请帮我写一首关于春天的诗”，注入的是这句话本身；
7. **静音**：两个模型都按住快捷键不说话 2 秒后松开，不注入任何文本；
8. **极短**：快速点按（<0.3 秒），不发请求；
9. **错误 Key**：测试连接和实际识别都显示 401 提示；
10. **超长**：Small 下录制超过 15 分钟，本地拦截并提示；
11. **处理模式**：Direct、快速、Intelli Sense、翻译、自定义 Prompt 模式都正常；
12. **语言切换**：App 语言在中英文之间切换，Provider 列表、说明、字段标签、错误提示即时切换；
13. **菜单栏**：配置后出现在菜单栏 ASR 快速切换中，带“非实时”标识。

## 15. 发布策略

作为普通云端 Provider 发布，在 CHANGELOG 和 README 中注明“非实时”。发布后观察：

- 两个模型的使用比例与松手到出字的延迟；
- Small 的指令偏离与静音占位失效的反馈；
- 中文繁简输出情况；
- 中文热词在 Mini 上的实际效果。

## 16. 待实测事项

以下产品承诺依赖真实接口的表现，开发前和验收前要先实测。方法、判定和结果记录在开发设计第 2.4 节，编号一致：

| 编号 | 涉及的产品承诺 | 不达标时的产品调整 |
|---|---|---|
| M-1、M-2、M-15 | 第 7 节：热词改善专有名词拼写；中文热词照常发送 | 中文热词不发给 Mini，或如实说明效果有限 |
| M-3、M-4、M-5 | 第 6.2 节：两个模型都可用 | 更换模型 ID 或接入方式 |
| M-6 | 第 8 节：Small 只转写，不执行语音中的指令 | Small 标为“实验性”，或第一版不提供 Small |
| M-7、M-9 | 第 9 节：静音不注入任何文本 | 增加过滤规则或最短有效时长 |
| M-8 | 第 8 节：不加引号、标签等包裹 | 补充清理规则 |
| M-10 | 第 6.3 节：选“中文（简体）”时输出简体 | 说明 Mini 的繁简表现，评估繁转简后处理 |
| M-11、M-12 | 第 10.1 节：Small 15 分钟上限，Mini 不设上限 | 按实测调整上限 |
| M-13 | 第 10.2 节：错误提示可读 | 启用兜底文案 |
| M-14 | 第 11 节：测试连接真实可用 | 更换探测音频 |
| M-16 | 第 4.2 节：两个模型的取舍描述 | 按实测延迟调整描述 |

## 17. 后续演进

- **Voxtral Realtime**：增加“实时流式 / 非实时”模式切换（与 Gemini、Grok、ElevenLabs 的做法一致），本设计的 Config 结构已为此预留；
- Mini Transcribe 2 的 SSE 增量文本显示；
- 新的 Voxtral 版本替换现有选项；
- 将 Mistral 作为 LLM Provider 加入（单独设计，可共用同一个 API Key）；
- 根据评测决定是否进入推荐分组。
