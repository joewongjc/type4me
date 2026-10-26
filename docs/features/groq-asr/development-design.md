# Groq Whisper ASR 开发设计

> 文档类型：开发设计
> 文档状态：当前有效（设计完成，待实现）
> 设计日期：2026-10-17
> 最后校验：2026-10-18
> 上游文档：`docs/features/groq-asr/product-design.md`
> 官方 API：https://console.groq.com/docs/api-reference#audio-transcription

## 1. 设计摘要

Groq 提供与 OpenAI 兼容的同步转写接口 `POST https://api.groq.com/openai/v1/audio/transcriptions`，请求为 multipart 上传，响应为 JSON。这个形态与 Type4Me 现有的共享批量链路 `BufferedBatchASRClient` + `BatchASRTranscriber` 完全吻合，因此：

- **不新增 Client**：用 `BufferedBatchASRClient(transcriber: GroqBatchTranscriber())`；
- **不复用 `OpenAIASRClient`**：它是早期独立实现，没有热词、无语音过滤、时长预检和真实的连接测试，也不在共享链路上；
- **只有批量模式**：Config 不采用 `ASRRecognitionModeConfigurable`，不出现实时 / 非实时切换；
- **不改 `SpeechRecognizer` 协议、不改音频采集格式**。

需要对共享层做三处小改动：

1. `BatchASRTranscriber` 增加可覆盖的最短录音时长（Whisper 需要 0.5 秒，其他 Provider 保持 0.3 秒）；
2. `BatchASRError.recordingTooLong` 的提示区分“可切换实时”和“只能缩短录音”两种情况；
3. 增加可选的上传前静音门限（默认关闭，Groq 开启），原因见 G-5 与第 6.4 节。

## 2. 接口要点（已核对官方文档）

| 项 | 值 |
|---|---|
| Endpoint | `https://api.groq.com/openai/v1/audio/transcriptions` |
| 鉴权 | `Authorization: Bearer gsk_...` |
| Body | `multipart/form-data` |
| 必填 | `model`，`file`（或 `url`，本设计只用 `file`） |
| 可选 | `language`（ISO-639-1），`prompt`（文档写 224 token；实测上限为 896 个 UTF-8 字节，超限返回 400，见 G-2），`response_format`（`json` / `text` / `verbose_json`），`temperature`（0–1，默认 0），`timestamp_granularities[]` |
| 文件格式 | flac, mp3, mp4, mpeg, mpga, m4a, ogg, wav, webm |
| 大小上限 | 免费档 25 MB，开发者档 100 MB |
| 最短计费 | 10 秒 |
| 服务端预处理 | 统一降采样为 16 kHz 单声道（与 Type4Me 采集格式一致，无需重采样） |
| 错误体 | `{"error": {"message": "...", "type": "..."}}`，现有 `BatchASRHTTP.errorMessage` 已能解析 |
| 速率限制 | 429 + `retry-after`（秒）；免费档 20 RPM / 2K RPD / 7.2K ASH / 28.8K ASD |

官方文档没有写清楚的内容，统一列在第 2.1 节的实测清单中。本文其他地方提到“以实测为准”时，都引用清单编号（G-1、G-2……）。

### 2.1 实测清单

本节是 Groq 所有待实测内容的唯一来源。设计按“当前假设”一栏实现；实测结果与假设不同时，按“结果对设计的影响”一栏修改代码和文档。

#### 执行约定

- **时机**：按“级别”执行。A 级在编写对应代码之前完成，B 级在交给用户验收之前完成，C 级在发布后持续观察；
- **凭证**：使用用户提供的 Groq API Key。Key 不写入仓库、脚本和日志；
- **工具**：用 `curl` 或一次性脚本，放在临时目录，不提交；
- **测试音频**：统一使用合成或专门录制的样本，不使用用户的真实语音。样本集：中文短句、英文短句、中英混合句、轻声说话、2 秒静音、5 秒键盘噪声、长音频（短句重复拼接到所需时长）。全部为 16 kHz 单声道 16-bit WAV；
- **夹具**：脱敏后的响应存到 `Tests/Type4MeTests/Fixtures/groq/`，文件名带编号（如 `G-1-verbose-json-zh.json`），供单元测试使用；
- **记录**：每完成一项，在“实测记录”表中填写日期、结论、夹具路径和对设计的改动，并把状态从“待实测”改为“已确认”（与假设一致）或“已调整”（设计已按结果修改）；
- **费用**：Groq 最短按 10 秒计费，全部实测（约 100 次请求）费用在 $0.05 以内。

#### 清单

