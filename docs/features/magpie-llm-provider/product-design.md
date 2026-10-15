# Type4Me Magpie LLM Provider 产品设计

> 分支：`feat/magpie-llm-provider`
> 文档类型：产品设计
> 文档状态：当前有效（设计完成，待评审）
> 设计日期：2026-10-15
> 最后校验：2026-10-15
> 对应开发设计：`docs/features/magpie-llm-provider/development-design.md`
> 外部依赖：Magpie（`yetone/magpie`，本机验证版本 0.1.1246）
> 外部文档：插件 https://usemagpie.ai/docs/zh/plugins ；接入应用 https://usemagpie.ai/docs/zh/integrate

## 1. 背景

Magpie 是一个运行在用户本机的模型网关和菜单栏应用。用户在 Magpie 里统一配置 API Key、本地模型和已登录的订阅（Claude、ChatGPT、Copilot、Gemini、Grok 等），再给每个 Agent 选择模型。Magpie 在本机 `127.0.0.1:3425` 提供 OpenAI Chat、OpenAI Responses、Anthropic Messages、Gemini 兼容接口，负责协议转换、路由组、配额耗尽切换和用量统计。

Type4Me 的 LLM 后处理（Intelli Sense、翻译、自定义 Prompt 模式、ASR 变体生成、Ask Anything 等）本质上是一个模型消费者。接入 Magpie 后：

- 用户直接使用已在 Magpie 登录的订阅额度和 Key，不需要再为 Type4Me 单独申请、粘贴 API Key；
- Magpie 的路由组、配额切换、用量统计自动覆盖 Type4Me；
- 安装 Type4Me 的 Magpie Agent 插件后，还可以在 Magpie 菜单栏给 Type4Me 换模型，和用户的其他 Agent 一致。

### 1.1 Magpie 提供的两种接入方式

调研发现 Magpie 官方给第三方提供两条接入路径，本设计两者都用：

| | 直连网关 | Agent 插件 |
|---|---|---|
| 官方文档 | “接入应用” | “插件 › Agent 插件” |
| 需要用户做什么 | 只需要 Magpie 在运行 | 额外执行 `magpie plugin add …` 安装插件 |
| 模型在哪里选 | Type4Me 里，从 Magpie 的 `/v1/models` 动态列出 | Type4Me 里或 Magpie 的 Agent 页 / 菜单栏，两边双向同步 |
| 身份与用量归属 | 请求带 `magpie-type4me` key，Magpie 记为 Type4Me | Magpie 写入 Agent 专用 key，记为 Type4Me |
| Magpie 的 Profile（`magpie save/use`）是否覆盖 Type4Me | 否 | 是 |
| Magpie Agent 页是否显示 Type4Me | 否 | 是 |

官方“接入应用”文档的原话建议：把 Magpie 作为一个额外的供应商（名为 Magpie）加在应用已有供应商旁边，模型列表从 `/v1/models` 动态读取。这和本设计的一等公民 Provider 方向一致。

## 2. 产品定位

### 2.1 一等公民 Provider，而不是复用 Custom

Magpie 作为独立 LLM Provider 出现在模型设置里，而不是让用户在“自定义（OpenAI 兼容）”里手填地址。理由：

1. 可以自动发现网关、动态列出模型，用户不需要知道端口和 key；
2. 插件托管模式下网关地址和 key 由 Magpie 写入，模型由两边共同维护，这和 Custom 的“用户手填全部字段”语义不同；
3. 需要状态感知和引导：是否安装、是否运行、是否装了插件；
4. 用户已有的 Custom 配置不受影响。

### 2.2 与 LLM Provider 收录政策的关系

`CLAUDE.md` 规定商业第三方聚合路由/网关走 Custom，不新增一等公民入口。Magpie 不属于这一类：它在本机运行，没有自己的账号体系和计费，使用的是用户自己的 Key 和订阅，定位与 Ollama 相同。本功能同时修改收录政策，增加一条明确例外：

