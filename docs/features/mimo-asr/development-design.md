# Type4Me MiMo-V2.5-ASR 开发设计

> 分支：`feat/211-mimo-asr`
> 文档类型：开发设计
> 文档状态：设计中
> 关联 Issue：#211
> 对应产品设计：`docs/features/mimo-asr/product-design.md`
> 设计日期：2026-08-24
> 官方 API：https://mimo.mi.com/docs/zh-CN/api/audio/Speech-Recognition

## 1. 设计摘要

MiMo-V2.5-ASR 使用 OpenAI Chat Completions 兼容接口，但并不兼容 Type4Me 当前 `OpenAIASRClient` 所使用的 `/audio/transcriptions` multipart 协议。

本次实现新增独立的 MiMo Provider，并复用现有 Batch ASR 生命周期：录音过程中缓存 PCM，`endAudio()` 时构造 WAV、Base64 编码并提交一次 HTTP 请求；响应使用 SSE 文本增量，映射为 `RecognitionTranscript` 事件。

核心原则：

1. Provider capability 必须声明为 `.batch()`；
2. 不修改 `SpeechRecognizer` 协议；
3. 不修改 AudioCaptureEngine 的基础采集格式；
4. 请求协议和 SSE 解析放在独立 Protocol 文件中，可单元测试；
5. Client 只负责生命周期、缓冲、URLSession 和事件发射；
6. API Key 继续走 Keychain；
7. 请求前严格执行 10 MB Base64/Data URL 上限检查；
8. 首版固定 WAV + `mimo-v2.5-asr`；
9. 不把 Type4Me hotwords 或 punctuation 开关硬映射到不存在的 API 字段；
10. 为 Batch Provider 的连接测试避免假阳性。

## 2. 当前架构适配点

Type4Me 当前 ASR 扩展点已经满足需求：

- `ASRProvider`：Provider 稳定枚举；
- `ASRProviderConfig`：动态凭证字段；
- `ASRProviderRegistry`：Config、Client factory 和 capability；
- `SpeechRecognizer`：统一录音生命周期；
- `RecognitionEvent` / `RecognitionTranscript`：统一输出；
- `ASRSettingsCard`：Provider 选择、动态字段、指引和测试；
- `KeychainService`：Secure credential；
- `RecognitionSession`：Batch 与 Streaming capability 的上层适配。

MiMo 不需要引入新的公共抽象。

## 3. 为什么不能复用 OpenAIASRClient

当前 OpenAI ASR 采用：

- Endpoint：`/audio/transcriptions`；
- `multipart/form-data`；
- 文件字段；
- 返回 `{ text: ... }`。

MiMo ASR 采用：

- Endpoint：`https://api.xiaomimimo.com/v1/chat/completions`；
- `application/json`；
- `messages[].content[].type = input_audio`；
- `input_audio.data = data:audio/wav;base64,...`；
- `asr_options.language`；
- 可选 `stream = true`；
- SSE 文本位于 `choices[].delta.content`。

协议差异足够大，不应通过在 `OpenAIASRClient` 中加入供应商条件分支来复用。

## 4. 为什么 capability 是 Batch

虽然官方参数名为 `stream`，它只控制响应输出是否通过 SSE 增量返回。

请求仍然要求完整 Base64 音频在 HTTP body 中一次性提交，因此在 Type4Me 的能力模型中：

```swift
capabilities: .batch()
```

不能使用：

```swift
capabilities: .streaming()
```

这样 `RecognitionSession` 才能保持正确的“录音结束后等待最终 ASR”行为。

## 5. 文件变更规划

### 5.1 新增文件

```text
Sources/Type4Me/ASR/MiMoASRClient.swift
Sources/Type4Me/ASR/Providers/MiMoASRConfig.swift
Sources/Type4Me/Protocol/MiMoASRProtocol.swift
Tests/Type4MeTests/MiMoASRConfigTests.swift
Tests/Type4MeTests/MiMoASRProtocolTests.swift
```

### 5.2 修改文件

```text
Sources/Type4Me/ASR/ASRProvider.swift
Sources/Type4Me/ASR/ASRProviderRegistry.swift
Sources/Type4Me/UI/Settings/ASRSettingsCard.swift
Tests/Type4MeTests/ASRProviderRegistryTests.swift
AGENTS.md
README.md
CHANGELOG.md            # 仅在版本发布流程要求时
```

