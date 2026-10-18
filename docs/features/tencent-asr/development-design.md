# 腾讯云 ASR（中英大模型 2.0）开发设计

> 文档类型：开发设计
> 文档状态：当前有效（设计完成，待实现）
> 设计日期：2026-10-17
> 最后校验：2026-10-18
> 上游文档：`docs/features/tencent-asr/product-design.md`
> 官方 API：实时语音识别 V2 https://cloud.tencent.com/document/product/1093/131127 ；CreateRecTask https://cloud.tencent.com/document/product/1093/37823 ；DescribeTaskStatus https://cloud.tencent.com/document/api/1093/37822

## 1. 设计摘要

腾讯云已经在 `ASRProvider` 枚举和 `TencentASRConfig` 中存在，但注册表里 `createClient: nil`，所以在设置中不可见。本次把它变成双模式 Provider：

| 模式 | 接口 | 鉴权 | Client |
|---|---|---|---|
| 实时流式（默认） | `wss://asr.cloud.tencent.com/asr/v2/<appid>` | URL 参数 + HMAC-SHA1 签名 | 新增 `TencentASRClient`（actor） |
| 非实时 | API 3.0 `CreateRecTask` + `DescribeTaskStatus` 轮询（`asr.tencentcloudapi.com`） | TC3-HMAC-SHA256 | `BufferedBatchASRClient` + 新增 `TencentRecTaskTranscriber` |

设计决定：

1. **引擎固定为 `16k_zh_en_2.0`**，作为 Config 的静态常量，不出现在凭证字段里；
2. **非实时走异步任务**：`16k_zh_en_2.0` 不支持极速版和一句话识别，只能用 `CreateRecTask` 提交后轮询；
3. **非实时复用 `BufferedBatchASRClient`**：给 `BatchASRTranscriber` 增加一个可覆盖的 `transcribe(...)` 入口（默认走现有的单次 HTTP 流程），腾讯云覆盖为“提交 + 轮询”。录音缓冲、最短录音、事件发射、取消、测试连接都继续共用；
4. **签名算法独立成纯函数**（`TencentCloudSigner`），用官方文档的示例向量做单元测试；
5. **不改 `SpeechRecognizer` 协议，不改音频采集格式**：`AudioCaptureEngine` 本来就每 200 ms 发出 6400 字节的 16 kHz PCM，正好是腾讯云建议的发送节奏。

## 2. 协议依据与待核实项

### 2.1 实时模式的协议依据：两份文档 + 实测

腾讯云有两份实时语音识别文档，地址都是 `wss://asr.cloud.tencent.com/asr/v2/<appid>`，签名算法相同，但写的参数和结果结构不同。2026-10-18 的实测（T-1）发现，`16k_zh_en_2.0` 实际返回的是**旧版文档**的结构：

| | 实时语音识别（WebSocket）`1093/48982` | 实时语音识别 V2（WebSocket）`1093/131127` | 实测（2026-10-18，`16k_zh_en_2.0`） |
|---|---|---|---|
| 适用引擎 | 1.0 大模型、通用引擎、`Hy-ASR-3.0-preview` | `16k_zh_en_2.0`、`16k_zh_en_speaker_2.0` | `16k_zh_en_2.0`、`16k_zh_en_speaker_2.0` 都被接受；不存在的引擎名返回 4001 |
| 结果字段 | `result` 对象：`index`、`slice_type`（0/1/2）、`voice_text_str` | `sentences`：`sentence_id`、`sentence_type`（0 未定稿 / 1 已定稿）、`sentence` | **`result` 对象**：`index`、`slice_type`、`voice_text_str`，另有 `speaker_info`、`emotion_type`、`speech_speed`；没有 `sentences` |
| 断句相关参数 | `vad_silence_time`、`max_speak_time` | `sentence_strategy` | 发送 `sentence_strategy=0` 不报错 |
| 其他差异 | 有 `filter_punc`、`word_info` | 没有 `filter_punc`、`word_info` | 未发送这两个参数 |
| 默认并发 | 200 路 | 50 路 | 未测 |

设计结论：

- **参数**按 V2 文档发送（第 7.1 节），实测全部被接受；
- **结果解码同时支持两种结构**（第 7.3 节）：以实测到的 `result` 结构为主，同时接受 V2 文档描述的 `sentences` 结构，防止腾讯云日后切换格式时无法解析；
- V2 文档明确列出该引擎支持 `hotword_list`、`needvad`、`convert_num_mode`、`filter_dirty`、`filter_modal`，实测均不报错。

### 2.2 实测清单

本节是腾讯云所有待实测内容的唯一来源，但不包括已经由 V2 文档确认的事项（第 2.1 节）。本文其他地方提到“以实测为准”时，都引用清单编号（T-1、T-2……）。设计按“当前假设”一栏实现；实测结果与假设不同时，按“结果对设计的影响”一栏修改代码和文档。清单中没有阻塞整体方案的项目。

#### 执行约定

- **时机**：A 级在编写对应代码之前完成，B 级在交给用户验收之前完成，C 级在发布后持续观察；
- **凭证**：使用用户提供的、仅授权语音识别的子账号 SecretId / SecretKey 与 AppID。凭证不写入仓库、脚本和日志；
- **工具**：用一次性脚本（需要实现两套签名，可以先写 `TencentCloudSigner` 并用它驱动脚本），放在临时目录，不提交；
- **测试音频**：统一使用合成或专门录制的样本，不使用用户的真实语音。样本集：中文短句、英文短句、中英混合句、带方言口音的普通话、含专有名词的句子、多次停顿的段落、连续说话 90 秒的长段落、2 秒静音、5 秒键盘噪声、1 秒 / 2 分钟 / 2.5 分钟长度的音频。全部为 16 kHz 单声道 16-bit PCM / WAV。实时测试按 200 ms 一包、1:1 速率发送；
- **夹具**：脱敏后的响应存到 `Type4MeTests/Fixtures/tencent/`，文件名带编号（如 `T-1-v2-interim-confirmed.jsonl`）；实时消息按到达顺序每行一条；
- **记录**：每完成一项，在“实测记录”表中填写日期、结论、夹具路径和对设计的改动，并把状态改为“已确认”或“已调整”；
- **费用**：按秒计费，全部实测约 20 分钟音频，通常落在每月免费额度内（实时 5 小时、录音文件 10 小时）。

#### 实时模式（V2 WebSocket）