> 本地运行、由用户自持的模型网关（如 Ollama、Magpie）可以作为一等公民 Provider。商业托管的聚合路由仍走 Custom。

### 2.3 显示名称与分组

| 项 | 中文 | 英文 |
|---|---|---|
| Provider 名称 | `Magpie（本机模型网关）` | `Magpie (Local Gateway)` |
| 标签 | `本机网关` | `Local Gateway` |
| 分组 | “本地”，排在 Codex CLI、Ollama 之后 | “Local” |

## 3. 目标与非目标

### 3.1 目标

1. 用户可在模型设置的“本地”分组选择 Magpie，并设为默认 LLM；
2. **零额外步骤可用**：Magpie 在运行时，用户在 Type4Me 里直接从 Magpie 的模型列表选模型即可使用，不需要安装插件、不需要填写 Key；
3. **可选插件托管**：安装 Type4Me 的 Magpie Agent 插件后，Type4Me 与 Magpie 共享同一份模型设置，在任意一边切换另一边都会同步；在 Magpie 菜单栏切换后，**下一次语音输入就生效**，无需重启 Type4Me；
4. Provider 页面根据实际状态给出逐步引导；
5. Type4Me 与 Type4Me Dev 共用同一份 Magpie 配置，只需要安装一个 Magpie 插件；
6. 保留现有“关闭思考”能力，按模型支持的推理档位自动取最低档；
7. Magpie 不可用时给出明确原因，后续处理与现有 LLM 失败路径一致；
8. 全部新增文案中英文齐全，切换 `tf_language` 后立即生效。

### 3.2 非目标（第一版）

- 在 Type4Me 里展示 Magpie 的路由组配置、配额或费用；
- Magpie 不可用时自动回退到其他 LLM Provider；
- 自动安装 Magpie 或 Magpie 插件；
- 通过局域网或远程访问 Magpie（只接受本机回环地址）；
- 为 Type4Me Dev 单独注册 Magpie Agent；
- 把 Magpie 当作 ASR Provider；
- 改用 Magpie 的 Anthropic / Responses 接口（统一走 OpenAI Chat Completions）。

## 4. 用户故事

1. **已在用 Magpie、只想快速用上**：在 Type4Me 选择 Magpie，页面显示“Magpie 正在运行”，从模型下拉里选 `deepseek/deepseek-chat`，点“设为默认”。全程没有复制任何东西。
2. **想在 Magpie 菜单栏统一管理**：在 Magpie 页面展开插件引导，复制安装插件的命令到终端执行，再在 Magpie 菜单栏给 Type4Me 选模型。Type4Me 页面自动变为“已与 Magpie 同步”，模型下拉显示 Magpie 选的模型。
3. **托管模式下在 Magpie 切换模型**：在 Magpie 菜单栏把 Type4Me 从 `deepseek/deepseek-chat` 换成 `group/auto-gemini-3-8-flash`，下一次按快捷键说话就用新模型，Type4Me 设置页同时更新。
4. **托管模式下在 Type4Me 切换模型**：在 Type4Me 的模型下拉里换成另一个模型并保存，Magpie 菜单栏和 Agent 页随之显示新模型。
5. **没装 Magpie**：在“本地”分组看到 Magpie，点进去看到一句话介绍、安装命令和下载入口，可以选择不使用。
6. **Magpie 没开**：默认 LLM 是 Magpie 但 Magpie 已退出，说完话后提示“Magpie 未运行”；设置页给出“打开 Magpie”按钮。
7. **开发者使用 Type4Me Dev**：Dev 自动读到同一份 Magpie 配置（直连模式下选的模型，或托管模式下 Magpie 写入的模型），只需在 Dev 里也把 Magpie 设为默认。

## 5. 两种模式

### 5.1 模式判定

