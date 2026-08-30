# Type4Me Gemini ASR Provider 开发设计

> 文档类型：开发设计
> 文档状态：当前有效（已实现，持续验证）
> 设计日期：2026-08-27
> 最后校验：2026-08-30
> 实现基线：`c82aa2b`
> 对应产品设计：[product-design.md](product-design.md)
> 官方 Live Transcription 文档：https://ai.google.dev/gemini-api/docs/live-api/live-transcribe
> 官方 API Reference：https://ai.google.dev/api/generate-content

## 1. 设计摘要

本次新增独立的 **Gemini** 实时 ASR Provider，使用 Gemini Live API 的 WebSocket `BidiGenerateContent` 接口。Provider 名是厂商名 `Gemini`；具体模型是它下面的一层可选配置，首版默认 `gemini-3.5-transcribe-live`（见 §7.2）。

Type4Me 现有 `SpeechRecognizer`、`ASRProviderRegistry`、`RecognitionTranscript`、实时 PCM 上传和 streaming teardown 已经能承载该模型，因此第一版不增加新的公共 ASR 抽象。

核心技术决策：

1. 新增独立 `ASRProvider.gemini`，不复用 `.google`；
2. Registry capability 使用 `.streaming()`；
3. 直接使用 `URLSessionWebSocketTask`，不引入 Google Gen AI SDK；
4. 模型固定 `gemini-3.5-transcribe-live`；
5. WebSocket 使用官方 `v1beta` BidiGenerateContent endpoint；
6. setup 使用 `responseModalities = [TEXT]`；
7. 使用 Manual VAD，关闭 automatic activity detection；
8. 第一段真实音频发送前发 `activityStart`，`endAudio()` 发 `activityEnd`；
9. interim transcript 映射到 `partialText`；finalized transcript 映射到 `confirmedSegments`；
10. Type4Me 当前 200ms PCM chunk 在 Gemini Client 内拆成约 100ms payload，不改 `AudioCaptureEngine`；
11. HotwordStorage 映射到 `customVocabulary`；
12. Smart / Verbatim 作为 Provider config；
13. API Key 继续使用 Keychain；
14. `connect()` 必须等待 WebSocket open + `setupComplete` 后才算 ready；
15. 不记录带 API Key 的完整 WebSocket URL；
16. `endAudio()` 在无音频时静默返回，不抛错（§16.1）；
17. `activityEnd → final` 有 2s 硬性预算（快速路径 1s，§16.2）；
18. 沿用现有 batch fallback 路径，但 `sendAudio` 内需节流（§16.3）；
19. setup / 消息字段命名已对照官方 SDK `googleapis/python-genai` 核实完毕并锁定（§4.1）。

## 2. 当前 Type4Me 架构适配

现有扩展点：

- `ASRProvider`：稳定 Provider ID；
- `ASRProviderConfig`：动态凭证和非安全参数；
- `ASRProviderRegistry`：Config / Client / Capability / validation；
- `SpeechRecognizer`：`connect → sendAudio → endAudio → disconnect`；
- `RecognitionTranscript`：confirmed / partial / authoritative / final；
- `RecognitionSession`：Streaming provider 自动持续调用 `sendAudio()`；
- `AudioCaptureEngine`：16 kHz / 16-bit / mono PCM；
- `HotwordStorage`：统一 ASR 热词来源；
- `ASRSettingsCard`：Provider Picker、字段渲染、指引和测试连接；
- `KeychainService`：secure credential。

Gemini 不需要修改 `SpeechRecognizer` protocol。

## 3. 为什么不能复用现有 Google Provider

当前 `.google`：

- display name：`Google Cloud STT`；
- Config：`GoogleASRConfig`；
- credential：Service Account JSON；
- Registry：`createClient = nil`；
- 语义：传统 Google Cloud Speech-to-Text。

Gemini Transcribe：

- 产品：Gemini Developer API；
- credential：Gemini API Key；
- endpoint：`generativelanguage.googleapis.com`；
- protocol：Gemini Live API WebSocket；
- model：`gemini-3.5-transcribe-live`；
- feature：Smart transcription / custom vocabulary / Live VAD。

如果复用 `.google`，会导致 persisted provider ID、credential schema 和产品命名发生语义冲突。

因此新增：

```swift
case gemini
```

## 4. 官方协议事实

第一版依赖以下官方约束：

- Model：`gemini-3.5-transcribe-live`；
- Transport：WebSocket；
- Endpoint：`wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent`；
- Input：raw 16-bit PCM；
- 推荐采样率：16 kHz；
- Channel：mono；
- 推荐 chunk：约 100ms；
- MIME：`audio/pcm;rate=16000`；
- Interim field：`serverContent.interimInputTranscription`；
- Final field：`serverContent.inputTranscription`；
- Auto language：`languageCodes: []`；
- Custom vocabulary：最多 1,000 项；
- Mode：`SMART` / `VERBATIM`；
- Live session 最大时长：10 分钟；
- Manual VAD：关闭 automatic activity detection 后使用 `activityStart` / `activityEnd`。

### 4.1 字段命名核实结果（已完成，2026-08-27）

本文档中的 JSON 字段名已对照官方 SDK `googleapis/python-genai`（`google/genai/_live_converters.py`、`google/genai/types.py`，main 分支）逐条核实完毕，**全部与本文档采用的命名一致**，未发现需要改名的项：

