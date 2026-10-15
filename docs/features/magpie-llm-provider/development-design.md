# Type4Me Magpie LLM Provider 开发设计

> 分支：`feat/magpie-llm-provider`
> 文档类型：开发设计
> 文档状态：当前有效（设计完成，待评审）
> 设计日期：2026-10-15
> 最后校验：2026-10-15
> 设计基线：`4325d461`
> 对应产品设计：`docs/features/magpie-llm-provider/product-design.md`
> 外部依赖：Magpie 0.1.1246（本机验证）

## 1. 设计摘要

新增 `LLMProvider.magpie`，走现有 OpenAI 兼容客户端 `DoubaoChatClient` 访问 Magpie 本机网关的 `/v1/chat/completions`。凭据不再由用户填写，而是由新的 `MagpieConnectionResolver` 在每次读取时合成：

- **托管模式**：读取 Magpie Agent 插件写入的 `~/Library/Application Support/Type4Me/magpie-agent.json`；Type4Me 可以修改其中的模型：保存时同步改写 `model` 一项，再在后台调用 `magpie type4me magpie/<model>` 让 Magpie 记录一致（见 §6.4）；
- **直连模式**：网关地址从 Magpie 的 `~/.config/magpie/settings.json` 发现，key 为固定标识 `magpie-type4me`，模型取自 `credentials.json` 的 `tf_llm_magpie.model`。

所有读取 LLM 配置的位置（`LLMRuntime.resolve`、`ASRVariantGenerator`、`ModelSettingsHelpers.hasConfiguredCredentials`、设置页）都经过 `KeychainService.loadLLMCredentials(for:)`，因此只在这一处做分支，其余调用方无需感知 Magpie。`LLMRuntime.resolve` 每次会话都会重新读取配置，Magpie 改写接入文件后下一次调用自然生效，运行时不需要文件监听。