用户不需要手动切换模式，Type4Me 按下面规则自动判定：

- 插件接入文件中有完整的模型、网关地址和 key → **Magpie 托管**；
- 否则 → **直连**。

用户在 Magpie 里对 Type4Me 执行“恢复默认”或卸载插件后，接入文件里的字段被 Magpie 删除，Type4Me 自动回到直连模式，并继续使用直连模式下之前选的模型（若有）。

### 5.2 直连模式

- 网关地址自动发现，用户看不到也不需要填写；
- 模型下拉从 Magpie `/v1/models` 动态读取，显示 Magpie 给的模型名称，路由组单独分为一组；
- Magpie 不在运行时，下拉显示上次保存的模型，不可展开，并提示打开 Magpie；
- 选好的模型和其他 Provider 一样，在点“保存”后生效。

### 5.3 Magpie 托管模式

- 模型、网关地址和 key 都来自 Magpie 写入的接入文件；
- **模型可以在两边修改**：Type4Me 的模型下拉与直连模式相同，保存后 Magpie 菜单栏与 Agent 页同步显示；在 Magpie 切换后，Type4Me 设置页 2 秒内同步；
- 网关地址和 key 只由 Magpie 写入，Type4Me 不改；
- 保存分两步：Type4Me 先直接改写文件中的 `model` 一项，写完立即确认，保存马上完成；随后在后台调用 Magpie 自己的命令行，让 Magpie 把它记为在 Magpie 里做的选择（Agent 页显示 `magpie/<模型>`）。后台这一步失败只影响 Magpie 的显示方式，不影响使用，也不提示用户；
- 保存通常立即完成，所以保存后切页、关闭窗口、设为默认都不需要等待；保存失败时页面停留，未保存的修改保留；
- 例外：上一次保存的后台同步还在进行时（约 1.6 秒内连续保存），新的保存会短暂等待它结束，保证后保存的模型一定生效；等待超过 6 秒则提示稍后再试，修改保留。

#### 5.3.1 双向读写的确认结果

这一节回答“Type4Me 和 Magpie 能否同时读写同一个接入文件”。依据是 Magpie 源码（`internal/agent/plugged.go`、`internal/edit/file.go`）和本机实测（临时插件 `type4me-probe`，测试后已卸载并清理）。

| 问题 | 结论 | 依据 |
|---|---|---|
| Magpie 能否读到 Type4Me 的改动 | 能，且立即生效 | Magpie 每次显示都重新读文件，读缓存按文件修改时间和大小失效；实测改写后 `magpie type4me-probe` 立即显示新值 |
| Type4Me 改模型后，请求还走 Magpie 吗 | 走。Magpie 只用 key 判断“是否仍由 Magpie 接入”，不看模型 | `onMagpie()` 只比较 key 这一项；实测改模型后用文件里的 key 请求新模型，返回正常 |
| Magpie 会不会报“被手动改动” | 不会。只有 key 或网关地址被改才报 | `Check()` 在模型与 Magpie 记录不一致时直接返回空；实测 `magpie ls` 无警告 |
| Type4Me 改过之后，Magpie 还能再切换吗 | 能 | 实测 Type4Me 改写后再执行 `magpie type4me-probe magpie/<model>`，文件被正确更新 |
| Magpie “恢复默认”还正确吗 | 正确。恢复的是 Magpie 首次接入前的原值，与之后谁改过模型无关 | 实测 Type4Me 改写后执行 `default`，文件恢复为 `{}` |
| Magpie 写文件会不会把 Type4Me 读到一半的文件弄坏 | 不会。Magpie 先写临时文件再整体替换，并保留文件权限 | `edit.WriteAtomic`：临时文件、fsync、rename |
| 两边同时写会怎样 | 没有跨进程锁，同一瞬间各写一次时后写者覆盖先写者 | Magpie 对插件文件没有使用 `filelock`。两边都只在用户主动切换时写入，写入窗口为毫秒级，实际冲突概率很低 |
| 直接改文件和通过 Magpie 命令行改，有什么区别 | 命令行修改后 Magpie 显示为 `magpie/<模型>`（Magpie 选择）；直接改文件后 Magpie 显示为不带前缀的模型（Agent 自带设置），模型目录变化时 Magpie 不会代为重写 | `get()` 比较文件值与 Magpie 记录的 `Ref` |