| 位置 | 采用命名 | 核实来源 | 结论 |
|---|---|---|---|
| setup 转写配置对象 | `setup.inputAudioTranscription` | `_LiveClientSetup_to_mldev` | ✅ 确认 |
| 转写配置字段 | `languageCodes` / `customVocabulary` / `mode` | `AudioTranscriptionConfig` | ✅ 确认，`mode` 取值 `VERBATIM` \| `SMART`，省略时服务端默认 `VERBATIM` |
| response modalities 层级 | `setup.generationConfig.responseModalities` | `_LiveClientSetup_to_mldev` | ✅ 确认（非 setup 根层） |
| 手动 VAD 开关 | `setup.realtimeInputConfig.automaticActivityDetection.disabled` | `RealtimeInputConfig` / `AutomaticActivityDetection` | ✅ 确认 |
| 实时音频负载 | `realtimeInput.audio`（Blob `{data, mimeType}`） | `_LiveClientRealtimeInput_to_mldev` | ✅ 确认；`mediaChunks` 为旧版命名，两者并存 |
| turn 结束信号 | 仅 `realtimeInput.activityEnd` | `audio_stream_end` 字段说明 | ✅ 确认；SDK 明确 `audioStreamEnd` **只能在自动 VAD 启用时发送**，本方案用手动 VAD，故不得发送 |
| interim / final 字段 | `serverContent.interimInputTranscription` / `serverContent.inputTranscription` | `LiveServerContent` | ✅ 确认，interim 描述为 "Low latency transcription updated while the user is speaking" |
| setup ack | `setupComplete` | `LiveServerMessage` | ✅ 确认 |

另确认：自动语言检测传 `languageCodes: []`（或省略）是官方明确支持的写法。

字段名仍全部集中在 `GeminiTranscribeProtocol` 内，使后续 API 演进只影响单文件。

## 5. 文件变更规划

### 5.1 新增文件

```text
Type4Me/ASR/GeminiASRClient.swift
Type4Me/ASR/GeminiConnectionGate.swift
Type4Me/ASR/Providers/GeminiASRConfig.swift
Type4Me/Protocol/GeminiTranscribeProtocol.swift
Type4MeTests/GeminiASRClientTests.swift
Type4MeTests/GeminiASRConfigTests.swift
Type4MeTests/GeminiLocalizationTests.swift
Type4MeTests/GeminiTranscribeProtocolTests.swift
```

`GeminiConnectionGate.swift` 同时承载连接 gate、`GeminiCloseTracker` 与 `URLSessionWebSocketDelegate`（§24.1）。

### 5.2 修改文件

```text
Type4Me/ASR/ASRProvider.swift
Type4Me/ASR/ASRProviderRegistry.swift
Type4Me/Session/RecognitionSession.swift
Type4Me/UI/Settings/ASRSettingsCard.swift
Type4MeTests/ASRProviderRegistryTests.swift
AGENTS.md
README.md
```

`RecognitionSession.swift` 的改动只有一处：在 `currentASREndpoint()` 中补 `.gemini` 分支（见 §13.1）。识别流程本身不需要修改。

`CHANGELOG.md` 只在对应发布流程中更新。

## 6. ASRProvider

新增到 International 区域：

```swift
case gemini
```

显示名：

```swift
case .gemini:
    return "Gemini"
```

Provider 名固定为厂商名 `Gemini`，**不带模型版本**。具体模型（当前为 `gemini-3.5-transcribe-live`）是 provider 下的一个可选项，见 §7.2，这样后续 Google 增加新的转写模型时无需新增 provider。

不要将 `.google` 改名为 Gemini，也不要迁移已有 `.google` credential。

## 7. GeminiASRConfig

建议定义：

```swift
enum GeminiTranscriptionMode: String, Sendable, CaseIterable {
    case smart = "SMART"
    case verbatim = "VERBATIM"
}

struct GeminiASRConfig: ASRProviderConfig, Sendable {
    static let provider = ASRProvider.gemini
    static let displayName = "Gemini"

    static let supportedModels: [(id: String, label: String)] = [
        ("gemini-3.5-transcribe-live", "Gemini 3.5 Transcribe (Live)"),
    ]
    static let defaultModel = "gemini-3.5-transcribe-live"

    static let webSocketBaseURL = "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"

    let apiKey: String
    let model: String
    let mode: GeminiTranscriptionMode
    let languageCode: String
}
```

### 7.1 credentialFields

API Key：

```swift
CredentialField(
    key: "apiKey",
    label: "API Key",
    placeholder: "...",
    isSecure: true,
    isOptional: false,
    defaultValue: ""
)
```

Mode：

```swift
CredentialField(
    key: "mode",
    label: L("转写模式", "Transcription Mode"),
    placeholder: "",
    isSecure: false,
    isOptional: true,
    defaultValue: "SMART",
    options: [
        FieldOption(value: "SMART", label: L("智能整理", "Smart")),
        FieldOption(value: "VERBATIM", label: L("逐字转写", "Verbatim")),
    ]
)
```

Language：

```swift
CredentialField(
    key: "languageCode",
    label: L("语言提示", "Language Hint"),
    placeholder: L("BCP-47，例如 en-US", "BCP-47, e.g. en-US"),
    isSecure: false,
    isOptional: true,
    defaultValue: "auto",
    options: [
        FieldOption(value: "auto", label: L("自动检测", "Auto Detect")),
        FieldOption(value: "cmn-Hans-CN", label: L("中文（普通话）", "Mandarin Chinese")),
        FieldOption(value: "yue-Hant-HK", label: L("粤语", "Cantonese")),
        FieldOption(value: "en-US", label: "English (US)"),
        FieldOption(value: "ja-JP", label: "日本語"),
        FieldOption(value: "ko-KR", label: "한국어"),
    ],
    allowCustomInput: true
)
```

### 7.2 模型选择（provider 与 model 解耦）

Provider 是厂商（`Gemini`），模型是 provider 下的一层选择。设置页字段顺序为 **API Key → 模型 → 转写模式 → 语言提示**。