| 编号 | 级别 | 待确认内容 | 当前假设（设计按此实现） | 实测方法 | 结果对设计的影响 | 状态 |
|---|---|---|---|---|---|---|
| T-1 | A | `sentences` 是数组还是单个对象 | 两种都可能，解码器都接受 | 录制正常样本的完整消息流 | 只出现一种时保留双解码，夹具锁定实际形态 | 已调整 |
| T-2 | A | 每条消息带的是变化的句子，还是迄今为止的全部句子 | 未知；按 `sentence_id` 覆盖写入，两种情况结果一致 | 多次停顿的段落，检查每条消息中的句子集合 | 无论哪种，状态机不变；夹具锁定实际行为 | 已确认 |
| T-3 | A | 同一句从未定稿到定稿是否沿用同一个 `sentence_id` | 沿用同一个 id | 同 T-2，跟踪每个 id 的 `sentence_type` 变化 | 不沿用：改为“新的定稿句替换掉此前所有未定稿句”的映射，并更新第 7.3.2 节与测试 | 已确认 |
| T-4 | B | 热词长度边界与本地过滤是否符合官方限制 | 最多 30 个字符且最多 10 个汉字；含空格或超出任一上限的热词跳过 | 验证 10 / 11 个汉字、30 / 31 个 ASCII 字符及中英混合边界；经过本地过滤后发送，确认合法词保留、非法词未进入请求 | 合法边界仍被拒绝：记录响应并收紧过滤规则；不放宽官方上限，同步第 8、13.5 节与产品文档第 7 节 | 已确认 |
| T-5 | B | 热词在 2.0 引擎上是否生效 | 能改善专有名词识别 | 专有名词样本，分别带和不带热词 | 无改善：在产品文档第 7 节如实说明 | 已调整 |
| T-6 | B | `needvad=1` + `sentence_strategy=0` 在 90 秒连续说话下的断句与完整性 | 自动断句，不丢字、不重复 | 90 秒长段落、多次停顿的段落 | 丢字或断句异常：调整 `sentence_strategy` 或 `needvad`，同步产品文档第 9 节 | 已确认 |
| T-7 | A | 欠费、资源包用尽等错误在握手时返回，还是在收到音频后才返回 | 可能在收到音频后返回，所以测试连接要发静音并等待 | 用余额为零或未开通的账号建立连接，记录错误出现的时机 | 握手即返回：测试连接只需握手，缩短等待窗口；音频后返回：按实测时间设置窗口（第 7.5 节） | 部分确认 |
| T-8 | B | 海外代理下的 6001 表现，以及开启“ASR 绕过代理”后是否恢复 | 返回 6001；绕过代理后恢复 | 开启海外代理分别测试两种模式 | 非实时模式的表现不同：补充对应错误映射 | 未测 |
| T-9 | C | 首字延迟与准确率 | 与火山、百炼相当 | 中文、中英混合、方言样本各 5 次 | 只作为发布后的评测数据 | 已确认 |

#### 非实时模式（CreateRecTask）

| 编号 | 级别 | 待确认内容 | 当前假设（设计按此实现） | 实测方法 | 结果对设计的影响 | 状态 |
|---|---|---|---|---|---|---|
| T-10 | A | 2.0 引擎是否接受 `HotwordList`、`ConvertNumMode`、`FilterDirty`、`FilterModal`、`FilterPunc` | 接受 | 逐个参数单独发送 | 不接受的参数不发送；`HotwordList` 不接受时，非实时模式不发送热词，并更新产品文档第 7 节 | 已确认 |
| T-11 | B | 5 MB 上限针对原始音频还是 Base64 字符串 | 2 分钟 WAV（原始约 3.8 MB，Base64 约 5.1 MB）可以提交 | 提交 2 分钟与 2.5 分钟的音频 | 2 分钟失败：改为 110 秒；2.5 分钟成功：放宽到 150 秒（第 6.3 节） | 已调整 |
| T-12 | B | 短音频任务的完成时间 | 5–30 秒音频在几秒内完成 | 5、30、120 秒音频各 5 次，记录提交到成功的耗时与轮询次数 | 调整轮询节奏（第 6.4 节）与产品文档第 5.2 节的描述 | 已确认 |
| T-13 | A | `Result` 的时间戳前缀与多行格式 | `[0:1.640,0:3.920]  文本` 每句一行 | 多句样本 | 调整解析正则（第 6.6 节） | 已确认 |
| T-14 | A | 测试连接用的 1 秒静音任务能否成功完成 | 任务成功，`Result` 为空 | 提交 1 秒静音并轮询 | 任务失败：改用 1 秒合成语音作为探测音频 | 已确认 |
| T-15 | B | API 3.0 计费、开通、权限类错误的实际 `Error.Code` | 与第 6.5 节的前缀映射一致 | 未开通账号、余额为零账号、未授权语音识别的子账号各调用一次 | 补充错误码映射与产品文档第 10 节的提示 | 部分确认 |

#### 实测记录