## 6. ASRProvider

新增：

```swift
case mimo
```

放在 China provider 区域。

显示名称：

```swift
case .mimo:
    return L("小米 MiMo（非实时）", "Xiaomi MiMo (Batch)")
```

不要使用单纯的 `MiMo`，因为用户需要在选择 Provider 时立即知道它不是边录边识别。

## 7. MiMoASRConfig

建议：

```swift
enum MiMoASRLanguage: String, Sendable, CaseIterable {
    case auto
    case zh
    case en
}

struct MiMoASRConfig: ASRProviderConfig, Sendable {
    static let provider = ASRProvider.mimo
    static let displayName = L("小米 MiMo（非实时）", "Xiaomi MiMo (Batch)")
    static let defaultModel = "mimo-v2.5-asr"
    static let endpoint = "https://api.xiaomimimo.com/v1/chat/completions"

    let apiKey: String
    let language: MiMoASRLanguage
}
```

### 7.1 credentialFields

只提供：

```swift
CredentialField(
    key: "apiKey",
    label: "API Key",
    placeholder: "...",
    isSecure: true,
    isOptional: false,
    defaultValue: ""
)

CredentialField(
    key: "language",
    label: L("识别语言", "Language"),
    placeholder: "",
    isSecure: false,
    isOptional: true,
    defaultValue: "auto",
    options: [
        FieldOption(value: "auto", label: L("自动检测", "Auto Detect")),
        FieldOption(value: "zh", label: L("中文", "Chinese")),
        FieldOption(value: "en", label: L("英文", "English")),
    ]
)
```

### 7.2 不暴露 model/baseURL

原因：

- 当前官方只支持 `mimo-v2.5-asr`；
- Base URL 是固定官方服务；
- Type4Me 的“自定义兼容 Endpoint”不是本 Issue 的目标；
- 减少无意义设置和错误配置。

## 8. Registry

注册：

```swift
.mimo: ProviderEntry(
    configType: MiMoASRConfig.self,
    createClient: { MiMoASRClient() },
    capabilities: .batch()
),
```

更新 Registry 测试，确认：

- `.mimo` 可用；
- `.mimo` 支持 Direct mode；
- `.mimo` capability `isStreaming == false`；
- audioInput 使用默认 `.pcmData`。

## 9. Client 生命周期

建议结构：

```swift
actor MiMoASRClient: SpeechRecognizer {
    private var config: MiMoASRConfig?
    private var options = ASRRequestOptions()
    private var session: URLSession?
    private var audioBuffer = Data()
    private var eventContinuation: AsyncStream<RecognitionEvent>.Continuation?
    private var _events: AsyncStream<RecognitionEvent>?
}
```

### 9.1 connect

职责：

1. 类型检查 `MiMoASRConfig`；
2. 保存 config / options；
3. 用 `options.urlSessionConfiguration` 创建 URLSession；
4. 清空 audioBuffer；
5. 重建 AsyncStream；
6. 发 `.ready`；
7. 发“录音中…”占位 transcript。

`connect()` 不做远程鉴权，不应该因为本地 config 可构造就被设置页视为“凭证已验证”。

### 9.2 sendAudio

```swift
func sendAudio(_ data: Data) async throws {
    audioBuffer.append(data)
}
```

第一版不边录边发。

### 9.3 endAudio

流程：

```text
validate config/session
        ↓
validate non-empty PCM
        ↓
optional minimum-duration guard
        ↓
PCM → WAV
        ↓
Base64 / Data URL size check
        ↓
build request(stream=true)
        ↓
URLSession.bytes(for:)
        ↓
parse SSE lines
        ↓
emit partial transcripts
        ↓
emit final transcript
        ↓
emit completed + finish
```

失败路径统一：

```swift
continuation.yield(.error(error))
continuation.yield(.completed)
continuation.finish()
throw error
```

保持与 StepFun Batch 客户端一致。

### 9.4 disconnect

必须：

- finish event stream；
- nil continuation；
- nil cached stream；
- clear audioBuffer；
- `session.invalidateAndCancel()`；
- nil session/config。