| 编号 | 级别 | 待确认内容 | 当前假设（设计按此实现） | 实测方法 | 结果对设计的影响 | 状态 |
|---|---|---|---|---|---|---|
| G-1 | A | `verbose_json` 的分段字段名和取值 | 与 OpenAI Whisper 一致：`segments[]` 含 `text`、`no_speech_prob`、`avg_logprob`、`compression_ratio` | 两个模型各发一条中文、一条英文，`response_format=verbose_json` | 字段名不同：改解析器；没有分段置信度：去掉无语音过滤，只保留最短时长与 prompt 回显清理，并更新产品文档第 9 节 | 已确认 |
| G-2 | A | `prompt` 超过 224 token 时的服务端行为；本地 token 估算是否足够保守 | 超限会报错；按“ASCII 每 3 字符 1 token、非 ASCII 每字 2 token”估算、预算 200 不会超限 | 构造估算值分别为 200、260、400 的中文、英文、中英混合 prompt，观察是否报 400、是否截断 | 超限只截断不报错：可保留预算，作为余量；估算为 200 的请求也报错：降低预算或调整估算系数 | 已调整 |
| G-3 | B | 简体引导语能否消除繁体输出 | `zh` 加引导语后输出简体 | 10 条中文样本，分别不加和加引导语，各跑 2 次，统计繁体字数（用 `Hant-Hans` 转换前后对比检测） | 加引导语后仍有繁体：更新产品文档第 7 节的承诺，把“可选的繁转简后处理”提前到第一版 | 已确认 |
| G-4 | B | “自动检测 + 中文界面”附加引导语是否影响英文和中英混合识别 | 影响可忽略 | 5 条中英混合、5 条纯英文样本，语言为自动检测，分别不加和加引导语 | 英文被音译或翻成中文：自动检测时不再附加引导语，只在语言选 `zh` 时附加 | 已调整 |
| G-5 | A | 无语音过滤阈值（`no_speech_prob > 0.6` 且 `avg_logprob < -1.0`）是否合适 | 能过滤静音与噪声上的幻觉，且不误删轻声说话 | 静音、噪声、轻声说话样本各 5 次，记录每个分段的两个指标 | 幻觉漏网：收紧阈值；轻声内容被删：放宽阈值。最终阈值写入代码常量与测试 | 已调整 |
| G-6 | B | 静音时是否回显 prompt（引导语或热词） | 偶尔回显，`ASRHotwordLeakSanitizer` 加“结果等于引导语即视为空”能清理 | 静音样本 + 带 5 个热词的 prompt，跑 10 次 | 出现清理不掉的回显形态：补充清理规则与测试 | 已调整 |
| G-7 | B | 免费档 25 MB 上限的实际表现 | 12 分钟 WAV（约 23 MB）可以上传；超过 25 MB 返回 413 | 上传 12 分钟与 14 分钟（约 27 MB）的长音频 | 12 分钟失败：降低 `maxDuration`；记录 413 的错误体 | 已确认 |
| G-8 | B | 401、404、413、429 的错误体是否有可读的 `error.message`；429 是否带等待时间 | 都有可读 message，429 的 message 含等待秒数，并带 `retry-after` 头 | 错误 Key、错误模型名、超大文件；1 分钟内连续发 21 次 1 秒静音触发 429 | message 为空或不可读：启用开发设计第 6.3 节的兜底文案 | 已确认 |
| G-9 | A | 测试连接用的 1 秒静音能否得到 HTTP 200 | 返回 200（官方最短 0.01 秒） | 两个模型各发一次 1 秒静音 | 不是 200：改用 1 秒的合成语音作为探测音频 | 已确认 |
| G-10 | C | 松手到出字的端到端延迟 | Turbo 在 1 秒左右 | 5、30、60 秒样本，两个模型各 5 次，记录 P50 / P90 | 只作为发布后的评测数据，不阻塞实现 | 已确认 |
| G-11 | C | 中国大陆网络能否直接访问 `api.groq.com` | 部分地区返回 403 或超时 | 在不使用代理的大陆网络下发一次测试连接 | 常见 403：在产品文档第 4.3 节写明需要代理 | 部分确认 |

#### 实测记录