| 编号 | 日期 | 结论 | 夹具 | 对设计的改动 |
|---|---|---|---|---|
| T-1 | 2026-10-18 | **实际返回的不是 V2 文档写的 `sentences`，而是旧版文档（48982）的 `result` 对象**：`{"code":0,"message":"success","voice_id":…,"message_id":…,"result":{"slice_type":0|1|2,"index":0,"start_time":0,"end_time":500,"voice_text_str":"我们这","word_size":0,"word_list":[],"speaker_info":null,"emotion_type":null}}`，定稿消息另有 `speech_speed`。`16k_zh_en_speaker_2.0` 同样如此。引擎确实生效：不存在的引擎名在握手时返回 4001 `Not support [engine_model_type: …]` | `T-1-ws-result-format.jsonl`、`T-1-ws-speaker-engine.jsonl` | 第 2.1、7.3 节改为同时支持两种格式，以实测的 `result` 格式为主；第 13.3 节测试同步修改 |
| T-2 | 2026-10-18 | 每条消息只带**当前这一句**（增量推送），不带之前已定稿的句子 | 同 T-1 | 无；按编号覆盖写入的状态机两种情况都正确 |
| T-3 | 2026-10-18 | 同一句从 `slice_type` 0 → 1 → 2 始终使用同一个 `index`；下一句 `index` 加 1 并从 `slice_type` 0 开始。定稿前文本会被改写（如 `今天下午3点，在会议室` → `今天下午3点在会议室讨论项目进度。`），定稿后不再变化 | 同 T-1 | 无 |
| T-4 | 2026-10-18 | 两种模式下，含空格、31 个 ASCII 字符、11 个汉字、10 个汉字 + 21 个 ASCII 字符的热词**都不报错**（服务端静默接受，推测直接忽略） | `T-4-hotword-bounds.jsonl` | 无；本地过滤仍按官方上限执行，目的是不发送会被忽略的热词，而不是避免请求失败 |
| T-5 | 2026-10-18 | **热词在两种模式下都没有明显效果**：`Type4Me|10`、`Type4Me|11`（超级热词）均未改善（实时仍为 `type4么`，非实时仍为 `type 4 ma`）；英文样本中 `Groq|10` 未把 `Grog` 纠正过来。唯一变化是含空格的 `Claude Code|10/11` 让输出从 `claudecode` 变为 `claude codede` / `Claude Code de`（该热词本身会被本地过滤跳过）。结论仅基于合成语音样本 | `T-5-hotword-effect-*.jsonl` | 继续发送热词（无副作用），但产品文档第 7 节不承诺效果，如实说明“2.0 引擎热词效果有限” |
| T-6 | 2026-10-18 | 90 秒连续语音被分成 14 句，`index` 0–13 连续，拼接后与原文一致，无丢字、无重复。`sentence_strategy=0` 下，0.4 秒的停顿不一定断句，单句可长达约 14 秒 | `T-6-ws-90s.jsonl` | 无 |
| T-7 | 2026-10-18 | 签名错误在**握手阶段**即返回 4002（约 0.15 秒）。欠费、资源包用尽等计费类错误没有条件复现（需要余额为零或未开通的账号） | `T-7-ws-4002.jsonl` | 测试连接保持“握手 + 0.5 秒静音 + 等待窗口”，窗口 1.5 秒；计费类错误的时机待有条件时补测 |
| T-8 | 2026-10-18 | 没有海外代理环境，未测 | — | 待补测 |
| T-9 | 2026-10-18 | 开始发送音频后约 0.45 秒出现第一个字；发送结束消息后约 80 毫秒收到最终结果。30 秒样本识别准确（`三点` 被转换为 `3点`） | — | 仅作评测数据 |
| T-10 | 2026-10-18 | `HotwordList`、`ConvertNumMode`、`FilterDirty`、`FilterModal`、`FilterPunc` 单独发送和同时发送都被接受，任务成功 | `T-10-params-*.json` | 无 |
| T-11 | 2026-10-18 | 2.5 分钟（原始 4.8 MB，Base64 6.4 MB）**提交成功**；2 分 45 秒（原始 5,280,044 字节）被拒绝：`InvalidParameter`，`Data: length should in range [0, 5242880], but got 5280044`。上限针对**原始音频**，为 5,242,880 字节（约 163 秒） | `T-11-over-limit.json` | 第 6.3 节 `maxDuration` 改为 150 秒，同步产品文档第 6.3、9 节 |
| T-12 | 2026-10-18 | 从提交到成功：5 秒音频约 1.3–2.1 秒（1–2 次查询）；30 秒约 2.8–3.7 秒（2–3 次）；120 秒约 4.4–5.9 秒（3–4 次）；1 秒静音约 1.3 秒 | — | 轮询节奏不变；产品文档第 5.2 节改为“短句约 2 秒，2 分钟录音约 5 秒” |
| T-13 | 2026-10-18 | `Result` 为 `[0:0.000,0:14.440]  文本
` 多行，每行可能包含**多句话**（按语义段落而非句子分行），时间戳后为两个空格 | `T-13-result-multiline.json` | 无；第 6.6 节的正则适用 |
| T-14 | 2026-10-18 | 1 秒静音任务成功，`StatusStr` 为 `success`，`Result` 为空字符串 | `T-14-silence.json` | 无 |
| T-15 | 2026-10-18 | 已确认（HTTP 均为 200，错误在 `Response.Error`）：SecretKey 错误 → `AuthFailure.SignatureFailure`；SecretId 不存在 → `AuthFailure.SecretIdNotFound`；任务不存在 → `FailedOperation.NoSuchTask`（Message 为空）；超过 5 MB → `InvalidParameter`。计费类、权限不足类错误码没有条件复现 | `T-15-api-errors.json` | 第 6.5 节补充已确认的错误码；其余待有条件时补测 |

说明：

- 本轮实测共约 60 次非实时任务、20 次实时会话。测试音频为 macOS 语音合成（Tingting、Samantha）生成的样本和程序生成的静音、噪声，没有方言样本，也不含真实人声；
- 实时测试使用 Swift `URLSessionWebSocketTask`，与 App 的网络实现相同；签名用的是按第 5 节写的独立实现，两套签名一次通过，说明第 5 节的算法描述正确；
- “夹具”一栏是实现时要导出的文件名。原始响应目前只保存在本地临时目录，实现时脱敏（去掉 `voice_id`、`RequestId`、`TaskId`）后放入 `Type4MeTests/Fixtures/tencent/`；
- **附带发现**：用这对仅用于语音识别的子账号密钥调用 CAM 的 `GetUserAppId`（`cam.tencentcloudapi.com`，版本 `2019-01-16`）成功拿到了 AppID。这意味着 AppID 可以在测试连接时自动获取，用户不必手动填写。是否采用属于产品决策，暂列为后续演进（产品文档第 16 节），本设计仍按手动填写实现。

V2 文档对发送节奏有两处说法（握手部分写 200 ms / 6400 字节，识别部分写 40 ms / 1280 字节），两者都是 1:1 实时速率。Type4Me 每 200 ms 发送 6400 字节，符合要求，不列入实测。

## 3. 改动清单

### 3.1 新增文件

| 文件 | 内容 |
|---|---|
| `Type4Me/Protocol/TencentCloudSigner.swift` | WebSocket HMAC-SHA1 签名、TC3-HMAC-SHA256 签名（纯函数） |
| `Type4Me/Protocol/TencentASRProtocol.swift` | 实时：URL 构造、响应解析、结束消息、错误码映射；热词格式化 |
| `Type4Me/Protocol/TencentRecTaskProtocol.swift` | 非实时：`TencentRecTaskTranscriber`，请求构造、响应解析、轮询 |
| `Type4Me/ASR/TencentASRClient.swift` | 实时 WebSocket Client（actor） |
| `Type4Me/Resources/Icons/tencent.png` | 品牌图标 |
| `Type4MeTests/TencentCloudSignerTests.swift` | 签名测试 |
| `Type4MeTests/TencentASRProtocolTests.swift` | 实时协议测试 |
| `Type4MeTests/TencentRecTaskProtocolTests.swift` | 非实时协议与轮询测试 |
| `Type4MeTests/TencentASRConfigTests.swift` | Config 测试 |

### 3.2 修改文件