结论：两边可以同时读写。Type4Me 保存时先直接改写 `model`（保证立即生效、保存结果可靠），再在后台调用 `magpie type4me magpie/<model>` 让 Magpie 的显示和记录一致。

## 6. Provider 详情页设计

详情页沿用现有 `LLMProviderDetailView` 的头部（图标、名称、标签、设为默认）和底部操作栏（测试连接、保存、还原），把“参数配置”卡片替换为下面的状态驱动内容。

### 6.1 状态表

从上到下判定，命中第一条即显示对应界面。

| # | 状态 | 判定 | 主要内容 | 操作 |
|---|---|---|---|---|
| T1 | 托管 · 在线 | 接入文件完整，网关在线 | “已与 Magpie 同步”、模型下拉、网关地址、关闭思考开关、隐私说明 | 保存；测试连接；打开 Magpie |
| T2 | 托管 · 离线 | 接入文件完整，网关离线 | “Magpie 未运行” + 当前模型（不可修改，模型列表和命令行都依赖 Magpie 运行） | 打开 Magpie |
| D1 | 直连 · 在线 | 网关在线 | 模型下拉、关闭思考开关、隐私说明、插件引导（折叠） | 保存；测试连接 |
| D2 | 直连 · 已安装未运行 | 网关离线，检测到 Magpie.app 或 `magpie` 命令 | “Magpie 已安装但未运行” + 已保存的模型（只读） | 打开 Magpie |
| D3 | 未安装 | 以上都不满足 | 介绍、安装命令 | 下载 Magpie；复制命令 |

附加提示（叠加在上述状态之上，不改变状态）：

- 接入文件存在但无法解析：黄色提示“Magpie 接入文件无法读取，已按直连模式处理”，带“在 Finder 中显示”；
- 接入文件中的网关地址不是本机回环地址：黄色提示“接入文件中的网关地址不是本机地址，已忽略”，按直连模式处理；
- 当前模型是路由组（id 以 `group/` 开头）：“这是 Magpie 路由组，实际使用的模型由 Magpie 按规则选择，响应速度可能不稳定。”

“设为默认”在 T1、T2 可用；在 D1、D2 中，已保存过模型时可用。离线状态允许设为默认，因为 Magpie 只是暂时没开。

### 6.2 D1 直连 · 在线

```text
┌ 参数配置 ──────────────────────────────────────────────┐
│ ● Magpie 正在运行（0.1.1246）                            │
│ 模型        [ deepseek/deepseek-chat              ▾ ]    │
│ 关闭思考    [●]                                          │
│ 文本会经 Magpie 转发给你在 Magpie 中为该模型配置的服务商。 │
│ ─────────────────────────────────────────────────────── │
│ ▸ 想在 Magpie 菜单栏切换 Type4Me 的模型？                 │
└─────────────────────────────────────────────────────────┘
                                   [测试连接]  [保存]
```

展开“想在 Magpie 菜单栏切换 Type4Me 的模型？”（显示社区包名的安装命令，见 Q6）：

```text
│ ▾ 想在 Magpie 菜单栏切换 Type4Me 的模型？                 │
│   ① 安装 Type4Me 插件                                    │
│      magpie plugin add @magpie-community/agent-type4me [复制] │
│   ② 在 Magpie 的 Agent 页为 Type4Me 选择模型   [打开 Magpie] │
│   完成后此页面会自动切换为“已与 Magpie 同步”。             │
```

模型下拉的分组：