| 编号 | 日期 | 结论 | 夹具 | 对设计的改动 |
|---|---|---|---|---|
| G-1 | 2026-10-18 | 字段与假设一致：`segments[]` 含 `id`、`seek`、`start`、`end`、`text`、`tokens`、`temperature`、`avg_logprob`、`compression_ratio`、`no_speech_prob`；根对象另有 `task`、`language`（如 `"Chinese"`、`"English"`）、`duration`、`text`、`x_groq`。Turbo 的 `no_speech_prob` 在正常语音上恒为 0 | `G-1-verbose-json-{zh,en}-{turbo,v3}.json` | 无 |
| G-2 | 2026-10-18 | 上限**不是 224 token，而是 896 个 UTF-8 字节**：402 个汉字被服务端报为 1206 characters（402×3），超限返回 HTTP 400，message 为 `prompt length must be 896 characters or fewer, but provided prompt contains N characters`；201 个汉字（603 字节）、估算 400 token 的 prompt 正常通过。另观察到：中文热词较多时，`一下` 被误识别为 `依下` | `G-2-prompt-limit-400.json` | 第 5.2 节改为按 UTF-8 字节计算预算（上限 880 字节），删除 token 估算 |
| G-3 | 2026-10-18 | 语言设为 `zh` 时，两个模型 × 10 条中文 × 2 次，**不加引导语也没有出现任何繁体**（加引导语同样为 0） | — | `zh` 不再需要引导语（与 G-4、G-5 合并决定，见第 5.2 节） |
| G-4 | 2026-10-18 | 自动检测 + 引导语时，Turbo 把 5 条英文中的 3 条错误转成中文，其中 1 条直接变成幻觉 `请订阅明镜与点点栏目`；自动检测 + 不加引导语时，Turbo 在 1 条中英混合样本上输出繁体（`這個Feature的PR已經Merge了`，`language` 为 `"Chinese"`） | `G-4-auto-hint-en-translated.json`、`G-4-auto-mixed-hant.json` | **取消简体引导语**；简体改由客户端繁转简保证：响应 `language` 为 `Chinese` 时做 ICU `Hant-Hans` 转换（第 5.3 节），同步产品文档第 7 节 |
| G-5 | 2026-10-18 | **阈值过滤无效**：幻觉文本的分段置信度都很“确定”（Turbo `no_speech_prob` 恒为 0.00，`avg_logprob` 约 -0.2～-0.3），一条都过滤不掉。典型幻觉：静音→`Thank you.` / `you`；静音 + 中文引导语→`请不吝点赞 订阅 转发 打赏支持明镜与点点栏目`；键盘噪声→`Продолжение следует...`、`我会认识。`、`例如,`、` .`。轻声说话（约 -24 dB）两个模型都识别正确 | `G-5-silence-*.json`、`G-5-noise-*.json` | 删除置信度阈值过滤；改为三层：上传前本地静音门限、已知幻觉短语整句过滤、prompt 回显清理（第 5.3、6.4 节），同步产品文档第 9 节 |
| G-6 | 2026-10-18 | Large v3 在静音和噪声上把**整个热词列表原样回显**（`Type4Me、Claude Code、Groq、Kubernetes、PostgreSQL`，噪声时还会变成 `Type5Me`）；Turbo 回显部分热词（`或许多数字、PostgreSQL`）。热词效果明显：不带热词时 `Type4Me`→`Tarpe4默` / `Type4M`、`Claude Code`→`Cloud Code`，带热词后两个模型都正确 | `G-6-echo-*.json`、`G-6-term1-*.json` | 回显清理改为“结果中的词汇有一半以上来自热词列表即视为回显”（第 5.3 节），并支持模型改写热词（编辑距离 ≤ 1） |
| G-7 | 2026-10-18 | 12 分钟 WAV（23.04 MB）上传成功，耗时 22.2 秒；14 分钟（26.88 MB）在上传约 1.2 MB 后即返回 HTTP 413：`{"error":{"message":"Request Entity Too Large","type":"invalid_request_error","code":"request_too_large"}}`，随后服务端断开连接 | `G-7-413.json` | 无，12 分钟上限保留 |
| G-8 | 2026-10-18 | 401：`Invalid API Key`；404：``The model `whisper-not-a-model` does not exist or you do not have access to it.``；413 见 G-7；429：message 含 `Please try again in 3s`，带 `retry-after: 3` 头，并附带组织 ID 与升级链接 | `G-8-{401,404,429}.json`（组织 ID 已脱敏） | 无需兜底文案；日志与错误提示中截断 429 message 的升级链接以后的部分，避免展示组织 ID |
| G-9 | 2026-10-18 | 两个模型对 1 秒静音都返回 HTTP 200（内容为幻觉 `Thank you.` / `you`） | — | 无；测试连接只看状态码 |
| G-10 | 2026-10-18 | 端到端（含约 1 秒网络往返）P50：Turbo 5 秒 1.96 s、30 秒 3.52 s、60 秒 4.13 s；Large v3 分别为 2.23 s、3.21 s、4.24 s；偶发长尾 7–10 s。12 分钟音频 22 s | — | 产品文档第 1 节“1 秒以内”的描述改为“短句约 2 秒出字” |
| G-11 | 2026-10-18 | 本机网络可直接访问 `api.groq.com`（不能代表所有大陆网络）。另发现：Cloudflare 会按 User-Agent 拦截部分客户端，Python `urllib` 默认 UA 被返回 403 `error code: 1010`；**URLSession 默认 UA 正常**（200，且能读到 413 JSON） | — | 第 6.3 节补充：403 且正文为 `error code: 1010` 时提示“请求被 Groq 网络防护拦截”；App 不需要自定义 UA |

说明：

- 本轮实测共约 260 次请求，测试音频为 macOS 语音合成（Tingting、Samantha）生成的样本和程序生成的静音、噪声，不含真实人声。真实麦克风环境下的静音与噪声表现，需要在用户验收时补充观察；
- “夹具”一栏是实现时要导出的文件名。原始响应目前只保存在本地临时目录，实现时脱敏（去掉组织 ID、请求 ID）后放入 `Tests/Type4MeTests/Fixtures/groq/`；
- G-5、G-4 的结果推翻了原设计中“置信度过滤”和“简体引导语”两项，第 5.2、5.3、6.4 节和产品文档第 7、9 节已按实测结果修改。

## 3. 改动清单

### 3.1 新增文件