| 文件 | 改动 |
|---|---|
| `Type4Me/ASR/Providers/TencentASRConfig.swift` | 采用 `ASRRecognitionModeConfigurable`；增加 `recognitionMode` 字段、引擎常量、字段提示、去空白校验 |
| `Type4Me/ASR/BufferedBatchASRClient.swift` | `BatchASRTranscriber` 增加 `transcribe(...)` 定制点；时长预检提取为独立函数 |
| `Type4Me/ASR/ASRProviderRegistry.swift` | `.tencent` 注册实时 Client、批量变体与两个校验器 |
| `Type4Me/Session/RecognitionSession.swift` | `asrModelLabel` 增加 `.tencent` 分支，显示引擎名 |
| `Type4Me/UI/AppState.swift` | `RecordingDisplayMetadata.current` 增加 `.tencent` 分支 |
| `Type4Me/UI/Settings/ASRProviderDetailView.swift` | 指引链接、Provider Note（按模式区分） |
| `Type4Me/UI/Settings/ModelSettingsState.swift` | SF Symbol 兜底图标 `cloud.bolt.fill` |
| `Type4Me/UI/Settings/BrandIconView.swift` | `.tencent → "tencent"`（彩色标识，不加入深色反色列表） |
| `Type4MeTests/ASRProviderRegistryTests.swift` | `.tencent` 加入双模式 Provider 断言列表 |
| `Type4MeTests/ASRRecognitionModeTests.swift` | 两种模式下字段 key 一致 |
| `CLAUDE.md` / `AGENTS.md`、`README.md`、`README.en.md`、`CHANGELOG.md`、`docs/README.md` | 把腾讯云从“Config only”移到“Fully implemented”，补充双模式列表与 Key Files |

不需要改动：`KeychainService`（存储键 `tf_asr_tencent` 自动生成，`secretKey` 已是 secure 字段）、`MenuBarControlCenter`、`ModelProviderListView`（按 capability 自动处理）。

## 4. 数据模型

### 4.1 `TencentASRConfig`

```swift
struct TencentASRConfig: ASRRecognitionModeConfigurable, Sendable {
    static let provider = ASRProvider.tencent
    static var displayName: String { L("腾讯云", "Tencent Cloud") }

    /// Chinese-English large model 2.0; the only engine offered in the first release.
    static let engineModelType = "16k_zh_en_2.0"

    static var credentialFields: [CredentialField] {[
        ASRRecognitionMode.credentialField,
        CredentialField(key: "secretId", label: "SecretId", placeholder: "AKID...",
                        isSecure: false, isOptional: false, defaultValue: "",
                        hint: L("在“访问管理 → API 密钥管理”中创建，建议使用仅授权语音识别的子账号密钥",
                                "Create one under CAM → API Keys. A sub-account key limited to ASR is recommended.")),
        CredentialField(key: "secretKey", label: "SecretKey", placeholder: L("密钥", "Secret"),
                        isSecure: true, isOptional: false, defaultValue: ""),
        CredentialField(key: "appId", label: "AppID", placeholder: "1250000000",
                        isSecure: false, isOptional: false, defaultValue: "",
                        hint: L("在“账号信息”页面查看，为纯数字", "Shown on the Account Info page; digits only.")),
    ]}

    let recognitionMode: ASRRecognitionMode
    let secretId: String
    let secretKey: String
    let appId: String
    // init?(credentials:)：三个字段都去首尾空白，任一为空 → nil；appId 必须全为数字 → 否则 nil
    // toCredentials()：recognitionMode + 三个字段
    // isValid：三个字段都非空
}
```

- 字段 key 不变，`recognitionMode` 插在首位，与其他双模式 Provider 一致（`ASRProviderRegistryTests` 会断言首字段为模式字段）；
- 现有 init 没有去空白。用户从控制台复制密钥时常带空格或换行，签名会失败且很难排查，所以这次加上；
- AppID 在 WebSocket URL 路径中使用，限制为纯数字，防止拼出非法 URL；
- 不需要迁移：腾讯云此前 `createClient == nil`，`availableASRProviders()` 会把它过滤掉，用户无法保存凭证。

### 4.2 显示模型名

通用的模型标签路径读取 `credentials["model"]` 等字段，腾讯云没有这些字段，会只显示“腾讯云”。参照 Grok 的写法增加分支：

```swift
if provider == .tencent {
    return "\(providerName) · \(TencentASRConfig.engineModelType)"
}
```

`RecognitionSession.asrModelLabel` 和 `AppState.RecordingDisplayMetadata.current` 两处都要加。

## 5. 签名：`TencentCloudSigner`

全部为纯函数，时间、随机数由调用方传入，便于用固定值测试。HMAC 和 SHA256 使用 CryptoKit（`HMAC<Insecure.SHA1>`、`HMAC<SHA256>`、`SHA256`）。

### 5.1 实时 WebSocket（HMAC-SHA1）

```swift
static func signedWebSocketURL(
    appId: String, secretId: String, secretKey: String,
    parameters: [String: String],      // 业务参数，不含签名相关字段
    timestamp: Int, expiresIn: Int, nonce: Int, voiceId: String
) throws -> URL
```

步骤：

1. 合并业务参数与 `secretid`、`timestamp`、`expired = timestamp + expiresIn`、`nonce`、`voice_id`；
2. 按 key 字典序排序，拼成 `k=v&k=v`（拼接签名原文时**不做** URL 编码，以官方示例为准）；
3. 原文为 `asr.cloud.tencent.com/asr/v2/<appid>?` + 排序后的查询串；
4. `signature = Base64(HMAC-SHA1(secretKey, 原文))`；
5. 构造最终 URL：所有参数值做 URL 编码，`signature` 中的 `+`、`=`、`/` 必须编码。

约束：`expiresIn` 取 24 小时（必须小于 90 天）；`nonce` 为不超过 10 位的正整数；`voice_id` 每次连接重新生成 UUID。

### 5.2 API 3.0（TC3-HMAC-SHA256）

```swift
static func signedAPIRequest(
    action: String, payload: Data,
    secretId: String, secretKey: String, timestamp: Int
) -> URLRequest
```

- 主机 `asr.tencentcloudapi.com`，服务名 `asr`，版本 `2019-06-14`，`POST /`；
- 规范请求：`POST\n/\n\ncontent-type:application/json; charset=utf-8\nhost:asr.tencentcloudapi.com\n\ncontent-type;host\n<hex(SHA256(payload))>`；
- 待签字符串：`TC3-HMAC-SHA256\n<timestamp>\n<date>/asr/tc3_request\n<hex(SHA256(规范请求))>`，`date` 为 timestamp 对应的 **UTC** 日期 `yyyy-MM-dd`；
- 派生密钥：`kDate = HMAC("TC3" + secretKey, date)` → `kService = HMAC(kDate, "asr")` → `kSigning = HMAC(kService, "tc3_request")`；
- 请求头：`Authorization: TC3-HMAC-SHA256 Credential=<secretId>/<date>/asr/tc3_request, SignedHeaders=content-type;host, Signature=<hex>`，以及 `X-TC-Action`、`X-TC-Version`、`X-TC-Timestamp`、`Content-Type`、`Host`；
- ASR 接口不要求 `X-TC-Region`，不发送。