## 10. WAV 编码

Type4Me 当前 Batch ASR 已经存在 PCM → WAV 逻辑。MiMo 需要的音频可固定为：

- PCM S16LE；
- mono；
- 16 kHz；
- 16 bit；
- WAV container。

优先考虑把 OpenAIASRClient 内部的 WAV helper 提取成共享的内部工具，例如：

```text
Sources/Type4Me/Audio/WAVEncoder.swift
```

如果本 PR 希望严格控制范围，也可以先在 `MiMoASRProtocol` 内实现等价 helper，但长期不建议复制 RIFF header 逻辑。

建议优先级：

1. 如果提取共享 helper 不影响现有 OpenAI 行为：本 PR 一并提取；
2. 如果会显著扩大 diff：MiMo 先独立实现并建立后续 refactor Issue。

## 11. 请求协议

`MiMoASRProtocol.buildRequest` 输入：

```swift
static func buildRequest(
    wavData: Data,
    config: MiMoASRConfig,
    options: ASRRequestOptions
) throws -> URLRequest
```

实际 `options` 当前只需要 `bypassProxy` 间接体现在 URLSession；hotwords、enablePunc、boostingTableID 不映射到请求体。

建议 JSON：

```json
{
  "model": "mimo-v2.5-asr",
  "messages": [
    {
      "role": "user",
      "content": [
        {
          "type": "input_audio",
          "input_audio": {
            "data": "data:audio/wav;base64,<BASE64>"
          }
        }
      ]
    }
  ],
  "asr_options": {
    "language": "auto"
  },
  "stream": true
}
```

Header：

```text
Content-Type: application/json
api-key: <MIMO_API_KEY>
```

官方同时支持 `Authorization: Bearer <MIMO_API_KEY>` 与 `api-key` 两种鉴权方式，第一版固定使用 `api-key`，减少协议分支。

## 12. 10 MB 限制

官方限制是 Base64 编码后的音频字符串大小上限 10 MB。

实现时不要只检查原 WAV 字节数，因为 Base64 会膨胀约 4/3，Data URL 还有固定前缀。

建议：

```swift
let base64 = wavData.base64EncodedString()
let dataURL = "data:audio/wav;base64,\(base64)"
```

然后检查 UTF-8 字节数。

常量集中定义：

```swift
static let maxEncodedAudioBytes = 10 * 1024 * 1024
```

注意：如果官方文档后续明确“10 MB”按十进制 10,000,000 计算，应以官方实际行为为准。为了避免边界请求失败，可以预留小幅安全余量，例如 9.5 MiB；最终阈值在实现阶段通过真实 API 验证后确定。

错误类型：

```swift
case audioTooLarge(encodedBytes: Int)
```

## 13. SSE 解析

### 13.1 解析原则

MiMo 的 SSE payload 基于 OpenAI Chat Completion chunk。

需要处理：

```text
data: {JSON}
```

以及：

```text
data: [DONE]
```

忽略：

- 空行；
- `event:`；
- 其他 SSE metadata。

### 13.2 模型

建议最小 Decodable：

```swift
struct StreamChunk: Decodable {
    let choices: [Choice]

    struct Choice: Decodable {
        let delta: Delta
        let finishReason: String?

        enum CodingKeys: String, CodingKey {
            case delta
            case finishReason = "finish_reason"
        }
    }

    struct Delta: Decodable {
        let content: String?
    }
}
```

不要为了兼容完整 OpenAI schema 建立庞大模型。

### 13.3 Transcript 发射

维护：

```swift
var accumulatedText = ""
```

每个 delta：

```swift
accumulatedText += delta
continuation.yield(.transcript(... isFinal: false))
```

完成时：

```swift
let finalText = accumulatedText.trimmingCharacters(in: .whitespacesAndNewlines)
continuation.yield(.transcript(... isFinal: true))
```

最终 transcript 的 `authoritativeText` 使用完整 finalText。

### 13.4 完成判定

允许以下任一条件结束：

- `finish_reason == "stop"`；
- 收到 `[DONE]` 且已经得到文本。

如果连接结束但没有任何文本，也没有明确错误，则返回 `invalidResponse`。