| 文件 | 内容 |
|---|---|
| `Sources/Type4Me/ASR/Providers/GroqASRConfig.swift` | `GroqASRConfig` + `GroqWhisperModel` |
| `Sources/Type4Me/Resources/Icons/groq.png` | 品牌图标（与现有图标同尺寸） |
| `Tests/Type4MeTests/GroqASRConfigTests.swift` | Config 测试 |
| `Sources/Type4Me/ASR/GroqHallucinationPhrases.swift` | 已知幻觉短语表（第 5.3 节） |
| `Sources/Type4Me/ASR/PCMSilenceDetector.swift` | 上传前静音门限（第 6.4 节） |
| `Tests/Type4MeTests/PCMSilenceDetectorTests.swift` | 静音门限测试 |
| `Tests/Type4MeTests/Fixtures/groq/G-*.json` | 第 2.1 节实测的脱敏响应夹具 |

### 3.2 修改文件

| 文件 | 改动 |
|---|---|
| `Sources/Type4Me/ASR/ASRProvider.swift` | International 段新增 `case groq`，`displayName` 返回 `"Groq"` |
| `Sources/Type4Me/Protocol/BatchASRTranscribers.swift` | 新增 `GroqBatchTranscriber` |
| `Sources/Type4Me/ASR/BufferedBatchASRClient.swift` | 协议新增 `minimumDuration`、`suggestsRealtimeFallback`、`skipsSilentAudio`；最短录音判断改为读 transcriber；按需调用静音门限；`recordingTooLong` 文案分支 |
| `Sources/Type4Me/ASR/ASRProviderRegistry.swift` | 注册 `.groq` |
| `Sources/Type4Me/UI/Settings/ASRProviderDetailView.swift` | 指引链接 + Provider Note |
| `Sources/Type4Me/UI/Settings/ModelSettingsState.swift` | SF Symbol 兜底图标 |
| `Sources/Type4Me/UI/Settings/BrandIconView.swift` | `.groq → "groq"`，按图标色彩决定是否加入深色反色列表 |
| `Tests/Type4MeTests/BatchASRTranscribersTests.swift` | Groq 请求构造与解析测试 |
| `Tests/Type4MeTests/ASRProviderRegistryTests.swift` | 把 `.groq` 加入非实时、无模式切换的断言列表 |
| `CLAUDE.md` / `AGENTS.md`、`README.md`、`README.en.md`、`CHANGELOG.md` | Provider 数量与列表 |
| `docs/README.md` | 实现后更新状态 |

不需要改动：

- `KeychainService`：存储键按 `tf_asr_\(provider.rawValue)` 自动生成，安全字段由 `isSecure` 决定；
- `MenuBarControlCenter`：按 `allCases` + capability 自动出现；
- `RecognitionSession.asrModelLabel` / `AppState.RecordingDisplayMetadata`：通用路径读取 `credentials["model"]`，自动显示 `Groq · whisper-large-v3-turbo`；
- `ModelProviderListView`：capability 为 `.batch()` 时自动显示“非实时”标签。

## 4. 数据模型

### 4.1 `GroqASRConfig`

```swift
enum GroqWhisperModel: String, CaseIterable, Sendable {
    case largeV3Turbo = "whisper-large-v3-turbo"
    case largeV3 = "whisper-large-v3"

    var optionLabel: String {
        switch self {
        case .largeV3Turbo: return "Whisper Large v3 Turbo ($0.04/hr)"
        case .largeV3:      return "Whisper Large v3 ($0.111/hr)"
        }
    }
}

struct GroqASRConfig: ASRProviderConfig, Sendable {
    static let provider = ASRProvider.groq
    static let displayName = "Groq"
    static let defaultModel = GroqWhisperModel.largeV3Turbo

    static let supportedLanguages = [
        "", "zh", "en", "ja", "ko",
        "fr", "de", "es", "it", "pt", "ru", "ar", "hi", "id", "th", "vi", "tr", "nl", "pl",
    ]

    // computed var：字段标签随 tf_language 实时切换（与 GrokASRConfig 一致）
    static var credentialFields: [CredentialField] {[
        CredentialField(key: "apiKey", label: "API Key", placeholder: "gsk_...",
                        isSecure: true, isOptional: false, defaultValue: ""),
        CredentialField(key: "model", label: L("模型", "Model"),
                        placeholder: defaultModel.rawValue,
                        isSecure: false, isOptional: true, defaultValue: defaultModel.rawValue,
                        options: GroqWhisperModel.allCases.map { FieldOption(value: $0.rawValue, label: $0.optionLabel) }),
        CredentialField(key: "language", label: L("语言", "Language"), placeholder: "auto",
                        isSecure: false, isOptional: true, defaultValue: "",
                        options: supportedLanguages.map { FieldOption(value: $0, label: languageLabel($0)) }),
    ]}

    let apiKey: String
    let model: GroqWhisperModel
    let language: String
    // init?(credentials:)：apiKey 去空白后为空则返回 nil；
    // 未知或空的 model 回退到 defaultModel；language 去空白。
    // toCredentials()：["apiKey", "model": model.rawValue, "language"]
    // isValid：!apiKey.isEmpty
}
```

设计决定：

- `model` 用枚举而不是任意字符串：只暴露两个已验证的模型，未知值（比如将来 Groq 下线某个模型后残留的旧值）回退到默认值，不会把 404 留给用户；
- `languageLabel` 对 `""`、`zh`、`en`、`ja`、`ko` 返回中英文名称（`zh` 为“中文（简体）/ Chinese (Simplified)”），其余返回 ISO 代码；
- `credentialFields` 必须是计算属性，否则标签在切换 `tf_language` 后不会刷新。