`date` 必须用 UTC 计算，用本地时区会在跨日时段签名失败，测试中要覆盖这一点。

## 6. 非实时：`TencentRecTaskTranscriber`

### 6.1 共享层定制点

```swift
protocol BatchASRTranscriber: Sendable {
    ...
    /// Runs one recognition. The default sends `makeRequest` once and parses the reply;
    /// task-based providers override it to submit and poll.
    func transcribe(
        pcmData: Data, config: any ASRProviderConfig,
        options: ASRRequestOptions, session: URLSession
    ) async throws -> String
}

extension BatchASRTranscriber {
    func transcribe(pcmData: Data, config: any ASRProviderConfig,
                    options: ASRRequestOptions, session: URLSession) async throws -> String {
        try await BatchASRHTTP.sendSingleRequest(pcmData: pcmData, with: self, config: config,
                                                 options: options, session: session)
    }
}
```

- 现有 `BatchASRHTTP.transcribe` 拆成两部分：`checkDuration(...)`（时长预检）和 `sendSingleRequest(...)`（单次请求，即现在的逻辑）；
- `BatchASRHTTP.transcribe` 改为：先 `checkDuration`，再调用 `transcriber.transcribe(...)`；
- 必须在协议体中声明 `transcribe`，扩展里只提供默认实现，这样覆盖实现才会被动态派发；
- 其他 transcriber 行为不变，现有测试应全部通过。

如果 Groq / Mistral 设计中的共享层改动（`minimumDuration`、`maxDuration(for:)`、`suggestsRealtimeFallback`、`tooLongHint`）已经合入，本改动与它们互不冲突，直接叠加。腾讯云是双模式 Provider，`suggestsRealtimeFallback` 使用默认值 `true`。

### 6.2 提交任务：`CreateRecTask`

`makeRequest` 生成签名后的 `CreateRecTask` 请求，payload：

```json
{
  "EngineModelType": "16k_zh_en_2.0",
  "ChannelNum": 1,
  "ResTextFormat": 0,
  "SourceType": 1,
  "Data": "<base64 WAV>",
  "DataLen": <WAV 字节数>,
  "ConvertNumMode": 1,
  "FilterDirty": 0,
  "FilterModal": 0,
  "FilterPunc": 0,
  "HotwordList": "<见第 8 节>"
}
```

- `HotwordList` 为空时不发送；
- `HotwordList`、`ConvertNumMode`、`Filter*` 是否发送，以 T-10 为准；不支持就不发送，使用服务端默认值；
- 音频统一编码为 WAV（`WAVEncoder.encode(pcmData:)`），格式由服务端从文件头识别。

### 6.3 时长上限

```swift
/// CreateRecTask rejects inline audio over 5,242,880 raw bytes (T-11), about 163 s of 16 kHz WAV.
let maxDuration: TimeInterval? = 150
```

T-11 实测：上限针对**原始音频**（WAV 字节数），为 5,242,880 字节；2.5 分钟（4.8 MB）提交成功，2 分 45 秒（5.28 MB）返回 `InvalidParameter`。取 150 秒，为 WAV 头和采集误差留出约 13 秒余量。

### 6.4 轮询：`DescribeTaskStatus`

```swift
/// Short dictation tasks usually finish within seconds; poll fast first, then back off.
static let pollIntervals: [Duration] = [.milliseconds(300), .milliseconds(500), .milliseconds(800)]
static let maxPollInterval: Duration = .seconds(1)
/// Stays under BatchASRHTTP.requestTimeout so the session's own timeout is not hit first.
static let pollDeadline: Duration = .seconds(90)
```

`transcribe` 覆盖实现：

1. 用 `session` 发送 `CreateRecTask`，解析得到 `Response.Data.TaskId`；
2. 循环：等待下一个间隔 → 发送签名后的 `DescribeTaskStatus { "TaskId": id }` → 读取 `Response.Data.Status`：
   - `0`（waiting）/ `1`（in process）：继续轮询；
   - `2`（success）：交给 `parseTranscript` 解析 `Result` 并返回；
   - `3`（failed）：抛出 `requestFailed`，message 为 `ErrorMsg`；
3. 超过 `pollDeadline` 抛出 `TencentASRError.taskTimedOut`；
4. 每次等待前检查 `Task.isCancelled`，等待用 `Task.sleep`。录音被取消时，`BufferedBatchASRClient.disconnect()` 会 `invalidateAndCancel()` 会话，进行中的请求和轮询都会以取消结束，不再继续扣费查询；
5. 查询接口限频 50 次/秒，上述节奏远低于这个限制。

### 6.5 API 3.0 响应与错误

腾讯云 API 3.0 在业务错误时**仍返回 HTTP 200**，错误放在响应体里：

```json
{ "Response": { "Error": { "Code": "AuthFailure.SignatureFailure", "Message": "..." }, "RequestId": "..." } }
```

因此 Create 和 Describe 的响应都要先检查 `Response.Error`，再读取 `Response.Data`。新增 `TencentRecTaskProtocol.apiError(from:) -> (code: String, message: String)?`，并映射到用户提示：

| `Error.Code` 前缀 / 值 | 提示（产品文档第 10 节） |
|---|---|
| `AuthFailure.*` | SecretId 或 SecretKey 无效（`AuthFailure.SignatureExpire` 额外提示检查系统时间） |
| `UnauthorizedOperation.*` | 子账号权限不足（提示为该子账号授权语音识别） |
| `FailedOperation.UserHasNoFreeAmount`、`FailedOperation.ServiceIsolate`、`FailedOperation.UserNotRegistered` 等计费 / 开通类 | 未开通、资源包用尽或欠费（原样带上服务端 message，避免码表遗漏） |
| `InvalidParameter*`、`MissingParameter` | 参数错误，展示服务端 message |
| `RequestLimitExceeded*` | 请求过于频繁 |
| `InternalError*` | 服务暂时不可用 |
| 其他 | 显示 `腾讯云 <Code>：<Message>` |