```text
路由组
  Super Intelligence · routing group      group/super-intelligence
  ...
模型
  DeepSeek Chat                           deepseek/deepseek-chat
  ...
```

### 6.3 T1 托管 · 在线

```text
┌ 参数配置 ──────────────────────────────────────────────┐
│ ✓ 已与 Magpie 同步  在这里或 Magpie 菜单栏切换模型都会同步 │
│ 模型        [ deepseek/deepseek-chat              ▾ ]    │
│ 网关        http://127.0.0.1:3425/v1                     │
│ 关闭思考    [●]                                          │
│ 文本会经 Magpie 转发给你在 Magpie 中为该模型配置的服务商。 │
└─────────────────────────────────────────────────────────┘
                          [打开 Magpie]  [测试连接]  [保存]
```

- Magpie 写入接入文件后，页面在 2 秒内从 D1 自动切到 T1，无需重新打开设置；
- 在 Magpie 切换模型后，下拉在 2 秒内更新；若此时 Type4Me 的下拉有未保存的修改，保留用户的修改，并在操作栏提示“Magpie 中的模型已变为 %@”，由用户决定保存还是还原；
- 保存立即完成；失败时提示原因，页面停留并保留未保存状态。

### 6.4 D3 未安装

```text
┌ 参数配置 ──────────────────────────────────────────────┐
│ Magpie 是一个本机模型网关，可以让 Type4Me 使用你在 Magpie │
│ 中登录的订阅或 API Key，并和其他 Agent 一起切换模型、统计用量。│
│                                                         │
│ curl -fsSL https://usemagpie.ai/install.sh | sh   [复制] │
└─────────────────────────────────────────────────────────┘
                                            [下载 Magpie]
```

### 6.5 关闭思考

语音后处理对延迟敏感，现有 Provider 默认关闭思考。Magpie 背后的模型各不相同，大多数不支持完全关闭，只支持若干推理档位（本机实测：`minimal/low/medium/high`、`low/medium/high`、`low/high/max` 等）。因此：

- 开关语义保持“关闭思考”，对 Magpie 实际含义是“使用该模型支持的最低推理档位”；
- 模型不支持推理档位时不发送该参数，开关隐藏；
- 开关的说明文字：“使用该模型支持的最低推理档位，降低延迟。”

## 7. 运行时行为

| 场景 | 行为 |
|---|---|
| 托管模式下 Magpie 换模型 | 下一次 LLM 调用读到新模型，无需重启 |
| 托管模式下 Type4Me 换模型 | 保存后 Magpie 立即显示新模型，下一次 LLM 调用生效 |
| 直连模式下修改模型 | 与其他 Provider 一致，保存后下一次调用生效 |
| Magpie 端口改变 | 直连模式自动发现新端口；托管模式由 Magpie 改写接入文件 |
| 网关离线 | 本次 LLM 调用失败，提示“Magpie 未运行，请打开 Magpie”；后续处理与现有 LLM 失败一致 |
| 网关返回 401/403 | 提示“Magpie 拒绝了请求，请在 Magpie 中检查 Type4Me 的接入” |
| 网关返回上游错误（额度、模型不可用等） | 显示 Magpie 返回的错误信息 |
| 直连模式下没选模型 | Magpie 不可设为默认；若已是默认，提示“请先在 Type4Me 中为 Magpie 选择模型” |

## 8. Type4Me 与 Type4Me Dev

- 插件接入文件和直连模式的模型都放在 Prod 与 Dev 共享的 Profile 目录 `~/Library/Application Support/Type4Me/`，两者读到相同的配置；
- 默认 LLM Provider 按应用分别保存，Dev 需要单独把 Magpie 设为默认；
- Magpie 插件以共享 Profile 目录判断 Type4Me 是否已安装，只装 Dev 时也能识别；
- 用量归属见 §12 决策 Q4。

## 9. 隐私与安全