### 4.2 Provider 枚举

```swift
// International
case openai
...
case grok
case groq      // 新增
case soniox
```

`rawValue` 为 `"groq"`，作为 Keychain 与 UserDefaults 的稳定键，以后不能改名。

## 5. `GroqBatchTranscriber`

```swift
/// Groq-hosted Whisper via the OpenAI-compatible `/audio/transcriptions` endpoint.
struct GroqBatchTranscriber: BatchASRTranscriber {
    static let endpoint = URL(string: "https://api.groq.com/openai/v1/audio/transcriptions")!

    let providerName = "Groq"
    /// 25 MB free-tier upload cap ≈ 13.6 min of 16 kHz mono WAV; keep headroom for multipart overhead.
    let maxDuration: TimeInterval? = 12 * 60
    /// Whisper hallucinates on very short clips.
    let minimumDuration: TimeInterval = 0.5
    let suggestsRealtimeFallback = false
    /// Whisper invents text on silence (G-5); skip uploads with no audible signal.
    let skipsSilentAudio = true

    func makeRequest(pcmData: Data, config: any ASRProviderConfig, options: ASRRequestOptions) throws -> URLRequest
    func parseTranscript(from data: Data, options: ASRRequestOptions) throws -> String
}
```

### 5.1 请求构造

multipart 字段顺序：

| 字段 | 值 | 条件 |
|---|---|---|
| `model` | `config.model.rawValue` | 总是 |
| `response_format` | `verbose_json` | 总是 |
| `temperature` | `0` | 总是（显式写出，避免服务端默认值变化） |
| `language` | `config.language` | 非空时 |
| `prompt` | `Self.prompt(...)` | 结果非空时 |
| `file` | `audio.wav`，`audio/wav`，`WAVEncoder.encode(pcmData:)` | 总是，放最后 |

其他：

- `request.timeoutInterval = BatchASRHTTP.requestTimeout`；
- 使用 `MultipartFormBody`（现有工具）；
- 用 WAV 而不是 FLAC：官方建议“WAV 延迟更低”，而且不需要新增编码器。

### 5.2 Prompt 构造（纯函数，便于测试）

```swift
/// Groq rejects prompts over 896 UTF-8 bytes with HTTP 400 (G-2); keep a small margin.
static let promptByteBudget = 880

static func prompt(hotwords: [String]) -> String
```

规则：

1. **不再使用简体引导语**。G-3 证明语言为 `zh` 时不加引导语也输出简体；G-4 证明自动检测时加引导语会把英文错误地转成中文；G-5 证明引导语会诱发中文幻觉（`请不吝点赞 订阅 转发…`）。简体输出改由第 5.3 节的繁转简保证；
2. prompt 只包含热词：去空白、去空值、去重（保持原顺序），用 `"、"` 连接；
3. 按 **UTF-8 字节数**逐个追加热词，总长不超过 `promptByteBudget`，放不下就停止，不截断单个热词。服务端按字节计数（402 个汉字被计为 1206），所以必须用 `text.utf8.count`，不能用字符数；
4. 结果为空时不发送 `prompt` 字段。

G-2 还观察到中文热词很多时识别准确率可能下降（`一下`→`依下`）。第一版不额外限制热词数量，作为发布后观察项（第 13 节）。

### 5.3 响应解析

G-5 证明分段置信度（`no_speech_prob`、`avg_logprob`）无法识别 Groq 的幻觉文本，**不使用置信度过滤**。解析步骤：

1. 解析 JSON 根对象，失败抛出 `BatchASRError.invalidResponse(provider:)`；
2. 取根对象的 `text`；没有 `text` 时拼接 `segments[].text`（分段文本自带前导空格或不带，直接拼接后整体 trim）；
3. **已知幻觉短语过滤**：把结果去掉首尾空白和标点、折叠空白后，如果与 `GroqHallucinationPhrases` 中任一条完全相等，返回空字符串。只做整句完全匹配，不做包含匹配，避免误删用户真的说出的“谢谢”。初始列表来自 G-5、G-6 和 Whisper 社区公认的高频幻觉：
   - `Thank you.`、`Thank you for watching.`、`Thanks for watching!`、`you`、`.`、`。`、`Продолжение следует...`；
   - `请不吝点赞 订阅 转发 打赏支持明镜与点点栏目`、`请订阅明镜与点点栏目`、`字幕由Amara.org社区提供`、`谢谢观看`、`谢谢收看`、`优优独播剧场——YoYo Television Series Exclusive`；
   - 列表放在独立文件中，便于以后追加；