T-15 已实测确认：`AuthFailure.SignatureFailure`（SecretKey 错误）、`AuthFailure.SecretIdNotFound`（SecretId 不存在）、`FailedOperation.NoSuchTask`（任务不存在，Message 为空，需要使用本地兜底文案）、`InvalidParameter`（如音频超过 5 MB，Message 为 `Data: length should in range [0, 5242880], but got N`）。计费类、权限不足类错误码没有条件复现，以官方错误码文档为准；没有覆盖到的代码走“其他”分支，不会丢失信息。HTTP 状态码非 200 时，沿用现有的 `requestFailed` 处理。

日志可以记录 `RequestId`，便于用户提工单，但不记录请求体。

### 6.6 结果解析

`Result` 为多行文本，每行可能带时间戳前缀，例如 `[0:1.640,0:3.920]  你好。`。

1. 按行拆分；
2. 用正则 `^\s*\[[^\]]*\]\s*` 去掉每行开头的时间戳；
3. 去掉空行，按顺序直接拼接（中文不需要分隔符；英文行尾通常已有空格或标点，拼接后再统一 trim 并把多个空白折叠为一个）；
4. 结果为空则返回空字符串。

具体格式以 T-13 为准，并用真实响应作为测试夹具。

## 7. 实时：`TencentASRClient`

结构参照 `BaiduASRClient`：actor、`URLSessionWebSocketTask`、连接闸门（等待 WebSocket 打开）、接收循环。

### 7.1 连接参数

参数按 V2 文档发送（第 2.1 节），T-1、T-10 实测全部被接受：

| 参数 | 值 | 说明 |
|---|---|---|
| `engine_model_type` | `16k_zh_en_2.0` | V2 文档列出的引擎 |
| `voice_format` | `1` | PCM |
| `needvad` | `1` | 官方建议超过 60 秒的音频开启；听写经常超过 60 秒 |
| `sentence_strategy` | `0` | 默认的语义短句。句子越短，定稿越早，录音条中的文字越稳定 |
| `filter_dirty` / `filter_modal` | `0` | 保持原话 |
| `convert_num_mode` | `1` | 智能数字转换（默认值） |
| `filter_empty_result` | `1` | 默认值，不推送空结果 |
| `hotword_list` | 见第 8 节 | 有热词时发送 |

不发送 V2 中不存在的旧参数：`filter_punc`、`word_info`、`max_speak_time`、`vad_silence_time`。也不发送说话人相关参数（`enable_speaker_context`、`speaker_context_id`），它们只对 `16k_zh_en_speaker_2.0` 有效。

### 7.2 生命周期

1. `connect`：生成签名 URL → 建立 WebSocket → 等待连接打开（5 秒超时）→ **等待服务端握手消息** `{"code":0,...}`（5 秒超时）。握手返回非 0 时立即抛出映射后的错误；成功后发出 `.ready`，启动接收循环；
2. `sendAudio`：直接发送二进制帧。`AudioCaptureEngine` 每 200 ms 发出 6400 字节，正好符合官方节奏；不做额外的缓冲或节流；
3. `endAudio`：发送文本消息 `{"type": "end"}`；
4. 收到 `final == 1` 的消息：发出最终 transcript 与 `.completed`；
5. `disconnect`：取消接收任务、关闭 WebSocket、使会话失效、清空状态。

注意：服务端规定两个音频包间隔不能超过 6 秒，15 秒没有音频会返回 4008。Type4Me 录音过程中持续发送（包括静音），正常使用不会触发；录音暂停或卡顿时触发的错误，按普通错误处理。

### 7.3 结果映射

实测（T-1）返回的消息结构：

```json
{ "code": 0, "message": "success", "voice_id": "...", "message_id": "...",
  "result": { "index": 0, "slice_type": 1, "voice_text_str": "我们这周要把",
              "start_time": 0, "end_time": 1100, "word_size": 0, "word_list": [],
              "speaker_info": null, "emotion_type": null } }
```

- 握手成功：`{"code":0,"message":"success","voice_id":"..."}`，没有 `result`；
- 识别中：每条消息只带**当前这一句**（T-2）；同一句从 `slice_type` 0（开始）→ 1（识别中，文本可能被改写）→ 2（定稿）始终使用同一个 `index`，下一句 `index` 加 1（T-3）；
- 结束：`{"code":0,"final":1,"message":"success"}`，没有 `result`。

V2 文档描述的另一种结构（目前没有实际出现）：

```json
{ "code": 0, "sentences": [ { "sentence": "实时语音识别。", "sentence_id": 1, "sentence_type": 1 } ] }
```

#### 7.3.1 消息解码

两种结构统一解码为同一个中间表示：

```swift
/// One sentence update, normalized from either wire format.
struct TencentSentenceUpdate: Equatable {
    let id: Int          // result.index 或 sentences[].sentence_id
    let text: String     // result.voice_text_str 或 sentences[].sentence
    let isFinal: Bool    // result.slice_type == 2 或 sentences[].sentence_type == 1
}

struct TencentRealtimeMessage {
    let code: Int
    let message: String?
    let voiceId: String?
    let updates: [TencentSentenceUpdate]   // 握手、结束消息为 []
    let isFinal: Bool                      // final == 1
}
```

- 有 `result` 对象时按实测结构解码：`slice_type == 2` 为定稿，`0`、`1` 为未定稿；
- 有 `sentences` 时按 V2 结构解码：数组或单个对象都接受；`sentence_type == 1` 为定稿，其他值为未定稿；
- 两者同时出现时以 `result` 为准，并记录一次日志，提示腾讯云的格式可能已变化；
- 只把明确的定稿值视为定稿，其他值（包括未来可能新增的值）都视为未定稿，避免把临时文本过早定稿；
- `speaker_info`、`emotion_type`、`speech_speed`、时间戳与 `word_list` 不解码，第一版用不到；
- 解码失败的消息记录日志后跳过，不中断会话。只有 `code != 0` 才按错误处理（第 7.4 节）。

#### 7.3.2 状态映射

```swift
struct TencentTranscriptState {
    private var sentences: [Int: String] = [:]   // update.id → 文本
    private var confirmedIDs: Set<Int> = []

    mutating func apply(_ update: TencentSentenceUpdate)
    mutating func markFinal()
    var transcript: RecognitionTranscript { ... }
}
```

- 未定稿更新：用新文本覆盖该 id 的内容（T-3 中定稿前文本会被改写，必须覆盖而不是追加）；
- 定稿更新：覆盖文本，并把该 id 标记为已定稿；
- 已定稿的句子再次收到未定稿更新时，**忽略**这条更新，防止定稿文字回退；
- `RecognitionTranscript`：
  - `confirmedSegments`：已定稿句子，按 id 升序；
  - `partialText`：未定稿句子按 id 升序拼接（实测中最多一句）；
  - `authoritativeText`：两者按 id 顺序拼接；
  - 收到 `final == 1` 时调用 `markFinal()`：把剩余的未定稿句子并入结果，`isFinal = true`；