- 直连模式的 key 是固定标识 `magpie-type4me`，不是密钥；托管模式的 Agent key 只能访问本机 Magpie 网关。两者都不存入钥匙串，也不写入日志、问题报告或历史，界面不显示托管模式的 key；
- Type4Me 对插件接入文件只修改 `model` 一项，网关地址和 key 只由 Magpie 写入；
- 详情页明确告知文本会经 Magpie 转发给用户在 Magpie 中选择的服务商；
- 只接受本机回环地址（`127.0.0.1`、`localhost`、`::1`）作为网关地址，防止接入文件被改写后把文本发往外部。

## 10. 文案（中英对照）

| 位置 | 中文 | English |
|---|---|---|
| 名称 | Magpie（本机模型网关） | Magpie (Local Gateway) |
| 标签 | 本机网关 | Local Gateway |
| 在线 | Magpie 正在运行（%@） | Magpie is running (%@) |
| 托管 | 已与 Magpie 同步 | Synced with Magpie |
| 托管说明 | 在这里或 Magpie 菜单栏切换模型都会同步 | Switching the model here or in Magpie's menu bar keeps both in sync |
| 托管外部变更 | Magpie 中的模型已变为 %@ | Magpie switched the model to %@ |
| 保存失败 | 无法同步到 Magpie：%@ | Couldn't sync to Magpie: %@ |
| 保存忙 | Magpie 正在同步上一次修改，请稍后再保存 | Magpie is still syncing your last change. Try saving again in a moment. |
| 隐私说明 | 文本会经 Magpie 转发给你在 Magpie 中为该模型配置的服务商。 | Text is sent through Magpie to the provider you set up for this model in Magpie. |
| 路由组提示 | 这是 Magpie 路由组，实际使用的模型由 Magpie 按规则选择，响应速度可能不稳定。 | This is a Magpie routing group. Magpie picks the model by its rules, so response time may vary. |
| 下拉分组 | 路由组 / 模型 | Routing Groups / Models |
| 插件引导标题 | 想在 Magpie 菜单栏切换 Type4Me 的模型？ | Want to switch Type4Me's model from Magpie's menu bar? |
| 插件步骤 1 | 安装 Type4Me 插件 | Install the Type4Me plugin |
| 插件步骤 2 | 在 Magpie 的 Agent 页为 Type4Me 选择模型 | Pick a model for Type4Me on Magpie's Agents page |
| 插件完成说明 | 完成后此页面会自动切换为“已与 Magpie 同步”。 | This page switches to "Synced with Magpie" on its own when you're done. |
| 离线 | Magpie 未运行 | Magpie isn't running |
| 已安装未运行 | Magpie 已安装但未运行 | Magpie is installed but not running |
| 未安装介绍 | Magpie 是一个本机模型网关，可以让 Type4Me 使用你在 Magpie 中登录的订阅或 API Key，并和其他 Agent 一起切换模型、统计用量。 | Magpie is a local model gateway. Type4Me can use the subscriptions and API keys you set up in Magpie, and switch models and track usage alongside your other agents. |
| 关闭思考说明 | 使用该模型支持的最低推理档位，降低延迟。 | Uses the lowest reasoning level this model supports, to cut latency. |
| 文件损坏 | Magpie 接入文件无法读取，已按直连模式处理。 | Can't read the Magpie connection file, so Type4Me is connecting directly. |
| 非本机地址 | 接入文件中的网关地址不是本机地址，已忽略。 | The gateway address in the connection file isn't on this Mac, so it was ignored. |
| 按钮 | 打开 Magpie / 下载 Magpie / 复制 / 已复制 / 在 Finder 中显示 | Open Magpie / Download Magpie / Copy / Copied / Show in Finder |
| 错误：未运行 | Magpie 未运行，请打开 Magpie | Magpie isn't running. Open Magpie and try again. |
| 错误：未选模型 | 请先在 Type4Me 中为 Magpie 选择模型 | Pick a Magpie model in Type4Me first |
| 错误：拒绝 | Magpie 拒绝了请求，请在 Magpie 中检查 Type4Me 的接入 | Magpie refused the request. Check Type4Me's connection in Magpie. |