4. **热词回显清理**：先经过 `ASRHotwordLeakSanitizer.sanitize(text, hotwords: options.hotwords)`；再把结果按 `、`、`，`、`,` 和空白切分，如果一半以上的片段与热词相同（忽略大小写，允许编辑距离 ≤ 1，以覆盖 G-6 中的 `Type5Me`），视为 prompt 回显，返回空字符串；
5. **繁转简**：根对象 `language` 为 `"Chinese"`，并且语言设置为 `zh`，或语言为自动检测且 `AppLanguage.current == .zh` 时，对结果做 ICU `Hant-Hans` 转换（`applyingTransform(StringTransform("Hant-Hans"), reverse: false)`）。G-4 证明自动检测时 Turbo 会输出繁体；英文界面的用户不做转换，避免影响有意输入繁体的用户。

纯静音在上传前已由第 6.4 节的本地静音门限拦截；第 3、4 步处理噪声环境下仍然产生的幻觉。G-5 中 `我会认识。`、`例如,` 这类没有固定模式的噪声幻觉无法可靠识别，是已知局限（第 13 节）。

### 5.4 无语音响应

Groq 对静音返回的是 200 加幻觉文本，而不是错误码，所以不覆盖 `isNoSpeechResponse`，过滤靠第 6.4 节的本地静音门限与第 5.3 节第 3、4 步完成。

## 6. 共享层改动

### 6.1 最短录音时长

`BufferedBatchASRClient.minimumAudioBytes` 目前是写死的 0.3 秒。改为：

```swift
protocol BatchASRTranscriber: Sendable {
    ...
    /// Recordings shorter than this are not uploaded; the session gets an empty transcript.
    var minimumDuration: TimeInterval { get }
}

extension BatchASRTranscriber {
    var minimumDuration: TimeInterval { 0.3 }
}
```

`endAudio()` 改为比较 `Int(transcriber.minimumDuration * Double(BatchASRHTTP.bytesPerSecond))`。其他 transcriber 走默认值，行为不变。

`BatchASRHTTP.validate` 用 1 秒静音测试连接，大于 0.5 秒，不受影响。

### 6.2 录音过长文案

```swift
protocol BatchASRTranscriber {
    /// False for batch-only providers, whose too-long error must not suggest switching to real-time mode.
    var suggestsRealtimeFallback: Bool { get }
}
extension BatchASRTranscriber { var suggestsRealtimeFallback: Bool { true } }
```

`BatchASRError.recordingTooLong` 增加 `suggestsRealtime: Bool` 关联值（`Equatable` 自动合成，需同步更新现有测试中的构造）。Mistral 设计还会再加一个 `hint: String?`，最终签名为 `(provider:maxSeconds:suggestsRealtime:hint:)`，见 `docs/features/mistral-asr/development-design.md` 第 6 节；Groq 传 `hint: nil`。文案规则：

- `true`：保持现文案“……请切换为实时流式”；
- `false`：“录音超过 \(provider) 的 \(minutes) 分钟上限，请缩短后重试” / “The recording exceeds the \(minutes)-minute limit of \(provider). Record a shorter segment and try again.”。

`CustomHTTPBatchTranscriber` 的 `maxDuration` 为 nil，不受影响；但它同样是纯批量 Provider，顺带将它的 `suggestsRealtimeFallback` 设为 `false`，保持语义正确。

### 6.3 HTTP 状态码文案

现有 `BatchASRError.requestFailed` 已展示“Provider 返回 HTTP code：服务端 message”。Groq 的 401 / 403 / 413 / 429 错误体都带 `error.message`（429 的 message 自带“Please try again in Xs”），直接复用即可满足产品文档第 10.2 节的要求，第一版不为 Groq 单独定制状态码文案。

G-8 已确认 401、404、413、429 的 message 都可读，不需要兜底文案。只有两处特殊处理，都在 `GroqBatchTranscriber` 内完成，不改共享层：

- 429 的 message 末尾附带组织 ID 和升级链接（`... Need more tokens? Upgrade to Dev Tier today at https://console.groq.com/settings/billing`）。展示和记录前截断到 `Please try again in Xs.` 为止，避免在界面和日志中出现组织 ID；
- 403 且正文为 Cloudflare 的 `error code: 1010`（G-11）时，message 改为“请求被 Groq 网络防护拦截，请检查代理或网络环境” / “The request was blocked by Groq's network protection. Check your proxy or network.”。

### 6.4 上传前静音门限

G-5 证明 Whisper 会把静音识别成 `Thank you.` 等文字，而且无法从响应中识别。最可靠的做法是不上传没有声音的录音：

```swift
protocol BatchASRTranscriber {
    /// When true, recordings with no audible signal are not uploaded; the session gets an empty transcript.
    var skipsSilentAudio: Bool { get }
}
extension BatchASRTranscriber { var skipsSilentAudio: Bool { false } }

enum PCMSilenceDetector {
    /// 30 ms frames above -50 dBFS count as audible.
    static let frameDuration: TimeInterval = 0.03
    static let audibleThresholdDBFS: Float = -50
    /// Total audible time required before a recording is worth uploading.
    static let minimumAudibleDuration: TimeInterval = 0.3

    static func isSilent(_ pcm: Data) -> Bool
}
```