## 14. 非流式兼容策略

第一版 Client 固定请求 `stream=true`，因为：

- 能更早展示识别文本；
- 与 StepFun Batch SSE 体验一致；
- 不改变“Batch”能力定义。

Protocol 测试可以同时定义非流式 response model，但首版没有必要实现自动 fallback。

如果未来发现 SSE 在部分代理环境不稳定，再增加：

```text
SSE 失败 → 非流式 JSON retry
```

该 fallback 不应在第一版无证据引入。

## 15. 错误模型

建议：

```swift
enum MiMoASRError: Error, LocalizedError, Equatable {
    case invalidConfig
    case emptyAudio
    case invalidEndpoint
    case audioTooLarge(encodedBytes: Int)
    case requestFailed(code: Int, message: String?)
    case invalidResponse
    case serverError(String)
}
```

HTTP 非 2xx 时读取有界 body，例如最多 1 KB，尝试解析官方 error message，否则回退到状态码。

日志严禁输出 API Key 和完整 request body。

## 16. URLSession 与代理

必须使用：

```swift
URLSession(configuration: options.urlSessionConfiguration)
```

这样 `ProxyBypassMode.current.bypassASR` 能继续生效。

不要直接使用 `URLSession.shared`，否则 MiMo 会绕开现有 ASR 代理绕过设置语义。

请求 timeout 建议 120 秒，与其他 Batch Provider 保持同级。

## 17. Settings 集成

### 17.1 guide links

`ASRSettingsCard.currentASRGuideLinks` 增加 `.mimo`：

- 官方接入文档；
- API Key 页面。

### 17.2 provider note

增加 `.mimo` 提示：

```swift
return L(
    "松开快捷键后提交完整录音；MiMo 的流式模式仅流式返回识别文本，不支持录音期间实时上传。",
    "The complete recording is submitted after you release the hotkey. MiMo streams transcript text only; it does not accept live audio chunks while recording."
)
```

### 17.3 推荐列表

不修改：

```swift
private static let recommendedProviders: [ASRProvider] = [.volcano, .soniox]
```

第一版 MiMo 进入 Others。

## 18. 测试连接问题

当前通用测试流程只调用：

```text
client.connect(...)
client.disconnect()
```

对于 MiMo 这种 `connect()` 不发 HTTP 请求的 Batch Client，这会产生假阳性。

本 Issue 建议同步解决，方案优先级：

### 方案 A：增加 Provider credential validator

在 Registry entry 中增加可选 validator：

```swift
let validateCredentials: (@Sendable (any ASRProviderConfig, ASRRequestOptions) async throws -> Void)?
```

优点：语义最清晰，可逐步用于 OpenAI / StepFun。

缺点：会扩大公共 Registry 结构。

### 方案 B：ASRSettingsCard 对 MiMo 做专用最小请求

优点：改动最小。

缺点：继续增加 Settings 对具体 Provider 的特殊判断。

### 方案 C：暂时禁用 MiMo 测试按钮

优点：不会假成功。

缺点：体验较差。

推荐：**A，如果改动范围可控；否则 C，禁止假阳性。** 不推荐 B。

如果官方不存在免费的鉴权 endpoint，validator 可发送一段极短的合法静音 WAV；实现前需要确认该请求是否产生可忽略费用以及是否会触发最短音频限制。

## 19. Keychain 与持久化

`apiKey`：

```swift
isSecure: true
```

因此自动进入现有 Keychain 存储。

`language`：

```swift
isSecure: false
```

存入 credentials.json。

不增加新的 UserDefaults key。

## 20. 单元测试

### 20.1 MiMoASRConfigTests

覆盖：

- 缺少 API Key → init nil；
- 空白 API Key → init nil；
- 默认 language = auto；
- zh/en 正确解析；
- 非法 language 回退 auto；
- `toCredentials()` round trip。

### 20.2 MiMoASRProtocolTests

覆盖：

- Endpoint；
- POST；
- `api-key` header；
- Content-Type；
- model 固定；
- Data URL 是 `audio/wav`；
- Base64 解码可还原原 WAV；
- `asr_options.language`；
- `stream == true`；
- 不出现 hotwords；
- 不出现 enable_punc；
- 超限音频抛 `audioTooLarge`；
- SSE delta 解析；
- 多 choices 时只消费 index 0 或明确选择第一项；
- finish_reason；
- `[DONE]`；
- malformed JSON；
- server error body。