- `model` 是非 secure、可选字段，落在 `credentials.json`，缺省或留空时回退 `defaultModel`；
- 字段带下拉选项，同时 `allowCustomInput: true`，便于新模型上线时用户先手填、我们再补进 `supportedModels`；
- 新增模型只需往 `supportedModels` 追加一行，**不新增 ASRProvider case，也不影响已保存的凭据**；
- Gemini 要求完全限定名 `models/<id>`。用户可能粘贴任一形式，统一由 `GeminiTranscribeProtocol.qualifiedModelName(_:)` 归一化：去掉已有 `models/` 前缀、trim 空白、为空时回退默认模型，再补上前缀，避免出现 `models/models/...`；
- 若将来某个模型不支持流式，再在 `ASRProviderRegistry.capabilities` 里按模型细分，本版不提前抽象。

### 7.3 config normalization

`init?(credentials:)`：

- apiKey trim 后不能为空；
- model 缺省或 trim 后为空回退 `defaultModel`；
- mode 非法值回退 `.smart`；
- language 为空回退 `auto`；
- custom BCP-47 只做 trim，不在客户端维护完整语言白名单。

理由：Google 支持语言列表会变化，不应把 85+ code 复制成 Type4Me 的长期 hard-coded validation source。

## 8. Registry

注册：

```swift
.gemini: ProviderEntry(
    configType: GeminiASRConfig.self,
    createClient: { GeminiASRClient() },
    capabilities: .streaming()
),
```

不需要自定义 `validateCredentials` closure。

当前 Registry 的通用 fallback 会：

```text
createClient
→ connect(config, options)
→ disconnect()
```

Gemini `connect()` 会真实执行 WebSocket handshake 和 setup，因此足以验证凭证和模型可访问性。

Registry 测试确认：

- isAvailable == true；
- isStreaming == true；
- supportsRealtimeRecognition == true；
- audioInput == .pcmData；
- Direct mode supported。

## 9. WebSocket 建连

### 9.1 URL

官方原生 WebSocket 示例使用：

```text
wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent?key=<API_KEY>
```

第一版遵循官方示例使用 query API Key。

安全要求：

- 不把 `url.absoluteString` 写入日志；
- Debug log 只记录 host、model 和匿名状态；
- error description 不回显 URL query；
- `URLRequest` 不进入通用 debug dump。

如果后续官方明确支持并推荐 WebSocket `x-goog-api-key` header，可单独迁移以降低 URL 泄露风险。

### 9.2 URLSession

必须使用：

```swift
URLSession(
    configuration: options.urlSessionConfiguration,
    delegate: delegate,
    delegateQueue: nil
)
```

这样继续支持现有 ASR proxy bypass 与测试注入。

不要使用 `URLSession.shared`。

### 9.3 cloudProxyURL

`ASRRequestOptions.cloudProxyURL` 只服务于 `HAS_CLOUD_SUBSCRIPTION` 下的 `.cloud` provider。Gemini 是 BYOK Provider，**必须忽略该字段**，始终连接官方 endpoint，不提供自定义 Base URL（与产品设计 §4 非目标一致）。

## 10. Connection Gate

Gemini 不能在 WebSocket `didOpen` 后立即视为 ready，因为协议要求首先发送 setup，并等待服务端 `setupComplete`。

建议 gate 状态：

```text
connecting
→ socketOpen
→ setupSent
→ setupComplete
→ ready
```

`connect()` 成功条件：

1. WebSocket handshake 成功；
2. setup message 成功发送；
3. 收到 `setupComplete`；
4. receive loop 已启动。

建议 timeout：5 秒。

错误路径：

- handshake failure；
- socket close before setup；
- setup error payload；
- setup timeout。

可以参考 `DeepgramConnectionGate` 结构，但不要把 Deepgram 类型直接复用到 Gemini。

## 11. Setup Message

推荐 setup：

```json
{
  "setup": {
    "model": "models/gemini-3.5-transcribe-live",   // 实际取自 config.model，见 §7.2
    "generationConfig": {
      "responseModalities": ["TEXT"]
    },
    "realtimeInputConfig": {
      "automaticActivityDetection": {
        "disabled": true
      }
    },
    "inputAudioTranscription": {
      "languageCodes": [],
      "customVocabulary": ["Type4Me", "SwiftUI"],
      "mode": "SMART"
    }
  }
}
```

### 11.1 languageCodes

如果 config 为 `auto`：

```json
"languageCodes": []
```

否则：

```json
"languageCodes": ["cmn-Hans-CN"]
```

第一版只发送 0 或 1 个语言提示。

### 11.2 customVocabulary

来源：

```swift
options.hotwords
```

处理：

1. trim whitespace/newline；
2. 丢弃空字符串；
3. 保序去重；
4. 最多取 1,000 项。

不要把 `boostingTableID` 映射到 Gemini。

日志只记录 count。

### 11.3 mode

直接映射：

```text
.smart    → SMART
.verbatim → VERBATIM
```

`enablePunc` 不映射，因为 Gemini Live Transcription 没有对应布尔字段。

## 12. 为什么使用 Manual VAD

Type4Me 是明确的 Push-to-Talk / Toggle-to-Talk 交互，客户端天然知道：

- 什么时候开始说；
- 什么时候结束录音。

官方 Manual VAD 正好允许关闭自动 VAD，然后由客户端发送 `activityStart` / `activityEnd`。

优势：

- 松手即可 finalization；
- 不需要额外等待服务端 silence timeout；
- 不会因用户讲话中间的自然停顿提前结束一个 Type4Me recording turn；
- 与现有快捷键语义一致。

## 13. activityStart 的发送时机

不要在 `connect()` 中发送 `activityStart`。

原因：`RecognitionSession` 在录音开始时会先完成 `connect()`，再等待音频引擎产出第一段有效 PCM，两者之间存在可观的空档；此外 `connect()` 也可能因为重试或 mode 切换而先于真正说话发生。如果在 `connect()` 内就声明 activity 开始，会在没有任何语音的情况下开启一个 turn，浪费 session 时长（Gemini 10 分钟上限从 session 建立起算，见 §25），也可能产生空 final。