- `BufferedBatchASRClient.endAudio()` 在最短时长检查之后、发请求之前，若 `transcriber.skipsSilentAudio && PCMSilenceDetector.isSilent(audioBuffer)`，直接以空结果结束；
- 默认 `false`，只有 Groq 开启，其他 Provider 行为不变；
- 阈值依据 G-5 的能量统计：正常语音帧约 -11～-15 dBFS，-24 dB 的轻声说话约 -38～-40 dBFS，都远高于 -50 dBFS；程序生成的静音没有任何帧超过阈值；
- 局限：键盘噪声（峰值约 -32 dBFS）高于轻声说话，按能量无法区分，这类噪声仍会上传，交给第 5.3 节的幻觉短语过滤。真实麦克风的底噪通常在 -60～-50 dBFS，用户验收时需要确认安静环境下不说话不会被上传（产品文档验收第 7 项）；
- `BatchASRHTTP.validate` 的 1 秒静音探测不经过 `BufferedBatchASRClient.endAudio()`，不受影响。

## 7. 注册

```swift
.groq: ProviderEntry(
    configType: GroqASRConfig.self,
    createClient: { BufferedBatchASRClient(transcriber: GroqBatchTranscriber()) },
    capabilities: .batch(),
    validateCredentials: { config, options in
        try await BatchASRHTTP.validate(with: GroqBatchTranscriber(), config: config, options: options)
    }
),
```

与 `.custom` 的注册方式相同。不使用 `batch:` 字段（那是给“实时 + 非实时”双模式 Provider 的）。

## 8. 设置 UI

`ASRProviderDetailView`：

```swift
case .groq:
    return [
        ("API Key", L("获取", "get"), URL(string: "https://console.groq.com/keys")!),
        (L("文档", "Docs"), L("查看", "view"), URL(string: "https://console.groq.com/docs/speech-to-text")!),
        (L("定价与限制", "Pricing & Limits"), L("查看", "view"), URL(string: "https://groq.com/pricing")!),
    ]
```

`currentProviderNote` 使用产品文档第 6.4 节的中英文文案。

图标：

- `ModelSettingsState.icon(for:)`：`.groq → "bolt.fill"`（只在品牌图缺失时用作兜底）；
- `BrandIconView`：`.groq → "groq"`。Groq 官方标识为橙红色，不需要加入 `shouldInvertInDarkMode`；如果最终素材是单色黑，再加入反色列表。素材来源与授权要和其他品牌图标保持一致，并更新 `ThirdPartyNotices`（如适用）。

## 9. 并发与生命周期

全部沿用 `BufferedBatchASRClient`：

- actor 隔离音频缓冲；
- 每次会话单独创建 `URLSession`，遵循 `options.urlSessionConfiguration`（绕过代理设置）；
- `disconnect()` 调用 `invalidateAndCancel()`，录音取消时上传请求会被中止；
- 错误先以 `.error` 发出，再发 `.completed`，`RecognitionSession` 现有错误处理不需要改。

`GroqBatchTranscriber` 是无状态值类型，满足 `Sendable`。

## 10. 日志与隐私

- 沿用 `BufferedBatchASRClient` 的“发送 N 字节 PCM”日志；
- 在 `parseTranscript` 中用 `os.Logger` 记录“分段总数 / 过滤数 / 结果字符数”，不记录文本内容；
- 不记录 prompt（含用户热词）、Authorization 头、音频；
- `BatchASRHTTP.errorMessage` 最多取 300 字节，沿用。

## 11. 测试计划

按项目约定，本地 UI 验收交给用户；以下是需要补充的自动化测试。

### 11.1 `GroqASRConfigTests`

1. 有效凭证解析，`toCredentials()` 往返一致；
2. 空 / 纯空白 apiKey 返回 nil；
3. 缺省 model 回退为 `whisper-large-v3-turbo`；未知 model（如 `distil-whisper-large-v3-en`）同样回退；
4. `credentialFields` 的 key 顺序为 `apiKey, model, language`，apiKey 为 secure；
5. 模型选项正好是两个，值与 `GroqWhisperModel.allCases` 一致；
6. 切换 `tf_language` 后，字段标签与语言选项标签随之变为对应语言（中英各断言一次，测试结束恢复原值）。

### 11.2 `BatchASRTranscribersTests`（Groq 部分）

1. 请求 URL、`POST`、`Bearer` 头、multipart Content-Type 正确；
2. multipart 包含 `model`、`response_format=verbose_json`、`temperature=0`，`file` 位于最后且是 WAV 头；
3. `language` 为空时不发送该字段；
4. `prompt(hotwords:)`：
   - 无热词 → 空字符串，请求中没有 `prompt` 字段；
   - 任何情况下都不包含简体引导语；
   - 热词去重、保序，用 `、` 连接；
   - 300 个汉字的热词列表被截断到 `utf8.count ≤ 880`，且不会截断半个词；纯英文热词按字节同样正确截断；
5. 解析（使用 G-1、G-4、G-5、G-6 的实测夹具）：
   - 正常 `verbose_json` → 取 `text`；
   - 没有 `text` 时拼接 `segments[].text`；
   - G-5 中的每一条幻觉（`Thank you.`、`you`、` .`、`请不吝点赞 订阅 转发 打赏支持明镜与点点栏目`、`Продолжение следует...`）→ 空字符串；
   - `谢谢你的帮助。` 这类包含“谢谢”但不完全等于幻觉短语的句子 → 原样保留；
   - G-6 中的热词回显（含 `Type5Me` 变体）→ 空字符串；带热词的正常句子 `我最近在用Type4Me做语音输入,配合Claude Code写代码。` → 原样保留；
   - G-4 中 `language == "Chinese"` 的繁体结果：语言 `zh` 或“自动 + 中文界面”时转为简体；“自动 + 英文界面”时保持原样；`language == "English"` 时不转换；
   - 非 JSON → `invalidResponse`；