- 按 id 覆盖写入，而不是简单追加。实测是增量推送（T-2），但即使将来改为每次推送全部句子，结果也一样；同一句重复推送定稿也不会出现重复文字（对应 CLAUDE.md 中“流式 ASR 防重复”的经验）。

### 7.4 错误处理

- 消息中 `code != 0`：映射为 `TencentASRError.server(code:message:)`，按产品文档第 10 节给出提示；发出 `.error` 与 `.completed`；
- 4008 / 4009 等连接类错误：与其他流式 Provider 一致，交给 `RecognitionSession` 现有的中断与恢复流程；
- 已请求结束但连接在 `final` 之前关闭：与 `BaiduASRClient` 一致，按已有文本结束。

### 7.5 测试连接

```swift
static func validateCredentials(config: any ASRProviderConfig, options: ASRRequestOptions) async throws
```

参照 `VolcASRClient.validateCredentials`：`connect`（握手成功）→ 发送 0.5 秒静音 → 在短时间窗口内等待服务端错误（欠费、资源包用尽等错误可能在收到音频后才返回）→ `disconnect`。窗口内没有错误即视为成功。T-7 实测签名错误在握手阶段（约 0.15 秒）即返回 4002；计费类错误的返回时机没有条件复现，因此保留发送静音与等待窗口，窗口取 1.5 秒。

## 8. 热词格式化（两种模式共用）

```swift
static let maxHotwords = 128
static let maxHotwordLength = 30
static let maxHotwordHanCharacters = 10
static let hotwordWeight = 10

static func hotwordList(from hotwords: [String]) -> String?
```

1. 去首尾空白、去空项；
2. 跳过含空白、`,`、`，`、`|` 的热词；
3. 分别统计总字符数与汉字数（按 Unicode Han 脚本识别汉字）；总字符数超过 30 或汉字数超过 10 时，跳过整个热词，不截断。中英混合热词须同时满足两个上限；
4. 去重保序，取前 128 个；
5. 格式化为 `词|10`，用英文逗号连接；
6. 结果为空返回 nil，调用方不发送该参数。

被跳过的热词数量写入日志（不记录内容）。

## 9. 注册

```swift
.tencent: ProviderEntry(
    configType: TencentASRConfig.self,
    createClient: { TencentASRClient() },
    capabilities: .streaming(),
    validateCredentials: { config, options in
        try await TencentASRClient.validateCredentials(config: config, options: options)
    },
    batch: .buffered(TencentRecTaskTranscriber())
),
```

`BatchVariant.buffered` 会把非实时模式的测试连接接到 `BatchASRHTTP.validate`，它调用 `BatchASRHTTP.transcribe`，经过第 6.1 节的改动后会走腾讯云的“提交 + 轮询”，所以非实时测试连接无需另写。

## 10. 设置 UI

`ASRProviderDetailView`：

- 指引链接：API 密钥、语音识别控制台、接入文档（按 `draftRecognitionMode` 切换实时 / 非实时文档）、定价，链接见产品文档第 6.4 节；
- `currentProviderNote`：按 `draftRecognitionMode` 返回产品文档第 6.3 节的两段文案；热词说明（“含空格的热词不会发送给腾讯云”）附在末尾。

## 11. 并发与生命周期

- `TencentASRClient` 是 actor，所有状态在 actor 内；接收循环通过 `await self.handleMessage` 回到 actor；
- 每次连接使用独立的 `URLSession`，遵循 `options.urlSessionConfiguration`（绕过代理设置），这对 6001 海外调用错误尤其重要；
- `TencentRecTaskTranscriber` 和 `TencentCloudSigner` 是无状态值类型 / 纯函数，满足 `Sendable`；
- 签名使用的时间戳在每次请求时取当前时间；轮询中的每个 Describe 请求都重新签名。

## 12. 日志与隐私

- 不记录 SecretKey、签名、带签名参数的完整 URL、请求体、音频、识别文本；
- 可以记录：模式、`voice_id`、`RequestId`、`TaskId`、错误码、轮询次数与总耗时、跳过的热词数量、结果字符数；
- `voice_id` 和 `RequestId` 方便用户向腾讯云提工单排查。

## 13. 测试计划

按项目约定，本地 UI 验收交给用户；以下是需要补充的自动化测试。

### 13.1 `TencentCloudSignerTests`

1. WebSocket 签名：用官方文档的示例参数与示例签名做断言（如果文档示例无法完整复现，就用 Python 等独立实现生成固定向量）；
2. 签名原文按 key 排序；最终 URL 中 `signature` 的 `+`、`=`、`/` 已编码；
3. TC3：用官方 API 3.0 签名文档的示例（固定 timestamp、payload）断言 `Authorization` 头完全一致；
4. TC3 日期使用 UTC：给定 UTC 23:30 与次日 00:30 的时间戳，`date` 分别正确；
5. payload 改动一个字节，签名随之变化。

### 13.2 `TencentASRConfigTests`

1. 字段顺序为 `recognitionMode, secretId, secretKey, appId`，`secretKey` 为 secure；
2. 三个字段去首尾空白后保存；任一为空返回 nil；
3. 非数字 AppID 返回 nil；
4. 默认模式为 `streaming`；`recognitionMode = batch` 正确解析；`toCredentials()` 往返一致；
5. 切换 `tf_language` 后字段提示与 displayName 随之切换（中英各断言一次）。

### 13.3 `TencentASRProtocolTests`（实时）

1. URL 包含 `engine_model_type=16k_zh_en_2.0`、`voice_format=1`、`needvad=1`、`sentence_strategy=0`；有热词时含 `hotword_list`，没有时不含；**不含** `filter_punc`、`word_info`、`max_speak_time`、`vad_silence_time`；
2. 握手消息 `code == 0` 视为成功；非 0 映射为对应错误；
3. `TencentRealtimeMessage` 解码：
   - **实测 `result` 结构**（T-1 夹具）：`slice_type` 0 / 1 解码为未定稿，2 解码为定稿；`index` 映射为 id；`speaker_info`、`emotion_type`、`speech_speed` 等字段被忽略；
   - **V2 `sentences` 结构**（V2 文档示例）：数组、单个对象都能解码；`sentence_type` 1 为定稿，0 为未定稿；
   - 两种结构同时出现时以 `result` 为准；
   - 握手消息、只有 `final: 1` 的结束消息解码为空 updates；
   - 用 T-1 的完整 30 秒消息流回放，最终文本与夹具中所有定稿句拼接结果一致；