需要澄清一个容易误解的点：Type4Me 的 `warmUpASRConnection()` **并不预建 ASR WebSocket**，它只是对 provider 域名发一次 `HEAD` 请求预热 DNS/TLS（见 §13.1）。所以这里的风险不是“复用了预热连接”，而是“connect 早于第一段真实音频”。

Gemini Client 维护：

```swift
private var didStartActivity = false
```

第一段非空 PCM 进入 `sendAudio()` 时：

```text
if !didStartActivity
  → send activityStart
  → didStartActivity = true
send audio payload
```

这样连接建立与语音起点解耦，不会产生空 turn。

### 13.1 warm-up endpoint

`RecognitionSession.currentASREndpoint()` 目前只为 volcano / stepfunBatch / soniox / deepgram 返回域名，其余走 `default: ""`，即完全不预热。Gemini 必须补一条，否则每次录音都要重新付 DNS + TLS 的冷启动成本：

```swift
case .gemini:
    return "https://generativelanguage.googleapis.com"
```

该预热只做 `HEAD` 请求，不携带 API Key，不建立 WebSocket。

## 14. Audio 输入与 100ms rechunk

当前 `AudioCaptureEngine`：

```text
sampleRate      = 16000
channels        = 1
format          = Int16 PCM
chunkDurationMs = 200
samplesPerChunk = 3200
chunkByteSize   = 6400
```

Gemini 官方推荐约 100ms、1,024~2,048 frames。

因此不要修改全局 `AudioCaptureEngine`，而在 Gemini Client 内将每个 6,400-byte / 200ms chunk 拆为两个约 3,200-byte / 100ms 子块。

建议常量：

```swift
private static let targetFramesPerPayload = 1600
private static let bytesPerSample = 2
private static let targetPayloadBytes = 3200
```

### 14.1 residual buffer

虽然当前上游 chunk 固定为 6,400 bytes，Client 仍应实现小型 residual buffer，避免未来 capture chunk 调整后破坏协议：

```text
append incoming data
while buffer >= 3200 bytes
  pop 3200
  send payload
endAudio 时 flush residual even if < 3200
```

不做重采样，不改变样本内容。

## 15. Audio Message

每个约 100ms 子块编码为 Base64 后发送：

```json
{
  "realtimeInput": {
    "audio": {
      "data": "<BASE64_PCM>",
      "mimeType": "audio/pcm;rate=16000"
    }
  }
}
```

Client 不持久化 Base64 string；构造后立即发送并释放临时对象。

## 16. endAudio

`endAudio()`：

1. 若 residual audio 非空，先 flush；
2. 如果从未发送过有效音频（`didStartActivity == false`），直接返回，**不抛错**；
3. 若 activity 已开始，发送：

```json
{
  "realtimeInput": {
    "activityEnd": {}
  }
}
```

4. 设置 `didEndAudio = true`；
5. 不立即 cancel WebSocket；
6. 等 receive loop 收到 finalized transcript；
7. 由现有 RecognitionSession 在 final / cleanup 后调用 `disconnect()`。

### 16.1 为什么 endAudio 不能抛 emptyAudio

`GeminiASRError.emptyAudio` 仍保留在错误模型中（供 §16.3 batch fallback 等调用方显式传入空音频的场景使用），但 `endAudio()` 不得抛它。

原因是 `RecognitionSession` 的 teardown 会这样消费返回值：

```text
endAudioOK = withTimeout(3s) { try await client.endAudio() }
if !endAudioOK → asrTeardownClean = false
                → streamingFailed = true
                → 可能触发 batch fallback
```

也就是说，从 `endAudio()` 抛错等价于宣告"本次流式识别失败"。对于用户只是按下快捷键没说话的正常场景，这会触发一次毫无意义的 batch fallback。现有流式 client（如 `DeepgramASRClient.endAudio()`）在这种情况下都是静默返回，Gemini 必须保持一致。

空录音本身由 `RecognitionSession` 的既有空结果分支处理，不需要 ASR 层报错。

### 16.2 endAudio 后的 final 时间预算（硬性）

teardown 的实际预算不是"尽快"，而是明确的数字：

| 阶段 | 超时 |
|---|---|
| `endAudio()` 本身（streaming provider） | 3s |
| `endAudio()` 后等待 `isFinal` | 2s |
| 已有流式文本的 phase-2 快速路径等待 `isFinal` | 1s |
| 超时后的全量 event drain | 5s |

含义：

- `activityEnd` 到 final transcript **必须稳定在 2s 内**，phase-2 路径下应争取 1s 内；
- 超出后会退化到 5s 全量 drain，并把 `asrTeardownClean` 置为 false，进而可能触发 batch fallback，用户侧表现为明显卡顿；
- 因此 §31 手工集成测试必须实测并记录 `activityEnd → final` 的 P50 / P95；
- 若实测 P95 > 2s，不能靠放宽 Type4Me 超时来解决，应先回头确认是否误用了 Manual VAD 或漏发了 turn 结束信号。

### 16.3 batch fallback 路径

`RecognitionSession.attemptBatchFallback` 对非 Soniox provider 会用同一个 provider 重跑一次：

```text
createClient
→ connect(config, ASRRequestOptions(enablePunc: true))
→ sendAudio(整段录音)
→ endAudio()
→ 等待 transcript.isFinal
```

对 Gemini 有三点必须注意：

1. **单次 `sendAudio` 会传入整段录音**（可能数 MB）。§14 的 residual buffer 循环保证了拆分正确性，但会一次性把数百个 100ms payload 无间隔灌入一个实时端点，可能触发服务端限流或降低识别质量。第一版要求：Gemini Client 在 `sendAudio()` 内对连续 payload 做轻量节流（每个 payload 之间让出一次调度，或按不低于 20× 实时速率发送），避免瞬间突发。
2. **该路径的 `ASRRequestOptions` 不带热词**（`hotwords` 为空），因此 fallback 结果不享受 `customVocabulary`。这是现有全局行为，第一版不改，但需在 §31 记录差异。
3. 该路径只接受 `transcript.isFinal == true` 的结果。由于它显式调用了 `endAudio()`，§17.2 的 `isFinal = didEndAudio` 规则天然满足，无需特例。