6. `PCMSilenceDetector.isSilent`：
   - 全零 PCM、-60 dBFS 的白噪声 → 静音；
   - 正常语音样本、-24 dB 的轻声样本（G-5 中的 soft1–soft3）→ 非静音；
   - 只有 0.2 秒可闻信号的录音 → 静音（低于 0.3 秒）；
7. 通过 mock `URLProtocol`（沿用现有 Grok 客户端测试的写法）：
   - 0.4 秒录音不发请求，直接返回空结果；
   - 2 秒全零录音不发请求（静音门限），直接返回空结果；
   - 超过 12 分钟抛出 `recordingTooLong(suggestsRealtime: false)`，且未发请求；
   - 401 / 404 / 413 / 429 响应映射为 `requestFailed`，message 取自 `error.message`；429 的 message 截断到 `Please try again in Xs.`，不含组织 ID；
   - 403 + `error code: 1010` 映射为网络防护拦截提示。

### 11.3 共享层回归

- 现有 transcriber 的 `minimumDuration` 为 0.3、`suggestsRealtimeFallback` 为 true、`skipsSilentAudio` 为 false；其他 Provider 的 2 秒全零录音仍会上传（行为不变）；
- `recordingTooLong` 两种文案的中英文断言；
- 更新已有构造 `recordingTooLong` 的测试。

### 11.4 `ASRProviderRegistryTests`

- `.groq` 加入非实时 capability 列表（`isAvailable`、`!isStreaming`、`!supportsRealtimeRecognition`）；
- `.groq` 加入“不提供模式切换”列表；
- `createClient(for: .groq)` 返回 `BufferedBatchASRClient`；
- `configType(for: .groq) == GroqASRConfig.self`。

### 11.5 手动验证（交给用户）

见产品文档第 14 节。实现者只需完成编译、签名、备份与安装完整性检查。

## 12. 实施步骤

建议分支：`feat/groq-asr-provider`（当前分支 `feat/optimize-asr-providers` 上有未提交的百度弃用改动，与本功能无关，按分支规范不要混在一起）。

1. A 级与 B 级实测已于 2026-10-18 完成（第 2.1 节），设计已按结果更新；实现时先把原始响应脱敏导出为夹具；
2. 共享层：`minimumDuration`、`suggestsRealtimeFallback`、`recordingTooLong` 文案，并补回归测试；
3. `GroqASRConfig` 与测试；
4. `GroqBatchTranscriber`（请求、prompt、解析）与测试；
5. 枚举、注册表、UI 链接、Provider Note、图标；
6. 文档：CLAUDE.md / AGENTS.md 的 Provider 数量与 Key Files，README 中英文，CHANGELOG，`docs/README.md` 状态；
7. `swift build -c release`，运行相关测试；
8. 按 `$type4me-deploy` 流程打包 `pure` + universal，交给用户验收。

## 13. 风险与待定问题

| 风险 / 问题 | 影响 | 处理 |
|---|---|---|
| 噪声环境下的幻觉文本（如 `我会认识。`、`例如,`） | 误注入少量无关文字 | 已知局限（G-5）：静音门限挡不住噪声，没有固定模式的幻觉无法用短语表识别。发布后收集真实幻觉样本扩充短语表；如果频繁出现，再评估本地 VAD（Silero，需 `HAS_SHERPA_ONNX`） |
| 幻觉短语表误删用户真的说出的整句（如只说了一句 “Thank you.”） | 极短的感谢语被吞掉 | 只做整句完全匹配；影响面限于用户整次录音只说了这一句的情况，可以接受 |
| 真实麦克风底噪高于 -50 dBFS | 静音门限失效，静音仍会上传并产生 `Thank you.` | 幻觉短语表兜底；用户验收第 7 项确认，必要时调整阈值 |
| 中文热词过多影响准确率 | 少量错字（G-2 中 `一下`→`依下`） | 发布后观察；必要时限制热词数量 |
| 繁转简误伤有意输入繁体的用户 | 繁体被转成简体 | 只在中文界面或语言选 `zh` 时转换；英文界面不转换 |
| 免费档 20 RPM 偏紧 | 高频用户遇到 429 | 错误信息透传服务端等待时间；不做客户端自动重试（会叠加计费与延迟） |
| 部分地区无法访问 `api.groq.com`，或被 Cloudflare 拦截 | 403 / 超时 | 403 文案提示检查网络地区；`error code: 1010` 单独提示（G-11）；沿用代理设置 |
| 10 秒最短计费 | 短句成本放大 | Turbo 下每次最多约 $0.0001，可以接受；写入产品文档 |
| Groq 下线或更名模型 | 404 | 枚举回退默认值；新模型通过版本更新追加 |