### 20.3 RegistryTests

覆盖 `.mimo`：

- available；
- batch；
- direct supported；
- createClient 非 nil。

## 21. Client 测试策略

如果当前测试基础设施允许 URLProtocol stub，增加：

1. connect 发 ready；
2. sendAudio 缓存数据；
3. endAudio 收到两段 SSE delta；
4. 发出 partial transcript；
5. 最终 final transcript；
6. completed；
7. HTTP 401 进入 error；
8. disconnect 清理 session。

如果现有 Client 测试没有网络 stub 基础设施，首 PR 至少保证 Protocol + Config + Registry 的纯单元测试，真实 Client 使用手工集成测试补充。

## 22. 手工集成测试

需要真实 MiMo API Key：

### 中文

- language=zh；
- 5~10 秒正常中文；
- 检查标点、首字和最终注入。

### 英文

- language=en；
- 检查英文标点与大小写。

### Auto

- 中文；
- 英文；
- 中英混合。

### 方言

至少尝试一段粤语或四川话，仅记录实际表现，不把单次测试结果写成产品保证。

### 网络异常

- 无效 Key；
- 断网；
- 超时；
- 代理绕过开/关。

### 长音频

生成接近限制和超过限制的 PCM，验证边界。

## 23. 构建与回归

实现后至少执行：

```bash
swift test
swift build
```

如果全量测试成本过高，先运行新增测试和 `ASRProviderRegistryTests`，随后再跑全量。

重点回归：

- OpenAI Batch ASR；
- StepFun Batch ASR；
- Volcano/Deepgram Streaming ASR；
- ASR Settings provider picker；
- Keychain credential save/load；
- Direct mode；
- LLM mode。

## 24. 实现顺序

1. 增加 `ASRProvider.mimo`；
2. 增加 `MiMoASRConfig`；
3. 增加 `MiMoASRProtocol` + tests；
4. 增加 `MiMoASRClient`；
5. Registry 注册为 batch；
6. Settings links/note；
7. 解决 MiMo 测试连接假阳性；
8. Registry / Config tests；
9. 真实 API 集成测试；
10. README / AGENTS provider 清单更新；
11. build + test；
12. 更新 Issue / PR 验收说明。

## 25. 风险与决策记录

### 风险 1：用户误解 SSE 为实时 ASR

缓解：Provider 名称、设置说明、capability 三层都明确 Batch。

### 风险 2：10 MB 限制

缓解：请求前本地检查；首版不分片。

### 风险 3：Batch 测试按钮假成功

缓解：实现 validator 或禁用错误的成功反馈。

### 风险 4：官方 API schema 演进

缓解：Protocol 最小解码，不依赖无关字段；模型、endpoint 常量集中。

### 风险 5：方言能力与营销描述不一致

缓解：UI 不提供方言准确率承诺；只暴露官方明确 API language code。

### 风险 6：Base64 内存峰值

同一时间可能同时存在 PCM、WAV、Base64 String 和 JSON body。正常短录音影响有限，但接近 10 MB 上限时会显著放大内存。

实现时应避免不必要的中间副本。若后续真实数据表明峰值明显，再考虑流式 Base64 encoder 或更紧的本地录音时长上限。

## 26. 第一版最终技术决策

| 项目 | 决策 |
|---|---|
| Provider | 独立 `.mimo` |
| Capability | Batch |
| Model | 固定 `mimo-v2.5-asr` |
| Endpoint | 固定官方 `/v1/chat/completions` |
| Audio | 16 kHz / 16-bit / mono WAV |
| Upload | 完整音频 Base64 Data URL |
| Response | SSE |
| Language | auto / zh / en |
| Hotwords | 不支持 |
| Punctuation toggle | 不支持 |
| Long audio | 本地拒绝，首版不分片 |
| Credentials | API Key in Keychain |
| Proxy bypass | 复用 ASRRequestOptions |
| Recommendation | 首版不进入推荐列表 |
| Test button | 不允许仅 connect() 就显示成功 |