如果实测表明整段灌入会稳定触发 Gemini 限流，则第一版改为让 Gemini 退出通用 batch fallback（fallback 直接返回 nil），而不是引入重试放大限流。

第一版 Manual VAD 不额外发送 `audioStreamEnd`，避免同时混用两种 turn-finalization 机制。若真实 API 测试表明 `activityEnd` 后仍需要 `audioStreamEnd`，再基于官方行为修正文档和实现。

## 17. Server Message 解析

Protocol 层只建立最小 JSON model。

需要识别：

```text
setupComplete
serverContent.interimInputTranscription.text
serverContent.inputTranscription.text
error
```

不要完整复制 Gemini Live API 的所有 Agent / tool / audio response schema。

### 17.1 Interim

收到：

```text
serverContent.interimInputTranscription.text
```

映射为：

```swift
RecognitionTranscript(
    confirmedSegments: confirmedSegments,
    partialText: interimText,
    authoritativeText: confirmedSegments.joined() + interimText,
    isFinal: false
)
```

每次 interim 替换上一个 partial，不追加。

### 17.2 Finalized

收到：

```text
serverContent.inputTranscription.text
```

Manual VAD 下预期 final 主要在 `activityEnd` 后产生。

处理：

1. normalize segment spacing；
2. append 到 `confirmedSegments`；
3. clear partial；
4. authoritativeText = confirmedSegments.joined()；
5. `isFinal = didEndAudio`。

为什么不对所有 `inputTranscription` 都强制 `isFinal = true`：

- Type4Me 的 `RecognitionSession` 把 `isFinal` 视为整次 recording 已完成的强信号；
- 如果未来 Gemini 在 activity 期间也产生 finalized sub-segment，提前标 final 会导致上层过早开始 teardown / LLM。

因此只有已经执行 `endAudio()` 后收到的 authoritative transcription 才标记整次 `isFinal = true`。

## 18. Transcript 去重与拼接

复用现有 streaming 原则：

- `confirmedSegments` 独立保存；
- interim 只作为 current partial；
- final append 一次；
- 相同 transcript 不重复 yield；
- CJK 不强制空格；
- Latin segment 之间按现有 CharacterExtensions 规则补空格；
- Smart 模式 final 以服务端清理后的文本为权威。

可以抽取 Deepgram 的 segment normalize helper；如果会扩大首版 diff，也可以在 Gemini Protocol 内实现等价私有函数。

## 19. Client 结构

建议：

```swift
actor GeminiASRClient: SpeechRecognizer {
    private var webSocketTask: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var session: URLSession?
    private var delegate: GeminiWebSocketDelegate?
    private var connectionGate: GeminiConnectionGate?

    private var eventContinuation: AsyncStream<RecognitionEvent>.Continuation?
    private var _events: AsyncStream<RecognitionEvent>?

    private var confirmedSegments: [String] = []
    private var lastTranscript: RecognitionTranscript = .empty
    private var residualAudio = Data()
    private var didStartActivity = false
    private var didEndAudio = false
}
```

## 20. connect 生命周期

流程：

```text
validate GeminiASRConfig
→ rebuild AsyncStream
→ build redaction-safe WebSocket request
→ URLSessionWebSocketTask.resume()
→ wait didOpen
→ start receive loop
→ send setup
→ wait setupComplete
→ reset transcript/audio state
→ emit .ready
```

注意顺序：receive loop 必须在等待 setupComplete 前开始，否则没有消费者处理服务端 setup ack。

## 21. sendAudio 生命周期

```text
ignore empty data
→ append residual buffer
→ if first real audio: send activityStart
→ while >= 3200 bytes:
     pop 3200
     base64 encode
     send realtimeInput.audio
     if 本次调用已连续发送多个 payload: yield / 轻量节流（见 §16.3）
→ update counters
```

正常录音时每次 `sendAudio()` 只会产生 2 个 payload，节流不生效；只有 batch fallback 一次性传入整段录音时才会命中。

WebSocket send 失败：

- 抛出错误给 RecognitionSession；
- receive side 同时发 `.error` 时需要避免双重 completed；
- 让现有 streaming recovery 有机会接管。

## 22. disconnect

必须：

- cancel receiveTask；
- WebSocket normal closure；
- invalidate URLSession；
- finish event stream；
- nil continuation / stream；
- clear gate/delegate；
- clear confirmed / partial state；
- clear residual audio；
- reset activity flags；
- 不保留 API Key 的 URLRequest 副本。

## 23. Error Model

建议：

```swift
enum GeminiASRError: Error, LocalizedError, Equatable {
    case invalidConfig
    case invalidEndpoint
    case handshakeTimedOut
    case setupTimedOut
    case setupRejected(String?)
    case emptyAudio
    case closedBeforeSetup(code: Int, reason: String?)
    case closed(code: Int, reason: String?)
    case quotaExceeded(String?)
    case sessionLimitReached
    case invalidResponse
}
```

`emptyAudio` 仅用于 batch fallback 等“调用方明确传入了空音频”的场景，**不得**从正常录音的 `endAudio()` 抛出（见 §16.1）。

`sessionLimitReached` 用于服务端因 10 分钟 session 上限关闭连接的可判定场景（§25.1）。

### 23.1 服务端 error payload

Gemini Live API error schema 只解析需要展示的字段，不建立庞大错误模型。

对错误文本：

- 最多保留有界长度，例如 1 KB；
- 去除疑似 API Key / URL query；
- 用户可见信息映射到中英文 LocalizedError；
- 原始 JSON 不写 debug log。

## 24. WebSocket Close Handling

参考 Deepgram 的 close tracker，但区分：