Magpie Agent 插件不放在本仓库，单独维护在独立仓库 [`kchen0x/magpie-agent-type4me`](https://github.com/kchen0x/magpie-agent-type4me)（本机路径 `~/Projects/magpie-agent-type4me`），发布时向 `magpie-community/plugins` 提交。

## 2. 外部事实与验证

### 2.1 已在本机验证（Magpie 0.1.1246）

| 事实 | 验证方式 |
|---|---|
| 网关监听 `127.0.0.1:3425` | `curl http://127.0.0.1:3425/api/hello` 返回 `{"name":"magpie","version":"0.1.1246"}` |
| `/v1/models` 无需 key 可读，返回 `id`、`magpie_label`、`reasoning`、`supported_reasoning_levels` | `curl /v1/models`，本机 69 个条目 |
| 路由组 id 以 `group/` 开头 | 同上，例如 `group/auto-gemini-3-8-flash` |
| 推理档位因模型而异，多数没有 `none` | 本机分布：`low/high/max`×14、`low/medium/high/xhigh/max`×12、`low/medium/high`×9、无×9、`minimal/low/medium/high`×7 |
| Magpie 设置文件位于 `~/.config/magpie/settings.json`，默认无 `port` 键 | 本机读取 |
| App bundle id `com.yetone.magpie`，URL scheme `magpie://`（仅用于导入） | `Info.plist` |
| CLI 位于 `~/.local/bin/magpie`，支持 `magpie <agent> <model>`、`magpie panel` | `magpie --help` |
| 插件 Agent 的命令行：`magpie <id> magpie/<model>` 设置模型、`magpie <id> default` 恢复、`magpie models <id>` 列出该 Agent 可选模型；设置一次约 1.6 s | 临时插件 `type4me-probe` 实测 |

### 2.1.1 已从 Magpie 源码确认（`yetone/magpie@b1d02fa`，2026-10-15）

| 事实 | 源码位置 |
|---|---|
| Magpie 只在用户切换模型、模型目录变化（`Sync`）、恢复默认（`Unwire`）时写入插件文件 | `internal/agent/plugged.go` |
| 写入方式：读出全文 → 修改指定键 → 临时文件 + fsync + rename 整体替换，保留原文件权限；对插件文件不加跨进程锁 | `internal/edit/file.go` `WriteAtomic`、`internal/edit/json.go` `SetJSON` |
| 读取带缓存，但按文件修改时间与大小失效，外部改动会被读到 | `internal/filememo` |
| “是否仍由 Magpie 接入”只看 key 那一项是否仍是 Magpie 写入的值（`onMagpie`） | `plugged.go` |
| 只有 key、网关地址等 `connect` 写入的字符串被改时才提示“被改动”；模型与 Magpie 记录不一致时不提示，按 Agent 自带设置显示 | `plugged.go` `Check`、`internal/agent/applied.go` `wiringOff` |
| 恢复默认把每个写过的键恢复为首次接入前的原值（原本不存在则删除），与之后谁改过模型无关 | `plugged.go` `restore` |
| `Sync` 只在文件中的模型仍等于 Magpie 记录时才重写 | `plugged.go` `Sync` |
| 通过 `Set` 传入非 `magpie/` 前缀或不在目录中的值，会先执行恢复默认再写原样值 | `plugged.go` `Fields[0].Set` |
| `config` 与 `dir` 都按 shell 规则展开 `~` 和 `$VAR` | `plugged.go` `pluggedPath` |
| 原值备份保存在 `~/.config/magpie/stash.json`，键为 `plugin:<id>:<文件路径>` | `internal/agent/stash.go` |

### 2.2 来自官方文档，未在本机验证

| 事实 | 来源 | 实现时验证 |
|---|---|---|
| 本机请求接受任意 key，`magpie-<应用id>` 会被记为该应用 | 接入应用文档 | Gate A |
| 无 key 时取 User-Agent 首词作为应用名 | 接入应用文档 | 仅作兜底，不依赖 |
| `reasoning_effort` 按所用 API 的字段透传 | 接入应用文档 | Gate A |
| Agent 插件字段：`id`、`name`、`config`、`format`、`model`、`prefix`、`bin`、`dir`、`ua`、`icon`、`notice`、`library`，以及 `connect({ gateway, model, models, agent })` | 插件文档 | Gate B |
| Magpie 原地修改配置文件，首次写入前备份原值；恢复时删除原本不存在的键 | 插件文档 | 已由源码与实测确认，见 §2.1.1 |
| `config`、`dir` 支持 `~` 与 `$VAR` 展开，不存在则新建 | 插件文档 | 已由源码确认 |

## 3. 当前架构适配

| 位置 | 现状 | 本设计的改动 |
|---|---|---|
| `LLMProvider` | 15 个 case，`isOpenAICompatible` 默认 true | 新增 `.magpie` |
| `LLMProviderRegistry.all` | provider → config 类型 | 注册 `MagpieLLMConfig` |
| `LLMClientFactory.make` | 非 Claude/Codex 都用 `DoubaoChatClient` | 不改，`.magpie` 走默认分支 |
| `KeychainService.loadLLMCredentials(for:)` | 合并 `credentials.json` 明文与钥匙串 | `.magpie` 改由 `MagpieConnectionResolver` 合成 |
| `KeychainService.saveLLMCredentials(for:values:)` | 按字段拆分明文/密文 | `.magpie` 只保存 `model`，其余丢弃 |
| `LLMRuntime.resolve` | 每次会话读取所选 Provider 配置 | 不改 |
| `LLMClientCacheKey` | provider + apiKey + model + baseURL | 不改；Magpie 换模型或端口时缓存自然失效 |
| `DoubaoChatClient` | `reasoning_effort` 固定发送 `"none"` | 新增“最低推理档位”分支和 Magpie 错误映射 |
| `ModelSettingsHelpers` | `localLLMProviders = [.codexCLI, .ollama]` | 追加 `.magpie`，`hasConfiguredCredentials` 增加分支 |
| `LLMProviderDetailView` | 通用字段渲染，Codex/Ollama 有特例 | `.magpie` 渲染独立的 `MagpieProviderSection` |
| `BrandIconView` / `ModelSettingsHelpers.icon` | 穷举 switch | 增加 `.magpie` |
| `migrateSecureCredentialGroups` | 迁移 `isSecure` 字段到钥匙串 | `MagpieLLMConfig` 没有 secure 字段，不受影响；接入文件不在 `credentials.json` 中 |

## 4. 文件规划

```text
Type4Me/LLM/LLMProvider.swift                       # .magpie case 与各属性
Type4Me/LLM/LLMProviderRegistry.swift               # 注册
Type4Me/LLM/Providers/MagpieLLMConfig.swift         # 新增：LLMProviderConfig
Type4Me/LLM/Magpie/MagpieAgentFile.swift            # 新增：插件接入文件模型与解析
Type4Me/LLM/Magpie/MagpieGateway.swift              # 新增：端口发现、回环校验、hello/models 探测
Type4Me/LLM/Magpie/MagpieConnectionResolver.swift   # 新增：模式判定与凭据合成
Type4Me/LLM/Magpie/MagpieModelCatalog.swift         # 新增：/v1/models 缓存与最低推理档位
Type4Me/LLM/Magpie/MagpieInstallation.swift         # 新增：安装检测、打开 App
Type4Me/LLM/Magpie/MagpieAgentModelWriter.swift     # 新增：托管模式写入模型（同步写文件 + 后台通知 Magpie）、写锁与 MagpieReconciler
Type4Me/LLM/DoubaoChatClient.swift                  # 推理档位、User-Agent、错误映射
Type4Me/Services/KeychainService.swift              # load/save 分支
Type4Me/UI/Settings/MagpieProviderSection.swift     # 新增：详情页状态驱动内容
Type4Me/UI/Settings/MagpieProviderStatusModel.swift # 新增：@MainActor 状态模型与轮询
Type4Me/UI/Settings/LLMProviderDetailView.swift     # 接入 MagpieProviderSection
Type4Me/UI/Settings/ModelSettingsState.swift        # 分组、配置判定、图标
Type4Me/UI/Settings/BrandIconView.swift             # 图标
Type4Me/Resources/Icons/magpie.png                  # Magpie 品牌图标（见 §13）
Type4MeTests/Magpie*Tests.swift                     # 新增测试，见 §15
CLAUDE.md、docs/README.md                           # 政策、Key Files、索引
```

## 5. Provider 定义

```swift
case magpie   // 追加在 .ollama 之后、.custom 之前
```

| 属性 | 值 |
|---|---|
| `displayName` | `L("Magpie（本机模型网关）", "Magpie (Local Gateway)")` |
| `defaultBaseURL` | `"http://127.0.0.1:3425/v1"`（仅作展示兜底，实际由 Resolver 决定） |
| `modelOptions` | `[]`（模型来自 `/v1/models`） |
| `isOpenAICompatible` | `true` |
| `isLocal` | `false`，详情页标签单独处理为“本机网关 / Local Gateway”，避免与 Ollama 的“本地”混淆 |
| `requiresAPIKey` | `false` |
| `thinkingDisableField(for:)` | `.lowestReasoningEffort`（新增，见 §9） |
| `needsReasoningSplit` | `false` |

`LLMThinkingPreference` 不改：Magpie 与其他直连 Provider 共用 `tf_disableThinking`，默认关闭思考。

## 6. 插件接入文件

### 6.1 位置与格式

```text
~/Library/Application Support/Type4Me/magpie-agent.json
```

位于 Prod 与 Dev 共享的 Profile 目录（`AppDataLocation.profileDirectory`）。测试运行时自动落到 `Type4MeTests` 目录，不触碰真实文件。

```json
{
  "model": "deepseek/deepseek-chat",
  "baseURL": "http://127.0.0.1:3425/v1",
  "apiKey": "<Magpie 为 Type4Me 生成的 Agent key>"
}
```

- 文件由 Magpie 创建；网关地址与 key 只由 Magpie 写入，Type4Me 只会修改 `model`（§6.4）；
- Magpie 恢复默认后三个键被删除，文件可能变为 `{}`；
- 文件中出现其他键（将来 Magpie 或插件新增）时忽略。

### 6.2 `MagpieAgentFile`

```swift
struct MagpieAgentFile: Equatable, Sendable {
    let model: String
    let baseURL: URL
    let apiKey: String

    enum LoadResult: Equatable, Sendable {
        case absent                 // 文件不存在，或三个键都缺失
        case incomplete             // 有部分键（Magpie 写入中途或被手动修改）
        case managed(MagpieAgentFile)
        case unreadable             // 存在但不是 JSON 对象
        case nonLoopback(String)    // baseURL 不是回环地址
    }

    static var defaultURL: URL { AppDataLocation.profileDirectory.appendingPathComponent("magpie-agent.json") }
    static func load(from url: URL = defaultURL) -> LoadResult
    static func parse(_ data: Data) -> LoadResult   // 纯函数，便于测试
}
```

解析规则：

- 字符串字段先 trim；空字符串视为缺失；
- `baseURL` 去掉末尾 `/`，必须是 `http` 且 host 为 `127.0.0.1`、`localhost` 或 `::1`，否则 `.nonLoopback`；
- 只有 `.managed` 会被 Resolver 采用，其余都按直连模式处理，并把原因交给 UI 显示提示。

### 6.3 读取开销

`loadLLMCredentials` 会被设置列表、菜单栏、会话启动频繁调用。`MagpieAgentFile.load` 用 `(mtime, size)` 做进程内缓存，未变化时不重新读文件。缓存用 `OSAllocatedUnfairLock` 保护。

因为 Magpie 用临时文件 + rename 整体替换（§2.1.1），替换后 inode 与 mtime 都会变化，`(mtime, size)` 缓存可靠；同一时钟刻度内写入同样长度的极端情况，额外比较 inode 号兜底。

### 6.4 托管模式下写入模型：`MagpieAgentModelWriter`

两边同时读写的可行性已由源码和实测确认（产品设计 §5.3.1）。保存拆成两步：**先同步写文件保证已保存，再在后台通知 Magpie 让显示一致**。

```swift
enum MagpieAgentModelWriter {
    enum Failure: Error, Equatable { case notManaged, notInCatalog, busy, verifyFailed, io(String) }

    /// 第 1 步：持有写锁同步写入并复读校验。托管模式下 `saveCredentials()` 直接调用，
    /// 返回即代表文件中已是新模型。通常毫秒级；后台命令正在运行时最多等待 6 s。
    static func writeModel(_ model: String, to url: URL = MagpieAgentFile.defaultURL) throws

    /// 第 2 步：后台让 Magpie 把这次修改记为它自己的选择。不抛错，失败只记日志。
    static func reconcileWithMagpie(model: String)
}

/// Type4Me 对接入文件的写锁：flock(LOCK_EX) 于 `magpie-agent.json.lock`（与接入文件同目录）。
/// 跨进程生效，Prod 与 Dev 同时运行时也互斥。Magpie 自身不使用这把锁。
struct MagpieAgentWriteLock { static func acquire(timeout: Duration) throws -> Held }

/// 第 2 步的执行者：单例，串行，只保留最新一次。命令执行器可注入，便于控制时序的测试。
actor MagpieReconciler { init(runner: MagpieCommandRunner, lock: MagpieAgentWriteLockProviding) }
```

#### 为什么需要并发协议

Magpie 命令行 `magpie type4me magpie/<model>` 内部调用 `wire(model)`，**无条件**写入目标模型，不检查文件当前内容（`internal/agent/plugged.go`）；进程约 1.6 s，写入发生在后段。若不加约束会出现：

1. 保存 A，后台命令 A 开始执行；
2. 命令 A 写文件前，用户保存 B，第 1 步同步写入 B 成功；
3. 命令 A 把文件写回 A；
4. B 的后台任务复读发现文件是 A，按“外部已修改”跳过。最终生效的是 A，已保存成功的 B 被静默丢弃。

Magpie 没有条件写入接口，无法在 Magpie 一侧防止第 3 步，因此必须在 Type4Me 一侧保证：**后台命令运行期间，Type4Me 不会有新的保存写入文件**。

#### 不取消后台命令的原因

只做第 1 步时，Magpie 把该模型当作“Agent 自带的设置”。Magpie 的 Profile（`magpie save` / `magpie use`，`internal/profile/profile.go`）记录的是字段显示值；应用一个记有不带 `magpie/` 前缀模型的 Profile 时，Magpie 会先恢复默认（删除网关地址与 key）再写入原样模型，Type4Me 会悄悄掉回直连模式。为了让 Profile 正常工作，保留第 2 步。

#### 并发协议

不变式：**Type4Me 对接入文件的所有写入（第 1 步写文件、第 2 步运行命令行）都持有同一把写锁；后台命令只在“文件当前模型等于它的目标值”时启动，并在命令结束前一直持锁。** 因此任何 Type4Me 保存都不可能夹在一次后台命令的“启动”与“写入”之间，后台命令写入的永远是 Type4Me 最近一次成功保存的值。

#### 第 1 步：同步写文件（决定保存成败）

1. **前置校验**：`model` 必须在当前 `MagpieModelCatalog` 中，否则抛 `.notInCatalog`（命令行只接受目录内模型，传入目录外的值会让 Magpie 先“恢复默认”，等于把 Type4Me 移出 Magpie）。
2. **取锁**：`MagpieAgentWriteLock.acquire(timeout: 6 s)`，以 `LOCK_NB` 每 20 ms 重试。只有后台命令正在运行时才需要等待，最长等待为命令超时 5 s 加余量；超时抛 `.busy`。
3. 持锁期间：重新解析接入文件，必须仍是 `.managed`，否则抛 `.notManaged`。
4. **写入**：读原始字节，用 `JSONSerialization` 解析为字典，只改 `model` 的值，其他键与未知键全部保留，再以 `.prettyPrinted` + `.withoutEscapingSlashes` 序列化。键顺序可能变化，这不影响 Magpie：它按键路径读写（gjson / `SetJSON`），而且这个文件只由程序写入，没有用户注释需要保留。写入临时文件后 `rename` 覆盖，保留原文件权限。
5. **复读校验**：仍是 `.managed` 且 `model` 等于目标值，否则抛 `.verifyFailed`。
6. 释放锁，调用 `reconcileWithMagpie(model:)`。
7. **不写** `baseURL`、`apiKey`，也不触碰 Magpie 的 `stash.json`；**不经过** `KeychainService` 与 `credentials.json`：托管模式下模型的唯一来源是接入文件。

任何失败都让 `save()` 返回 `false`，草稿保留（§11.4）。`.busy` 的提示为“Magpie 正在同步上一次修改，请稍后再保存”。第 1 步完成后，请求已经会使用新模型：Magpie 只用 key 判断接入状态，不会报警告，恢复默认仍正确（§2.1.1）。

#### 第 2 步：后台通知 Magpie（只影响 Magpie 的显示与 Profile）

1. `MagpieReconciler` 是单例 actor，与设置页生命周期无关，窗口关闭后仍会执行完；
2. 新请求到达时替换尚未开始的旧请求，只保留最新一次；
3. 执行一次请求：
   1. 若 `MagpieInstallation.cliURL()` 不存在，结束；
   2. 在后台线程取写锁（阻塞等待）；
   3. 持锁复读接入文件：仍是 `.managed` 且 `model` 等于本次目标值才继续；否则说明之后有更新的保存或用户在 Magpie 做了选择，释放锁并结束；
   4. 持锁运行 `magpie type4me magpie/<model>`：参数用数组传递，不经过 shell；超时 5 s（实测约 1.6 s）；只看退出码，不解析输出；
   5. 超时：先 `terminate()`，再等待进程真正退出，之后才进入下一步，保证锁释放后不存在仍在运行的命令；
   6. 持锁复读，只用于日志：持锁期间 Type4Me 不会写入，命令也只会写入本次目标值，所以复读到其他值只可能来自 Magpie 一侧的外部选择，**不写回**；
   7. 释放锁；
4. 任何失败（无命令行、退出码非 0、超时）只写 debug 日志，不提示用户：文件已是最近一次保存的模型，功能不受影响。

命令行重写的值与第 1 步相同（模型、网关地址、key 都不变），`MagpieProviderStatusModel` 复读时模型没有变化，不会触发“Magpie 中的模型已变为 %@”提示。

#### 残余边界

- **Magpie 一侧的写入不受这把锁约束。** 用户在 Type4Me 保存后约 1.6 s 内，又在 Magpie 菜单栏选了另一个模型 C，且 C 恰好在后台命令写入之前落盘时，后台命令会把 C 覆盖为 Type4Me 刚保存的值。这需要两边的用户操作在 1.6 s 内交错，且结果是“Type4Me 最近一次保存生效”而不是丢失保存；在 Magpie 不提供条件写入的前提下接受。反过来，若 C 在后台命令写入之后才落盘，C 生效，第 3.6 步不会把它改回。
- **超时被终止的命令**：Magpie 先原子替换文件、再写 `stash.json`。若恰好在两者之间被终止，文件是新值而 Magpie 记录的仍是旧值，Magpie 会把模型显示为“Agent 自带的设置”，功能不受影响；下一次保存会再次运行命令修正。

日志只记录步骤、目标模型、等待锁的时长与结果，不记录 key。

## 7. 网关发现

### 7.1 `MagpieGateway`

```swift
enum MagpieGateway {
    static let defaultPort = 3425
    static let settingsURL = home/.config/magpie/settings.json

    /// 直连模式的 base URL：读取 settings.json 的整数 `port`，缺省 3425。
    static func directBaseURL(settingsData: Data?) -> URL   // 纯函数
    static func directBaseURL() -> URL                      // 读取真实文件，带 mtime 缓存

    static func isLoopback(_ url: URL) -> Bool

    /// UI 探测用，超时 1.5 s。
    static func hello(baseURL: URL) async -> HelloResult    // .magpie(version) / .notMagpie / .unreachable
}
```

- Magpie 网关 base URL 形如 `http://127.0.0.1:<port>`，OpenAI 客户端用 `<base>/v1`，`hello` 用 `<base>/api/hello`；
- 运行时（`LLMRuntime.resolve`）**不调用** `hello`，避免给每次语音输入增加网络往返；网关离线由真实请求失败暴露；
- `settings.json` 只读，不写入（官方文档要求）。

### 7.2 直连模式的身份

```swift
static func directIdentity(bundleID: String? = Bundle.main.bundleIdentifier) -> String {
    bundleID == AppDataLocation.devBundleID ? "magpie-type4me-dev" : "magpie-type4me"
}
```

对应产品决策 Q4。若评审决定不区分，固定返回 `magpie-type4me`。

## 8. 模式判定与凭据合成

### 8.1 `MagpieConnectionResolver`

```swift
enum MagpieConnectionMode: String, Sendable { case managed, direct }

struct MagpieResolvedConnection: Equatable, Sendable {
    let mode: MagpieConnectionMode
    let model: String          // 直连模式未选模型时为空
    let baseURL: URL           // 以 /v1 结尾
    let apiKey: String
    let agentFileIssue: MagpieAgentFile.LoadResult?   // .unreadable / .nonLoopback / .incomplete 时供 UI 提示
}

enum MagpieConnectionResolver {
    static func resolve(
        agentFile: MagpieAgentFile.LoadResult,
        storedDirectModel: String?,
        directBaseURL: URL,
        directIdentity: String
    ) -> MagpieResolvedConnection   // 纯函数

    static func credentials(storedPlaintext: [String: String]) -> [String: String]
}
```

判定：

1. `agentFile == .managed(f)` → `mode = .managed`，`model/baseURL/apiKey` 取自 `f`；
2. 否则 → `mode = .direct`，`model = storedDirectModel ?? ""`，`baseURL = directBaseURL + /v1`，`apiKey = directIdentity`。

### 8.2 `KeychainService` 分支

```swift
static func loadLLMCredentials(for provider: LLMProvider) -> [String: String]? {
    if provider == .magpie {
        let stored = stringDictionary(loadAll()[llmStorageKey(for: .magpie)])
        return MagpieConnectionResolver.credentials(storedPlaintext: stored)
    }
    ...
}
```

返回字典：

| 键 | 含义 |
|---|---|
| `model` | 生效模型，可能为空 |
| `baseURL` | 生效地址 |
| `apiKey` | 生效 key |
| `source` | `managed` / `direct` |
| `directModel` | 直连模式保存的模型，托管模式下也返回，便于回退后显示 |

`saveLLMCredentials(for: .magpie, values:)` 只把 `values["model"]` 写入 `tf_llm_magpie.model`，忽略其他键，保证托管模式下的地址和 key 不会被复制进 `credentials.json`。这只用于直连模式；托管模式下的保存走 `MagpieAgentModelWriter`（§6.4），不经过 `KeychainService`。

### 8.3 `MagpieLLMConfig`

```swift
struct MagpieLLMConfig: LLMProviderConfig {
    static let provider = LLMProvider.magpie
    static var credentialFields: [CredentialField] {
        [CredentialField(key: "model", label: L("模型", "Model"), placeholder: "",
                         isSecure: false, isOptional: false, defaultValue: "",
                         options: [], allowCustomInput: true)]
    }
    let model: String, baseURL: String, apiKey: String

    init?(credentials: [String: String])   // model 非空且 baseURL 为回环地址才成功
    func toCredentials() -> [String: String]
    func toLLMConfig() -> LLMConfig { LLMConfig(apiKey: apiKey, model: model, baseURL: baseURL) }
}
```

`credentialFields` 只声明 `model`，保证通用的字段迁移、草稿比对逻辑不会处理地址和 key。

### 8.4 配置完整性

`ModelSettingsHelpers.hasConfiguredCredentials(for: .magpie)` = `MagpieLLMConfig(credentials:) != nil`，即“有生效模型且地址合法”。这决定“设为默认”是否可用，以及菜单栏是否把 Magpie 视为已配置。

## 9. 关闭思考：最低推理档位

### 9.1 新的禁用策略

```swift
enum ThinkingDisableField {
    ...
    /// `reasoning_effort: <模型支持的最低档位>` — Magpie
    case lowestReasoningEffort
}
```

档位排序：`none < minimal < low < medium < high < xhigh < max`。取模型 `supported_reasoning_levels` 中排序最低的一档；包含 `none` 时取 `none`；未知档位名排在已知档位之后，不会被选为最低。

### 9.2 `MagpieModelCatalog`

```swift
actor MagpieModelCatalog {
    static let shared = MagpieModelCatalog()

    struct Entry: Sendable { let id: String; let label: String?; let isGroup: Bool; let reasoningLevels: [String] }

    func models(baseURL: URL, forceRefresh: Bool = false) async throws -> [Entry]   // 设置页下拉用，超时 3 s
    func lowestReasoningEffort(model: String, baseURL: URL) async -> String?        // 运行时用，超时 300 ms
}
```

- 按 `baseURL` 缓存 10 分钟；设置页打开时强制刷新；
- 运行时首次调用若缓存未命中，最多等 300 ms 拉取 `/v1/models`（本机回环，通常几毫秒）；超时或失败返回 `nil`，即**不发送** `reasoning_effort`，请求照常进行；
- `isGroup = id.hasPrefix("group/")`。

### 9.3 `DoubaoChatClient` 改动

`process` / `processStreaming` 已是 `async`。构造请求体前：

```swift
var reasoningEffort: String? = disableField == .reasoningEffort ? "none" : nil
if disableField == .lowestReasoningEffort, let base = URL(string: config.baseURL) {
    reasoningEffort = await MagpieModelCatalog.shared.lowestReasoningEffort(model: config.model, baseURL: base)
}
```

两处请求构造（约第 87 行与第 153 行）都改为使用 `reasoningEffort`。注意第 153 行目前用的是不带模型的 `provider.thinkingDisableField`，Magpie 必须走 `thinkingDisableField(for: config.model)`，实现时一并统一。

### 9.4 设置页开关

- 托管模式与直连模式都显示；当前模型在目录中没有推理档位时隐藏；
- 说明文字固定为“使用该模型支持的最低推理档位，降低延迟。”，并在其后显示实际档位，例如“（low）”。

## 10. 请求、User-Agent 与错误

### 10.1 User-Agent

`.magpie` 请求设置 `User-Agent: Type4Me/<CFBundleShortVersionString>`。正常情况下 Magpie 按 key 归属用量，UA 只在 key 缺失时兜底。其他 Provider 不改 UA。

### 10.2 代理

回环地址不应走代理。实现时确认 `ProxyBypassMode` 与系统代理设置下 `127.0.0.1` 请求不被转发（CFNetwork 默认对回环地址直连）；若有例外，`.magpie` 强制 `bypassProxy = true`。

### 10.3 错误映射

在 `LLMError` 新增：

```swift
case magpieUnavailable        // URLError .cannotConnectToHost / .networkConnectionLost / .timedOut（连接阶段）
case magpieRejected(Int)      // 401 / 403
case magpieModelMissing       // 直连模式 model 为空（resolve 阶段）
```

- 仅当 `provider == .magpie` 时映射，其他 Provider 行为不变；
- 其他 HTTP 错误：尝试解析 OpenAI 格式 `{"error":{"message":...}}`，把 Magpie 转述的上游错误原文作为 `requestFailed` 的附加信息展示；
- `magpieModelMissing`：`LLMRuntime.resolve` 在 `MagpieLLMConfig.init` 失败时返回 `nil`，现有调用方已经处理“LLM 未配置”。实现时确认该路径给出的用户提示，必要时为 `.magpie` 替换为“请先在 Type4Me 中为 Magpie 选择模型”。

失败后的会话行为（原文处理、浮条提示、翻译模式失败）完全沿用 `RecognitionSession` 现有 LLM 失败路径，不新增分支。

## 11. 设置页

### 11.1 `MagpieProviderStatusModel`

```swift
@MainActor
final class MagpieProviderStatusModel: ObservableObject {
    enum Gateway: Equatable { case unknown, online(version: String), offline }
    enum Installation: Equatable { case installed, notInstalled }

    @Published private(set) var connection: MagpieResolvedConnection
    @Published private(set) var gateway: Gateway = .unknown
    @Published private(set) var installation: Installation
    @Published private(set) var catalog: [MagpieModelCatalog.Entry] = []

    var state: MagpieProviderState { MagpieProviderState.derive(connection:gateway:installation:) }

    func start()   // onAppear
    func stop()    // onDisappear
}
```

- `start()` 启动两个循环：每 1 s 重新解析接入文件（命中 mtime 缓存时几乎无开销），每 5 s 调用 `hello`；状态变化才发布；
- 选择轮询而不是 `DispatchSource`：接入文件所在的 Profile 目录同时承载 `history.db-wal` 等高频写入，目录监听噪声大；Magpie 写文件的方式（原地写或原子替换）未知，文件级监听需要处理重新挂载。轮询只在详情页可见时运行，成本可忽略；
- 网关从离线变为在线时刷新模型目录。

### 11.2 状态推导

`MagpieProviderState.derive` 为纯函数，对应产品设计 §6.1：

| 输入 | 输出 |
|---|---|
| mode = managed，gateway online | `.managedOnline` |
| mode = managed，gateway offline | `.managedOffline` |
| mode = direct，gateway online | `.directOnline` |
| mode = direct，gateway offline，installed | `.installedNotRunning` |
| 其他 | `.notInstalled` |
| gateway unknown | 按 offline 推导，但不显示离线警告（首次探测前避免闪烁） |

### 11.3 安装检测与打开

```swift
enum MagpieInstallation {
    static let bundleID = "com.yetone.magpie"
    static let cliCandidates = ["~/.local/bin/magpie", "/opt/homebrew/bin/magpie", "/usr/local/bin/magpie"]
    static func isInstalled() -> Bool          // NSWorkspace.urlForApplication(withBundleIdentifier:) 或 CLI 存在
    static func openApp()                      // NSWorkspace.openApplication(at:configuration:)
}
```

`openApp()` 只用于“打开 Magpie”按钮。Magpie 没有公开打开 Agent 页的 deep link；`magpie panel` 可以打开菜单栏面板，但需要执行外部命令，留作后续评估。

`MagpieInstallation.cliURL()` 返回第一个存在且可执行的 `cliCandidates`，供 §6.4 第 2 步使用。

### 11.4 `LLMProviderDetailView` 接入

- `provider == .magpie` 时，`configurationSection` 中的 `dynamicCredentialFields` 替换为 `MagpieProviderSection(model:, draftModel: $llmCredentialValues["model"])`；
- 头部标签增加 `.magpie` 分支：“本机网关 / Local Gateway”；
- 直连模式：模型下拉绑定 `llmCredentialValues["model"]`，沿用现有草稿、保存、还原、`SettingsDraftCoordinator` 流程；
- 托管模式：与直连模式相同，模型下拉绑定 `llmCredentialValues["model"]` 并注册草稿参与者；`saveCredentials()` 对 `.magpie` 托管模式同步调用 `MagpieAgentModelWriter.writeModel`（§6.4 第 1 步），成功后刷新 `savedLLMValues` 并调用 `reconcileWithMagpie`，返回 `true`；失败时返回 `false`，在操作栏提示原因，草稿保持未保存；
- 因为保存是同步完成的，`SettingsDraftCoordinator` 的现有契约不变：`save()` 返回 `true` 时文件里确实已是新模型，切页、切 Provider、关闭窗口、“设为默认”都可以按现有逻辑立即继续；返回 `false` 时 `confirmUnsavedChanges` 回调 `.cancelled`，页面停留、草稿保留，`handleSetAsDefault()` 不会调用 `onSetAsDefault`；
- 托管模式下 Magpie 在外部改了模型：`MagpieProviderStatusModel` 发现文件中的模型变化后，若当前无未保存修改，直接刷新 `llmCredentialValues` 与 `savedLLMValues`；若有未保存修改，只刷新 `savedLLMValues` 并提示“Magpie 中的模型已变为 %@”；
- 托管 · 离线（T2）：下拉禁用，因为模型目录与命令行都需要 Magpie 运行；
- 测试连接：沿用 `testLLMConnection()`。网关地址和 key 取 Resolver 的生效值，模型取下拉当前的草稿值（`effectiveLLMValues["model"]`），这样测试的就是用户正要保存的模型；直连模式首次未保存时也能测试。下拉为空时测试按钮禁用；
- 现有 `fetchModels()` 不用于 Magpie，改由 `MagpieModelCatalog` 提供带分组和标签的列表；
- 模式从直连切到托管时，若直连下拉有未保存修改，丢弃草稿并在操作栏提示“已与 Magpie 同步”，下拉显示 Magpie 写入的模型。

### 11.5 本地化

- 全部文案使用 `L(zh, en)`，在 `body` 内求值，不缓存字符串；`MagpieProviderStatusModel` 只发布语义状态，不发布文案；
- 产品设计 §10 的文案表即实现清单。

## 12. Magpie Agent 插件（独立仓库）

### 12.1 仓库

插件与 Type4Me 主仓库分开维护：

| 项 | 值 |
|---|---|
| 仓库名 | `magpie-agent-type4me` |
| 本机路径 | `~/Projects/magpie-agent-type4me` |
| 远端 | https://github.com/kchen0x/magpie-agent-type4me （公开，`main`；`a4cd0bc` 首个提交，`1f6ab28` 按社区规范调整布局） |
| 社区 PR | https://github.com/magpie-community/plugins/pull/136 （`kchen0x:feat/agent-type4me` → `main`，2026-10-15 提交，待审） |
| npm 包名 | `@magpie-community/agent-type4me` |
| 许可 | MIT，版权方与 Type4Me 一致（Type4Me Contributors） |

分开维护的原因：插件的发布节奏跟随 Magpie 社区仓库与 npm，与 Type4Me 的 App 发布无关；插件用 bun 测试，不进入 Type4Me 的 Swift 构建与打包。

目录与社区仓库 `packages/<name>/` 的规范一致，便于原样复制：

```text
magpie-agent-type4me/
├── package.json            # magpie.agent → ./type4me.agent.js；magpie.icon；repository 指向 packages/type4me
├── type4me.agent.js        # agent 描述与 connect()，单文件、不导入任何模块
├── type4me.test.mjs        # bun test
├── assets/icon.png         # 128×128，从 Type4Me 的 docs/images/type4me_icon.png 导出，供 https 引用
├── README.md               # 同时作为社区包的 README
├── README.zh-CN.md         # 仅独立仓库
└── LICENSE
```

### 12.2 源码要点

```js
// type4me.agent.js（节选）
export const agent = {
  id: "type4me", name: "Type4Me",
  icon: "https://raw.githubusercontent.com/kchen0x/magpie-agent-type4me/main/assets/icon.png",
  config: "~/Library/Application Support/Type4Me/magpie-agent.json", // 与 MagpieAgentFile.defaultURL 一致
  format: "json", model: "model",
  dir: "~/Library/Application Support/Type4Me", ua: ["Type4Me"],
  notice: "Type4Me uses the new model on your next dictation. Type4Me 会在下一次语音输入时使用新模型。",
}

export function connect({ gateway }) {
  return { baseURL: gateway.v1, apiKey: gateway.key }
}
```

说明：

- 社区规范要求 Agent 模块“单文件、不导入任何模块”，所以图标不再内嵌为 `data:` URL 模块，改为 https 地址引用本仓库 `assets/icon.png`（已确认返回 200 image/png），同时写在 `package.json` 的 `magpie.icon`，供 Magpie 插件市场卡片使用；
- `dir` 指向共享 Profile 目录，Prod 或 Dev 任一安装过即判定为已安装（Magpie 按 shell 规则展开 `~`，已由源码确认）；
- 不写 `bin`：Type4Me 没有命令行入口；不写 `prefix`：Type4Me 直接把 Magpie 模型 id 发给网关；不写 `library`：Type4Me 不使用 instructions、MCP 和 skills；
- `connect` 不依赖 Node API、定时器或 `fetch`，符合 moejs 运行环境限制；
- 插件文件路径是 macOS 专用的。Magpie 在 Windows/Linux 上会因 `dir` 不存在把 Type4Me 判定为未安装，这是期望行为；
- `agent.config` 与 Type4Me 的 `MagpieAgentFile.defaultURL` 是跨仓库契约：两边测试各自断言同一个字符串，任何一边修改都必须同步另一边，并同步社区仓库的副本。

### 12.3 验证状态（2026-10-15）

- 独立仓库 `bun test`：4 项通过；社区分支 `bun test packages/type4me` 4 项通过，`bun scripts/check.mjs` 通过；
- 本机 Magpie 0.1.1246：以目录方式安装的插件加载了单文件版本，`magpie type4me` 显示已选模型，接入文件含 `model`、`baseURL`、`apiKey`；
- 写入、请求与恢复默认的契约此前已用临时插件验证（§2.1.1）。

### 12.4 发布

1. ~~在 GitHub 创建远端仓库~~：已于 2026-10-15 创建 `kchen0x/magpie-agent-type4me`（公开）；
2. ~~向 `magpie-community/plugins` 提 PR~~：已提交 #136，新增 `packages/type4me/`，README 的 Agents 表登记一行；
3. 待维护者审阅合并；首个 npm 版本由维护者手动发布（`scripts/publish.sh <otp>`，`publish.yml` 设为 Trusted Publisher），之后再提交 `registry.json` 的 `"kind": "agent"` 条目；
4. 发布前过渡：用户用 `magpie plugin add github:kchen0x/magpie-agent-type4me` 安装。设置页的插件引导由常量 `MagpieInstallation.agentPluginInstallCommand` 控制：当前为该 `github:` 命令，npm 发布后改为 `magpie plugin add @magpie-community/agent-type4me`。托管模式的检测与显示不受该常量影响；
5. 之后修改插件：先在独立仓库提交，再向社区仓库同步提交，版本号同步递增。

## 13. 图标

使用 Magpie 官方品牌图标（授权已由产品负责人确认）：

- 来源：Magpie 仓库 `build/darwin/magpie.icns`（App 图标）；
- 产物：`Type4Me/Resources/Icons/magpie.png`，256×256 PNG，与现有品牌图标规格一致（例如 `ollama.png`）；用 `sips`/`iconutil` 从 icns 导出；
- `BrandIconView.iconName` 增加 `.llm(.magpie)` → `"magpie"`；App 图标自带底色，不加入 `shouldInvertInDarkMode`；
- `ModelSettingsHelpers.icon(for: .magpie)` 的 SF Symbol 仅在图标资源加载失败时作为后备，沿用现有各 Provider 的后备机制；
- 插件 `agent.icon` 使用 Type4Me 自己的 App 图标（https 地址），不是 Magpie 图标。

## 14. 文档与政策更新

- `CLAUDE.md`：
  - “LLM Provider Inclusion Policy”增加例外：本地运行、由用户自持的模型网关（如 Ollama、Magpie）可以作为一等公民；
  - Key Files 表增加 `Type4Me/LLM/Magpie/`；在 Magpie 小节注明插件在独立仓库 `magpie-agent-type4me`，以及 `CONFIG_PATH` 跨仓库契约；
  - `LLMProvider.swift` 描述中的数量从 15 改为 16，并列出 Magpie；
- `docs/README.md`：功能文档表登记本功能两份文档；
- `README.md` / `README.en.md`：LLM Provider 列表加入 Magpie（实现完成后）。

## 15. 测试计划

### 15.1 单元测试（XCTest，`Type4MeTests/`）

| 文件 | 覆盖 |
|---|---|
| `MagpieAgentFileTests` | 完整文件 → managed；`{}` → absent；缺一个键 → incomplete；非 JSON / 数组 → unreadable；`https://example.com/v1` → nonLoopback；`localhost`、`[::1]` 合法；字段 trim 与末尾 `/` 处理；未知键忽略 |
| `MagpieGatewayTests` | `settings.json` 无 port → 3425；`port: 4000` → 4000；port 为字符串或越界 → 3425；文件缺失 → 3425；回环判定 |
| `MagpieConnectionResolverTests` | managed 优先于 direct；direct 使用保存的模型；托管失效后回到 direct 且保留直连模型；Dev bundle id 身份 |
| `MagpieReasoningLevelTests` | `[low, high, max]` → low；`[minimal, low]` → minimal；含 `none` → none；空 → nil；未知档位名不被选为最低 |
| `KeychainServiceTests`（扩充） | `.magpie` 保存只写 `model`；托管模式的 key 不出现在 `credentials.json`；`migrateStoredCredentials` 不改动 `tf_llm_magpie` 与接入文件 |
| `MagpieProviderStateTests` | §11.2 推导表全部分支 |
| `MagpieAgentModelWriterTests` | `writeModel`：只改 `model`，`baseURL`、`apiKey`、未知键与文件权限不变；写入用临时文件 + rename；非托管状态抛 `.notManaged`；目录外模型抛 `.notInCatalog`；复读不一致抛 `.verifyFailed`；锁被占用超过 6 s 抛 `.busy`。`MagpieReconciler`（注入假的命令执行器）：参数为 `["type4me", "magpie/<model>"]`；连续三次请求只执行第一次与最后一次；执行前文件模型已被改成别的值时跳过；无命令行、退出码非 0、超时都不抛错；超时后等待进程退出才释放锁 |
| `MagpieWriteRaceTests`（时序可控） | 注入可暂停的命令执行器，复现 review 中的时序：① 保存 A，命令 A 启动并停在“写文件之前”；② 另一线程保存 B，断言 `writeModel(B)` 阻塞等待锁；③ 放行命令 A 写入 A 并退出；④ 断言 `writeModel(B)` 随后成功，文件为 B；⑤ 命令 B 运行，最终文件为 B 且执行器收到的最后一次参数为 `magpie/B`。变体：命令 A 超时被终止 → B 仍最终生效；命令 A 运行期间模拟 Magpie 外部写入 C（复读值既不是 A 也不是 B）→ 不写回 |
| `MagpieAgentWriteLockTests` | 同进程两个持有者互斥；子进程持锁时本进程 `acquire` 等待并在释放后成功；持锁进程崩溃（`kill -9`）后锁自动释放 |
| `LLMProviderDetailView` 保存路径（逻辑层测试） | 托管模式 `writeModel` 失败时 `save()` 返回 `false`，`confirmUnsavedChanges` 回调 `.cancelled`，草稿仍为 dirty；“设为默认”在保存失败时不切换默认 Provider；测试连接使用草稿模型 + Resolver 的地址与 key |
| `MagpieLocalizationTests` | Provider 名称、标签、各状态标题、错误文案在 `zh` / `en` 下都有值且不同语言不相同；切换 `tf_language` 后 `displayName` 立即变化 |
| `LLMClientCacheTests`（扩充） | Magpie 换模型或端口导致缓存失效原因为 `model` / `baseURL` |
| `LLMProviderModelOptionsTests`（扩充） | `.magpie.modelOptions` 为空，`thinkingDisableField` 为 `.lowestReasoningEffort` |

### 15.2 请求构造测试

用 `URLProtocol` 桩拦截：

- `.magpie` 请求地址为 `<baseURL>/chat/completions`，`Authorization: Bearer <key>`，`User-Agent` 以 `Type4Me/` 开头；
- 关闭思考且目录有档位 → 请求体带 `reasoning_effort: <最低档>`；目录无档位或超时 → 不带该字段；
- 连接被拒 → `LLMError.magpieUnavailable`；401 → `magpieRejected(401)`；
- 其他 Provider 的请求体与改动前一致（回归）。

### 15.3 手动验收（交给用户）

按 `CLAUDE.md`，界面操作与录音体验由用户完成。开发侧只做编译、签名、安装完整性检查。验收清单即产品设计 §11。

## 16. 实现顺序

1. Gate A：用 curl 对本机 Magpie 验证 §2.2 中网关相关事实；
2. `LLMProvider.magpie`、`MagpieLLMConfig`、注册、各穷举 switch，编译通过；
3. `MagpieAgentFile`、`MagpieGateway`、`MagpieConnectionResolver` 与单元测试；
4. `KeychainService` 分支与测试；`MagpieInstallation`、`MagpieAgentModelWriter` 与测试；
5. `MagpieModelCatalog`、`ThinkingDisableField.lowestReasoningEffort`、`DoubaoChatClient` 改动与请求构造测试；
6. 错误映射；
7. `MagpieProviderStatusModel`、`MagpieProviderSection`、`LLMProviderDetailView` 接入、分组与图标、本地化测试；
8. Gate B：用独立仓库的插件在本机 Magpie 上验证写文件、Type4Me 写回与恢复行为；
9. `CLAUDE.md`、`docs/README.md` 更新；
10. 打包安装，交给用户验收。

## 17. Gate A：网关契约

在实现第 5 步前完成，结果补充进本文档 §2：

1. `POST /v1/chat/completions`，`Authorization: Bearer magpie-type4me`，非流式与 `stream: true` + `stream_options.include_usage` 都返回 OpenAI 格式，且 Magpie 用量页记为 `type4me`；
2. 带 `reasoning_effort: low` 发往支持档位的模型，Magpie 透传或转换后上游不报错；发往无档位模型时的行为；
3. 网关未运行时 `URLError` 的具体 code；
4. 上游错误（例如无效模型 id）时 Magpie 返回的状态码与错误体格式。

## 18. Gate B：插件契约

2026-10-15 已用临时插件 `type4me-probe` 预先验证文件读写契约（见 §2.1.1 与产品设计 §5.3.1），正式插件在实现第 8 步复验：

1. `magpie plugin add ~/Projects/magpie-agent-type4me` 成功，Agent 页出现 Type4Me（加载部分已于 2026-10-15 冒烟通过）；
2. 在 Magpie 选择模型后 `magpie-agent.json` 内容符合 §6.1，Type4Me 设置页 2 秒内切到托管模式；
3. 在 Type4Me 托管模式下保存新模型：保存立即完成，文件已是新模型；约 2 秒后 `magpie type4me` 显示 `magpie/<新模型>`，`magpie ls` 无警告；
4. 删除命令行（临时改名）后保存：保存照常成功，请求正常，`magpie type4me` 显示不带前缀的模型，无警告；
4a. 在 Type4Me 保存后立即在 Magpie 选另一个模型：后台通知不覆盖 Magpie 中的新选择；
4b. 保存时接入文件不可写（临时改为只读）：保存失败，页面停留，草稿保留；
4c. 在 Type4Me 连续保存 A、B（间隔小于 1 秒）：第二次保存短暂等待后成功，最终文件、`magpie type4me` 显示均为 B；
5. `magpie type4me default` 后三个键被删除，Type4Me 回到直连模式；
6. 预验证结论：Magpie 原子替换写入，`dir` 支持 `~` 展开——已由源码确认，复验时只需观察不回归。

## 19. 风险

| 风险 | 影响 | 应对 |
|---|---|---|
| Magpie 尚在快速迭代（日更），插件字段或网关行为变化 | 接入失效 | 契约集中在 `MagpieAgentFile` / `MagpieGateway`，Gate A/B 用例保留为手动回归清单 |
| `reasoning_effort` 透传不可靠 | 关闭思考失效，延迟升高 | Gate A 验证；失败时 `.magpie` 的 `thinkingDisableField` 退回 `nil`，仅依赖现有 `<think>` 过滤 |
| 路由组选中慢模型 | 后处理延迟高 | 产品层提示；不做技术干预 |
| 接入文件被其他程序改写指向外部地址 | 文本外发 | 回环地址校验 |
| 社区插件发布周期不受我们控制 | 安装命令无法使用 npm 包名 | 过渡期使用 `github:` 安装命令或隐藏插件引导，见 §12.4 |
| 插件与 App 分仓后 `CONFIG_PATH` 不一致 | Magpie 写到 Type4Me 读不到的位置 | 两边测试断言同一字符串；修改需两个仓库同时提交 |
| Type4Me 与 Magpie 同时写插件文件 | 后写者覆盖先写者，丢失一次模型切换 | 两边都只在用户主动操作时写，窗口为毫秒级；Type4Me 写前复读、写后校验，校验失败即保存失败并保留草稿 |
| Magpie 命令行参数或输出格式变化 | 后台通知失败，Magpie 显示不带前缀的模型 | 保存成败只取决于第 1 步写文件，不受影响；后台失败只记日志 |
| 后台命令覆盖较新的 Type4Me 保存 | 已保存的模型被静默改回 | Type4Me 写文件与后台命令共用跨进程写锁；命令只在文件等于其目标值时启动并持锁到结束（§6.4 并发协议），有时序可控测试覆盖 |
| 后台命令覆盖用户在 Magpie 中 1.6 s 内的新选择 | Magpie 中的新选择被 Type4Me 最近一次保存取代 | 在 Magpie 无条件写入的前提下接受；见 §6.4 残余边界 |
| 连续保存时第二次保存需等待后台命令 | 主线程最多等待约 6 s | 只在 1.6 s 内连续保存时出现；超时返回 `.busy`，草稿保留 |
| 运行时首次请求等待模型目录 | 首次延迟最多 +300 ms | 设置页打开、Magpie 设为默认时预热目录缓存 |