## 11. 验收标准

1. “本地”分组出现 Magpie，图标、名称、标签在中英文下正确；
2. Magpie 运行时，不装插件即可在 Type4Me 选模型、测试连接、设为默认并完成一次语音后处理；
3. 安装插件并在 Magpie 选模型后，详情页 2 秒内切到“已与 Magpie 同步”，无需重开设置；
4. 托管模式下 Magpie 换模型，下一次语音输入使用新模型（通过 Magpie 用量页或 debug 日志确认），Type4Me 下拉 2 秒内更新；
5. 托管模式下在 Type4Me 换模型并保存：保存立即完成，下一次语音输入即用新模型；数秒内 `magpie type4me` 显示 `magpie/<新模型>`，Magpie Agent 页无“被改动”警告；之后在 Magpie 再切换、恢复默认均正常；保存失败时页面停留并保留修改，“设为默认”不生效；
6. 在 Magpie 中对 Type4Me “恢复默认”后，Type4Me 回到直连模式且之前直连选的模型仍在；
7. 关闭思考开启时，请求带上该模型最低推理档位；模型不支持推理档位时不带该参数；
8. 退出 Magpie 后语音输入给出“Magpie 未运行”；
9. Dev 读到与 Prod 相同的 Magpie 配置；
10. 用户原有 Custom 及其他 Provider 配置不受影响；
11. 托管模式的 key 不出现在界面、日志、问题报告中；
12. 所有状态与文案在中英文间切换后立即更新。

## 12. 待评审决策

| # | 问题 | 建议 |
|---|---|---|
| Q1 | 是否同时支持直连和插件托管两种模式 | 支持。直连让 Magpie 用户零步骤可用，插件托管满足在 Magpie 菜单栏统一管理的需求。只做插件会让每个用户都多一步命令行操作 |
| Q2 | Magpie 放在“本地”分组还是“推荐”分组 | 本地。推荐分组面向无门槛的首选项，Magpie 需要先安装 |
| Q3 | Magpie 离线时是否自动回退到其他 Provider | 不回退。回退会让用户不清楚文本发往何处 |
| Q4 | 直连模式下 Prod 和 Dev 是否用不同的身份（`magpie-type4me` / `magpie-type4me-dev`）以便在 Magpie 用量里区分 | 区分。成本为零，便于对比 Dev 改动前后的用量；托管模式下两者共用插件 key，无法区分 |
| Q5 | 插件仓库归属 | **已决定**：独立公开仓库 https://github.com/kchen0x/magpie-agent-type4me （本机 `~/Projects/magpie-agent-type4me`），已并入 `magpie-community/plugins`（#136，2026-10-15 合并），插件目录登记见 #139；首个 npm 版本需要社区维护者发布 |
| Q6 | 插件发布到 npm 之前，设置页是否显示插件引导 | **已决定**：显示 `magpie plugin add @magpie-community/agent-type4me`。插件已并入社区仓库（#136），Magpie 0.1.1243 及以后在 npm 发布前从社区 `dist` 分支安装；更早的 Magpie 可改用 `github:kchen0x/magpie-agent-type4me` |
| Q7 | 托管模式下 Type4Me 修改模型的方式 | **已决定**：先同步改写 `model` 一项作为保存结果，再在后台调用 `magpie type4me magpie/<model>` 让 Magpie 记录一致。两步共用一把写锁，保证后台命令不会覆盖更新的保存（技术设计 §6.4）。保留后台命令是为了 Magpie Profile：只改文件时，应用 Profile 会让 Type4Me 掉回直连模式。依据见 §5.3.1 |