- setup 前关闭：连接失败；
- recording 中异常关闭：stream error；
- endAudio 后正常关闭：如果 final 已收到可视为完成；
- endAudio 后关闭但无 final：返回 invalid response / interrupted。

不要把所有 post-handshake close 都视为成功。

### 24.1 实现约定（已落地）

Gemini Live 的大多数失败（配额、session 上限、服务端内部错误）以 **close 帧**而非 JSON `{"error": …}` body 到达，因此 close 通道是主要失败通道，必须接线：

- `GeminiCloseTracker`（对齐 `DeepgramCloseTracker`）记录 setup 完成**之后**的首个异常终止；
- `GeminiWebSocketDelegate.didCloseWith`：`gate.isReady == true` 时写入 tracker，否则走 `closedBeforeSetup` 让 `connect()` 失败；
- `didCompleteWithError`：同时写入 tracker 与 gate，覆盖无 close 帧的传输层断开；
- `GeminiASRError.unexpectedClose(code:reason:)` 忽略 `normalClosure` / `goingAway` / `noStatusReceived`，其余映射为 `.closed(code:reason:)`；reason 同时命中 session/duration/connection 与 limit/exceed/maximum 类关键字时映射为 `.sessionLimitReached`；
- receive loop 的终止分支：**先** `consumeCloseError()`，有值则 `emit(.error(…))`；无值但本次会话从未发出过 final（`didEmitFinal == false`）同样 `emit(.error(…))`；最后才 `emit(.completed)`。

判定基准是「本次会话是否已交付 final」，而不是「是否发过音频」。只发 `.completed` 会让 `RecognitionSession` 把截断的 partial 当成最终结果注入：不触发 `beginStreamRecovery`，`needsBatchFallback` 因 `lastStreamingError == nil` 且 `hasUsableStreamingResult == true` 而为 false，用户得到静默截断的文本。

## 25. 10 分钟 Session 限制

第一版不自动 rollover。

### 25.1 与 Type4Me 自身录音上限的关系

`RecognitionSession.maxRecordingDuration` 目前是 600 秒，与 Gemini 的 10 分钟 session 上限数值相同，但**两者的起点不同**：

- Type4Me 的 600 秒从**录音开始**计时；
- Gemini 的 10 分钟从 **WebSocket session 建立（`connect()`）** 起算，早于第一段音频。

因此在长录音场景下，Gemini 一定先于 Type4Me 自身的上限被服务端关闭，600 秒这道保护对 Gemini 实际上永远不会先生效。

第一版处理（已落地，与初稿方案不同）：

- `RecognitionSession` 的录音上限改为 **provider 相关**：`maxRecordingDuration(for:)` 对 `.gemini` 返回 **570 秒（9 分 30 秒）**，其余 provider 仍为 600 秒；
- 该定时器与 Gemini 的 session 时钟同源（都在 ASR 连接建立后起算），570 < 600 留有 30 秒余量，Type4Me 因此**总是先于服务端关闭主动收尾**；
- 收尾走既有的 `stoppedByMaxDuration` 路径，复用已本地化的「已达最大时长 / Max duration reached」提示，**不新增 UI 组件、不新增事件类型**；
- 万一服务端仍抢先关闭，§24.1 的 close tracker 会把它映射为 `.sessionLimitReached` 并触发恢复流程，用户不会静默丢字；
- 不自动重连；文档与设置页统一表述为「单次实时识别约 10 分钟」，不承诺精确到秒。

**放弃初稿的「9 分 30 秒发一次提示」方案的原因**：录音进行中没有可用的非中断提示通道——`RecognitionEvent.error` 会触发 `beginStreamRecovery` 打断录音，`recoveryPrompt` / `macActionResult` 会重置热键状态，`processingLabelOverride` 在 `stopRecording()` 时被清空。主动提前收尾比新增一条 UI 通道更简单，且用户可感知的结果更好。

Client 记录 connect / start activity 时间，同时用于诊断。

如果服务端因为 session limit 主动关闭：

- 识别为可理解的 session limit 错误（如果 reason 可判定）；
- 不把当前 partial 当作完整 final；
- 让现有恢复机制保留可恢复路径；
- UI 提示用户单次 Gemini Live 录音最长约 10 分钟。

后续 rollover 需要独立设计：

```text
finalize segment
→ reconnect
→ activityStart
→ continue audio
→ merge transcript
```

不在首版实现。

## 26. Rate Limits 与 Free Tier

Rate limit 属于 Google Project / Usage Tier，不在客户端硬编码 RPM / TPM / RPD 数字。

Client 只负责：

- 识别 quota / rate-limit 类错误；
- 给出可理解提示；
- 不做激进自动重试，避免加剧限流。

定价和 Free Tier 只属于文档与链接，不进入核心识别逻辑。

## 27. Settings 集成

`ASRSettingsCard.currentASRGuideLinks` 增加 `.gemini`：

- Live Transcription Docs；
- Get API Key；
- Pricing / Rate Limits。

Provider note 建议：

中文：

`实时流式识别。Smart 模式会自动清理口语停顿、重复和自我纠正；如需逐字记录可切换为 Verbatim。`

英文：

`Real-time streaming transcription. Smart mode cleans up disfluencies, repetitions, and self-corrections; switch to Verbatim for literal transcripts.`

不修改：

```swift
private static let recommendedProviders: [ASRProvider] = [.volcano, .soniox]
```

首版 Gemini 自动进入 Others。

## 28. Keychain 与持久化

`apiKey`：secure → Keychain。

`mode`、`languageCode`：non-secure → credentials.json。

不增加新的 UserDefaults key。

Persisted provider ID 为：

```text
gemini
```

与 LLM 层可能存在的 Gemini provider 名称互不冲突，因为枚举类型不同。

## 29. Unit Tests

### 29.1 GeminiASRConfigTests

覆盖：

- missing apiKey → nil；
- whitespace apiKey → nil；
- default mode SMART；
- VERBATIM round trip；
- invalid mode fallback SMART；
- default language auto；
- custom BCP-47 round trip；
- secure/non-secure field metadata。

