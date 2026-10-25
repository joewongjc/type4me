# 手机版：iPhone 语音键盘与 Mac 配置同步

> 文档类型：产品与开发设计
> 状态：已实现，测试中（自行安装）
> 设计日期：2026-10-25
> 最后校验：2026-10-25
> 实现基线：`9334f5d1`（PR #372）

## 1. 产品

iPhone 上的 Type4Me 是一个语音键盘：在任何输入框切到 Type4Me 键盘，按住说话，松手出字。识别服务、文本模型、模式、热词和片段替换都和 Mac 版对应。

- **分发**：暂未上架 App Store。代码在仓库 `iOS/` 目录，用户用 Xcode 自行安装，步骤见 [iOS/README.md](../../../iOS/README.md)。
- **入口**：Mac 版侧边栏「设置」上方的「手机版」页面。上半部分说明如何安装，下半部分是扫码同步。
- **同步**：没有服务器。Mac 把配置编码成二维码（内容多时拆成几张轮播），手机扫码后在导入页挑选要保存的内容。
- **不同步的内容**：本地识别引擎和本机模型网关（只在 Mac 上运行）、智能感知 / Mac 操作 / 随便问 / Prompt 优化（需要 Mac 的上下文或工具）、应用专属片段（手机键盘无法知道正在给哪个 App 输入）。

## 2. 架构

```
┌──────────── iPhone ────────────┐            ┌──────── Mac ────────┐
│ Keyboard 扩展                   │            │ 手机版页面           │
│  模式切换 · 按住说话 · 出字       │            │  MobileSyncPanel    │
│        │ App Group 文件 + Darwin │            │  MobileConfigExporter│
│        ▼ 通知                    │   二维码    │        │            │
│ 主 App（后台待命）               │ ◀───────── │  Type4MeTransferCore │
│  VoiceSession：录音→识别→模式    │            └─────────────────────┘
│  ConfigStore（钥匙串）            │
│  ModeStore · VocabularyStore     │
└─────────────────────────────────┘
```

- **键盘不录音**：iOS 不允许键盘扩展使用麦克风。键盘通过 App Group 里的指令文件和 Darwin 通知（`Shared/DictationIPC.swift`）让主 App 录音、识别、调用模型，再把结果写回给键盘插入。
- **后台开麦**：主 App 在前台开启会话时激活 `playAndRecord` 音频会话并输出静音，同时保持一个不可见的画中画会话（`PiPKeeper`），之后只在按住说话时打开麦克风，松开就关。
- **复用 Mac 源码**：`iOS/project.yml` 直接编译 `Type4Me/ASR`、`Type4Me/Protocol`、`LLMProvider.swift`、翻译提示词与校验等文件，识别协议和服务商表只维护一份。
- **共用模块** `Type4MeTransferCore`：同步格式和片段替换的匹配规则（`SnippetPattern`），Mac 和 iPhone 都链接它。

## 3. 同步格式

`Type4MeTransferPayload`，zlib 压缩后 base64url 编码，前缀 `T4M2.`；超过约 1000 字符时拆成 `T4MP.<组>.<序号>.<总数>.<内容>` 多张码，任意顺序扫齐即可。单张码是 `type4me://import?c=…`，iPhone 相机扫码能直接打开导入页。

| 字段 | 键 | 内容 |
|---|---|---|
| `asr` / `asrProfiles` | `a` / `as` | 识别服务，第一个为默认 |
| `llm` / `llmProfiles` | `l` / `ls` | 文本模型，第一个为默认 |
| `modes` | `m` | 模式；内置模式只传类型和用户改过的提示词 |
| `hotwords` | `h` | 用户热词 |
| `snippets` | `s` | 全局片段替换 |
| `sourceName` / `createdAt` | `d` / `t` | 来源 Mac 名称与时间 |

新增字段都是可选的，旧版接收方会忽略，因此版本号保持 2。二维码里的 API Key 没有加密，界面上默认模糊，点击后才显示。

## 4. 导入规则

- **服务**：按服务商合并到手机的服务列表，勾选「默认」的直接启用。密钥只存在 iPhone 钥匙串（`ConfigStore`）。
- **模式**：内置模式更新名称和提示词；自定义模式按 ID 更新或新增，键盘有空位时直接放上去。
- **词汇**：只增不删。热词按忽略大小写去重；片段按触发词（忽略大小写和空格）匹配，已有的以 Mac 为准。
- 识别时把热词传给识别服务；片段替换在模式处理之前作用于识别结果，与 Mac 顺序一致。

## 5. 自行安装的签名

`iOS/Signing.xcconfig` 提供默认值，用户在 Git 忽略的 `Signing.local.xcconfig` 里填 Team ID 和 bundle ID 前缀。App、键盘、App Group 分别是 `<前缀>.ios`、`<前缀>.ios.keyboard`、`group.<前缀>.ios`；App Group 写进每个 target 的 Info.plist（`T4MAppGroup`），运行时由 `SharedContainer` 读取。

## 6. 测试

- Mac：`Type4MeTransferTests`（编解码、多码拼接、词汇字段）、`MobileConfigExporterTests`（导出内容与模式映射）。
- iPhone：`iOS/README.md` 的真机验证清单；`iOS/UITests` 是模拟器截图脚本，不作为 CI 门槛。