4. 状态机（两种结构各跑一遍）：
   - 同一 id 依次收到未定稿 → 未定稿（文本被改写）→ 定稿，文本逐步更新后定稿；
   - 第二句（新 id）开始后，第一句保持定稿不变；
   - 同一句重复收到定稿，不产生重复文本；
   - 已定稿句子再收到未定稿更新，文本不回退；
   - 每条消息携带全部句子与只携带当前句子两种推送方式，得到相同的 transcript；
   - 乱序到达的 id 按升序拼接；
   - 用 T-6 的 90 秒消息流回放，得到 14 句、无重复无丢失；
5. `final == 1` 时 `isFinal == true`，剩余未定稿句子并入结果；
6. 错误码 4002 / 4003 / 4004 / 4005 / 4006 / 6001 的中英文提示；
7. 结束消息为 `{"type":"end"}`。

### 13.4 `TencentRecTaskProtocolTests`（非实时）

1. `CreateRecTask` 请求：`X-TC-Action`、`X-TC-Version`、`Host` 正确；payload 中 `EngineModelType`、`ChannelNum == 1`、`SourceType == 1`；`Data` 能解码出 WAV 头；`DataLen` 等于 WAV 字节数；
2. 通过 mock `URLProtocol` 模拟：
   - Create 成功 → Describe 依次返回 0、1、2 → 得到解析后的文本，请求次数符合预期；
   - Describe 返回 3 → 抛出带 `ErrorMsg` 的错误；
   - HTTP 200 + `Response.Error` → 抛出映射后的错误（`AuthFailure.SignatureFailure` 等）；
   - 超过轮询截止时间 → `taskTimedOut`（测试中注入较短的截止时间与间隔）；
   - 等待期间取消 → 立即结束，不再发出查询；
3. 超过 150 秒的录音本地拦截，不发请求，提示为“请切换为实时流式”；`InvalidParameter`（`Data: length should in range…`）响应映射为参数错误并展示服务端 message；
4. `Result` 解析：去掉时间戳前缀；多行拼接；空结果；无时间戳的纯文本也能处理。

### 13.5 热词

`hotwordList(from:)`：

1. `["腾讯云", "Type4Me", "Claude Code", "a,b", "x|y"]` → `腾讯云|10,Type4Me|10`；
2. 纯中文：10 个汉字保留，11 个汉字跳过（即使总字符数未超过 30）；
3. 纯英文：30 个 ASCII 字符保留，31 个 ASCII 字符跳过；
4. 中英混合：10 个汉字 + 20 个 ASCII 字符保留；11 个汉字 + 19 个 ASCII 字符跳过；10 个汉字 + 21 个 ASCII 字符跳过。分别覆盖汉字数上限和总字符数上限；
5. 包含基本汉字区以外的 Unicode Han 字符时，同样计入汉字数；
6. 超过 128 个有效热词时截断；去重保序；超长词跳过整个词，不截断为新词，也不占用有效热词名额；
7. 全部被跳过时返回 nil；实时 `hotword_list` 与非实时 `HotwordList` 均使用同一格式化函数及上述限制。

### 13.6 共享层回归

- `BatchASRHTTP.transcribe` 拆分后，现有 Bailian / Gemini / ElevenLabs / Grok / Azure / Custom 的 transcriber 测试全部通过；
- 默认 `transcribe` 实现只发送一次请求。

### 13.7 注册表

- `.tencent` 可用；`supportsRecognitionModeSelection == true`；首字段为模式字段且默认 `streaming`；
- 实时模式 `createClient` 返回 `TencentASRClient`，capability 为实时；
- 非实时模式返回 `BufferedBatchASRClient`，capability 为非实时；
- 把 `.tencent` 加入 `ASRProviderRegistryTests` 中双模式 Provider 的各个列表。

### 13.8 手动验证（交给用户）

见产品文档第 13 节。实现者只需完成编译、签名、备份与安装完整性检查。

## 14. 实施步骤

建议分支：`feat/tencent-asr`。与 Groq、Mistral 互相独立，分开评审。

1. 第 2.2 节的实测已于 2026-10-18 完成（T-8 未测，T-7、T-15 部分确认），设计已按结果更新；实现时先把原始消息流与响应脱敏导出为夹具（实时消息至少覆盖：握手、未定稿更新、定稿、结束）；
2. `TencentCloudSigner` 与测试；
3. 共享层 `transcribe` 定制点与回归测试；
4. `TencentASRConfig` 改造与测试；
5. 非实时：`TencentRecTaskTranscriber`（请求、错误、轮询、解析）与测试；
6. 实时：协议层、状态机、`TencentASRClient`、测试连接，以及测试；
7. 注册表、模型标签、UI 链接与说明、图标；
8. 文档：CLAUDE.md / AGENTS.md（Provider 数量、Fully implemented 与双模式列表、Key Files），README 中英文，CHANGELOG，`docs/README.md`；
9. `swift build -c release`，运行相关测试；
10. 有条件时补测 T-8（海外代理）以及 T-7、T-15 中的计费、权限类错误；
11. 按 `$type4me-deploy` 流程打包 `pure` + universal，交给用户验收。

## 15. 风险与待定问题

| 风险 / 问题 | 影响 | 处理 |
|---|---|---|
| 实际返回格式与 V2 文档不一致（T-1 已发生：实际为 `result`，文档为 `sentences`） | 只按文档实现会握手成功却解析不出文字 | 解码器同时支持两种结构，以实测为主；第 13.3 节用实测消息流回放测试锁定 |
| 腾讯云日后把返回格式切换为 V2 文档的 `sentences` | 解析失败 | 已同时支持；两种结构同时出现时记录日志 |
| 2.0 引擎热词效果有限（T-5） | 专有名词识别改善不明显 | 产品文档如实说明，不承诺效果；继续发送热词 |
| 异步任务等待时间过长 | 非实时体验差 | 快速轮询 + 退避；产品文档中如实说明；默认模式为实时 |
| 2.0 引擎免费并发只有 50 路 | 高峰期 4006 | 个人使用通常不会触发；提示用户稍后再试 |
| 后付费默认关闭 | 免费额度用完后 4004 | Provider Note 与错误提示都说明需要开启后付费或购买资源包 |
| 海外代理导致 6001 | 无法使用 | 提示用户为 ASR 绕过代理（已有设置） |
| 账号级密钥泄露风险 | 安全 | Keychain 存储；推荐仅授权语音识别的子账号密钥 |
| 签名细节（编码、UTC 日期）出错 | 全部请求失败 | 官方示例向量测试 + 跨日测试 |
| `Result` 格式与预期不同 | 结果带时间戳或丢字 | 用真实响应作为夹具 |