### 29.2 GeminiTranscribeProtocolTests

覆盖：

- WebSocket endpoint；
- API Key query 正确 percent-encode；
- 日志 redaction helper 不暴露 key；
- setup model；
- responseModalities TEXT；
- automaticActivityDetection.disabled == true；
- auto language → []；
- explicit language → [code]；
- Smart / Verbatim mapping；
- customVocabulary trim / de-dup / max 1000；
- activityStart message；
- activityEnd message；
- audio message MIME；
- Base64 可还原原 PCM；
- setupComplete parse；
- interim parse；
- final parse；
- malformed response；
- error response。

### 29.3 Rechunk Tests

覆盖：

- 6400 bytes → 3200 + 3200；
- 3200 bytes → one payload；
- 1000 + 2200 → one payload；
- residual 在 endAudio flush；
- 空 audio 不发 activityStart；
- **整段录音（batch fallback 规模，例如 1.92 MB）→ 600 个 payload 且顺序、内容无损**（对应 §16.3）；
- 从未发送音频时 `endAudio()` 不抛错（对应 §16.1）；
- 未 connect 时 `sendAudio()` / `disconnect()` 均不抛错、可重复调用。

这几条 client 级行为由 `GeminiASRClientTests` 覆盖，无需网络。

### 29.3.1 Close Handling Tests（对应 §24.1）

- `unexpectedClose` 忽略 `normalClosure` / `goingAway` / `noStatusReceived`；
- 其余 close code 映射为 `.closed(code:reason:)`；
- reason 命中 session 时长关键字时映射为 `.sessionLimitReached`，普通 `internal error` 不得误判；
- `GeminiCloseTracker` 只记录首个异常终止、`consumeCloseError()` 取走后清空；
- 传输层失败经 `recordFailure` 记录，且不被后续 `normalClosure` 覆盖。

### 29.4 Registry Tests

覆盖 `.gemini`：

- available；
- streaming；
- realtime recognition；
- pcmData；
- createClient non-nil；
- Direct mode supported。

### 29.5 本地化测试

按 AGENTS.md 的强制本地化要求，新增设置字段属于语言敏感 UI，必须覆盖：

- `tf_language` 为中文时，模型、转写模式与语言提示字段的 label / option 文案为中文；
- 切换为英文后，同一字段渲染为英文，且无需重启；
- Provider 显示名 `Gemini` 在两种语言下一致，不被翻译；模型 id（如 `gemini-3.5-transcribe-live`）同样不翻译；
- §14 错误表中的用户可见文案中英文均存在且非空；
- 用户已选中的 `model` / `mode` / `languageCode` **值**在语言切换后不变（持久化的是语义值，不是 UI 字符串）。

## 30. Client Test Strategy

如果现有 `URLProtocol` 无法直接 stub WebSocket，则将 protocol parsing、message creation、rechunk 和 connection gate 做成纯单元可测部分。

至少补充可注入 transport 或最小 WebSocket test seam，覆盖：

1. open 后 setup；
2. setupComplete 后 ready；
3. 第一段 audio 前只发一次 activityStart；
4. 200ms audio 拆成两个 payload；
5. interim → partial；
6. endAudio → activityEnd；
7. endAudio 后 final → isFinal true；
8. invalid setup → error；
9. abnormal close → error；
10. disconnect cleanup。

## 31. 手工集成测试

需要真实 Gemini API Key。

### 中文 Smart

- Auto；
- 10 秒中文；
- 包含“嗯”“那个”和一次口头纠正；
- 验证 interim 延迟与 Smart final。

### 中文 Verbatim

同一段内容切换 Verbatim，确认口语内容保留程度明显不同。

### 中英混输

例如：

`帮我把 Type4Me 的 Gemini WebSocket provider 改成 Swift actor。`

检查 code-switching 和术语。

### Hotwords

加入：

- Type4Me；
- SwiftUI；
- WebSocket；
- Antigravity。

比较开启前后。

### 网络与凭证

- invalid API Key；
- 无网络；
- proxy bypass on/off；
- quota / 429（若测试项目可触发）；
- WebSocket 中断。

### 延迟实测（必须记录数据）

- `connect()` → `setupComplete`；
- 第一段音频 → 第一个 interim；
- **`activityEnd` → final transcript 的 P50 / P95**，对照 §16.2 的 2s / 1s 阈值；
- 超标时记录是否退化到全量 drain。

### batch fallback

- 人为制造流式失败（如录音中断网后恢复），确认 fallback 路径可用；
- 确认整段音频灌入未触发限流；
- 记录 fallback 结果缺少热词偏置带来的差异（§16.3 第 2 点）。

### 长录音

- 连续录音超过 9 分 30 秒，确认 Type4Me 在 570 秒主动收尾并显示「已达最大时长」，文本完整无截断；
- 超过 10 分钟被服务端关闭时，确认不会把 partial 当作完整 final 注入。

### UI

- 普通浮动栏实时文字；
- compact live transcript；
- 松手后 final 不重复；
- Direct / LLM 两类 mode。

## 32. Build 与 Regression

实现后至少：

```bash
swift test
swift build
```

重点回归：

- Deepgram streaming；
- Soniox streaming；
- Grok streaming；
- MiMo batch；
- ASR Settings Picker；
- Keychain save/load；
- HotwordStorage；
- RecognitionSession streaming teardown；
- **batch fallback（`attemptBatchFallback`）路径**；
- **中英语言切换后的 ASR 设置页**；
- compact live transcript；
- Direct 与 LLM ProcessingMode。

## 33. 实现顺序

1. 增加 `.gemini`；
2. 增加 `GeminiASRConfig` + tests；
3. **核实 §4.1 的全部字段命名并回写文档**（已完成：对照官方 SDK `googleapis/python-genai` 的 `_live_converters.py` / `types.py`，全部确认）；
4. 增加 `GeminiTranscribeProtocol` + message/parser tests（字段名以第 3 步结论为准）；
5. 增加 100ms rechunk helper + tests；
6. 增加 connection gate；
7. 实现 `GeminiASRClient.connect()` + setupComplete；
8. 实现 Manual VAD + audio streaming（含 §16.3 的发送节流）；
9. 实现 interim/final transcript mapping；
10. Registry 注册为 `.streaming()`；
11. `RecognitionSession.currentASREndpoint()` 补 `.gemini` warm-up 域名；
12. Settings links / provider note；
13. Registry / client / 本地化 tests；
14. 真实 API 集成测试（含 §16.2 的 final 延迟实测）；
15. README / AGENTS provider 清单；
16. `swift test` + `swift build`；
17. ASR Evaluation 对比。

第 3 步是硬性前置：在字段名未确认前不要写 §29.2 的断言，否则测试会把错误的协议假设固化下来。该步骤已于 2026-08-27 完成，结论见 §4.1。

## 34. 风险与缓解

### 风险 1：API Key 出现在 WebSocket URL

官方 WebSocket 示例使用 `?key=`。

缓解：禁止完整 URL 日志、禁止 URLRequest dump、错误文本 redaction。后续若官方确认 header auth，优先迁移。

### 风险 2：setup ready 与 socket open 混淆

缓解：只有 `setupComplete` 后才 emit ready。

### 风险 3：200ms chunk 增加识别延迟

缓解：Client 内拆成约 100ms payload，不改全局 capture cadence。

### 风险 4：Manual VAD 在用户开口前提前开始 turn

`connect()` 早于第一段真实音频，若在 connect 时就声明 activity 开始，会浪费 session 时长并可能产生空 turn。（注意：Type4Me 的 warm-up 只是 HTTP HEAD 预热，并不预建 WebSocket，见 §13。）

缓解：activityStart 延迟到第一段真实 `sendAudio()`。

### 风险 5：Gemini 提前发送 finalized sub-segment

缓解：只有 `didEndAudio == true` 时才把 authoritative transcript 标记为 Type4Me `isFinal = true`。

### 风险 6：Smart 过度改写

缓解：默认 Smart 但提供 Verbatim；Evaluation 单独记录 over-edit 情况。

### 风险 7：10 分钟连接上限

缓解：首版明确不做会议级长录音；session 计时从 `connect()` 起算，早于 Type4Me 自身 600s 上限，故对 Gemini 把录音上限收紧到 570 秒并主动收尾（§25.1）；服务端仍抢先关闭时由 close tracker 映射为 `.sessionLimitReached`，不静默成功（§24.1）；后续独立 rollover 设计。

### 风险 8：Rate limit 经常变化

缓解：不硬编码 Free Tier 数字；只映射错误并链接官方额度页面。

### 风险 9：Live API schema 扩张

缓解：Protocol 只解析 setup / transcript / error 最小子集，不引入完整 Gemini Agent schema。

### 风险 10：setup / 消息字段命名与实际 API 不符

公开资料对转写配置对象、responseModalities 层级和实时音频负载的命名存在分歧（§4.1）。

缓解：字段名集中在 `GeminiTranscribeProtocol` 单文件；实现顺序第 3 步已完成核实（对照官方 SDK）并回写文档，测试断言据此锁定。

### 风险 11：batch fallback 整段音频灌入触发限流

缓解：`sendAudio()` 内做轻量节流（§16.3）；若实测仍稳定触发限流，则第一版让 Gemini 退出通用 batch fallback，而不是重试放大限流。

### 风险 12：final transcript 超出 teardown 预算

`activityEnd → final` 必须稳定在 2s 内（phase-2 路径 1s），否则每次录音都退化到 5s 全量 drain 并可能误触发 fallback。

缓解：§16.2 定为硬性验收阈值，集成测试实测 P50 / P95；超标时先排查 Manual VAD 用法，不放宽 Type4Me 超时。

## 35. 第一版最终技术决策

| 项目 | 决策 |
|---|---|
| ASR Provider ID | `.gemini` |
| 与 `.google` 关系 | 独立，不复用 |
| Capability | `.streaming()` |
| Model | `gemini-3.5-transcribe-live` |
| Transport | URLSession WebSocket |
| Endpoint | Gemini `v1beta` BidiGenerateContent |
| Authentication | 官方 WebSocket `?key=`，日志严格 redaction |
| Audio | 16 kHz / Int16 / mono PCM |
| Capture chunk | 现有 200ms 不改 |
| Gemini payload | Client 内拆为约 100ms |
| VAD | Manual PTT |
| activityStart | 第一段真实 audio 前 |
| activityEnd | `endAudio()` |
| Interim | `partialText` |
| Final | confirmed + endAudio 后 `isFinal` |
| Mode | SMART 默认 / VERBATIM 可选 |
| Language | Auto + 单个 BCP-47 hint |
| Hotwords | `customVocabulary`，最多 1000 |
| Punctuation flag | 不直接映射 |
| Credential test | 通用 connect/disconnect 即可真实验证 |
| Session rollover | 首版不做 |
| Session 上限处理 | Gemini 专属 570 秒录音上限，主动收尾复用「已达最大时长」提示（§25.1） |
| endAudio 空音频 | 静默返回，不抛错（§16.1） |
| final 延迟预算 | `activityEnd → final` ≤ 2s（phase-2 路径 ≤ 1s） |
| batch fallback | 沿用通用路径，`sendAudio` 内节流；限流则退出该路径 |
| warm-up | `currentASREndpoint()` 增加 Gemini 域名，仅 HEAD 预热 |
| cloudProxyURL | 忽略，不支持自定义 Base URL |
| 协议字段名 | 已对照官方 SDK `googleapis/python-genai` 核实并锁定（§4.1） |
| SDK dependency | 不引入 Google Gen AI SDK |
