> update：官方[词库管理Skill](https://github.com/joewongjc/type4me-vocab-skill)，帮你大幅提高识别准确率

<p align="center">
  <img src="docs/images/header-combined.svg" width="100%" alt="Type4Me - macOS 语音输入法" />
</p>


- **语音识别**：内置本地识别引擎、媲美云端引擎准确率；支持多家云端引擎厂商；支持流式识别、边说边出字，说完无需等待、快速输入；
- **文本处理**：内置润色、Prompt优化、翻译功能，可自定义添加任意处理模版（比如改人设、改语气、小语种翻译等等）；
- **模型接入**：支持主流厂商API接入；文本处理支持使用Ollama接本地模型；
- **词汇管理**：支持热词、映射词，2种模式。热词用于校正语音识别引擎，映射词可作为兜底或个性化场景使用（如 Web coding -> Vibe Coding, "我的邮箱地址" -> xxx@gmail.com）；
- **历史记录**：存储所有历史识别记录，包括原始文本和处理后文本，支持导出CSV；
- **配套Skill**：真正做到100%准确率，打造只属于你的输入法，[点这里安装Skill](https://github.com/joewongjc/type4me-vocab-skill)后跟你的agent说"Qwen3.5 不要识别成 Queen 3.5"，他就能自动帮你管理热词和映射词，同类错误不再犯 

## 立即体验

**方式一：直接下载DMG（推荐）**

两个版本，共享配置文件，可随时替换安装：  

| 版本                                                         | 说明                                                         | 安装包大小   |
| ------------------------------------------------------------ | ------------------------------------------------------------ | ------ |
| ✨推荐：**[云端版本（点击下载）](https://github.com/joewongjc/type4me/releases/download/v1.6.2/Type4Me-v1.6.2-cloud.dmg)** | 支持云端识别 (Intel + Apple Silicon)，需配置语音、大模型API Key。语音识别推荐火山-豆包语音/Soniox、体验最好。火山注册有送额度，单价都十分便宜。[配置指引](https://my.feishu.cn/wiki/QdEnwBMfUi0mN4k3ucMcNYhUnXr) | ~4MB  |
| **[本地版本（点击下载）](https://github.com/joewongjc/type4me/releases/download/v1.6.2/Type4Me-v1.6.2-local-apple-silicon.dmg)** | 内嵌 SenseVoice + Qwen3-ASR 本地识别引擎 (Apple Silicon only，约占用8GB内存，建议32GB以上)，大模型依旧需要配置API Key或Ollama本地服务。 | ~725MB |

系统要求：macOS 14+ (Sonoma)

**DMG提示无法打开、损坏、APP安装后打不开？**

> 解决方案：  
>
> - Step 1：打开「终端」，运行下列命令
>
>   xattr -d com.apple.quarantine /Applications/Type4Me.app
>
>   ```bash
>   spctl --master-disable
>   ```
>
> - Step 2：打开「系统设置」，进入「隐私与安全性 - 允许以下来源的应用程序」，选择「任何来源」
>
> - Step 3：打开DMG安装包，将Type4Me拖入Application文件夹后打开。
>
> - Step 4（可选）：回到系统设置，把刚刚的「允许以下来源的应用程序」从任何来源改回去。

> 因为目前还没有申请好Apple的开发者认证（努力申请中），这是正常提示，可通过配置解决。

**方式二：复制本项目的链接丢给你的 Agent帮你部署**

## 界面预览

<p align="center">
  <img src="https://github.com/user-attachments/assets/80b7e36d-92a4-40fb-84d6-d0b9da49bbcc" width="400" />
  <img src="https://github.com/user-attachments/assets/480df251-cd5f-462f-a574-ad0f5abd328a" width="400" />
</p>
<p align="center">
  <img src="https://github.com/user-attachments/assets/84a531be-b6d1-44e6-8dff-6763e9298ac1" width="400" />
  <img src="https://github.com/user-attachments/assets/ab2eecbb-62f1-4895-bd7c-49c138ef6da0" width="400" />
</p>


[查看演示视频](#演示视频)


## 为什么做Type4Me

市面上语音输入法，至少命中以下问题之一：贵（$30/月）、封闭（不可导出记录）、扩展性差（不能自定义Prompt）、慢（强制优化及网络延迟）  

作为某最贵识别工具曾经的粉丝，心路历程就是：**「它怎么可以这么好用，但又这么难用」**
以及也不必所有的话都说的这么工工整整规规矩矩。
## 使用Tips

- 语音识别：
  - 推荐使用云端模型，成本极低（我高强度用说了5w字=5小时，对应5块人民币，豆包语音注册送40小时，[配置指引](https://my.feishu.cn/wiki/QdEnwBMfUi0mN4k3ucMcNYhUnXr)）
  - 尽管本地模型效果还不错，但十分占用内存，内嵌Sense Voice用于流式识别（2GB内存占用）、Qwen3 ASR做校准（8GB内存占用），你也可以单独开其中一个，但体验不佳，Sense Voice中文不错、但英文单词十分拉垮。
- 文本处理（接入LLM）：
  - 依旧推荐使用云端模型，接入Coding Plan API，这类轻量文本处理Token消耗肉眼不可见；
  - LLM本地跑的内存占用比语音识别还高，而且效果相比云端模型相去甚远；
  - **不要**使用思考模式，推荐轻量模型。作者自己用的是Seed-2.0-lite。例如Minimax M2.7无法关闭思考，处理时间会非常长。对于我们这种轻量文本处理完全没有必要，牺牲体验也换不到效果。
    - 如果你发现你的处理时间很长，请把你使用的厂商和模型告诉我，我看看代码里是否成功关闭思考（目前没有遍历测试所有API）
- **强烈建议**搭配[配套Skill](https://github.com/joewongjc/type4me-vocab-skill)使用：市面上所有的语音输入法，专有名词均无法做到很好的识别（例如：Qwen 3.5），搭配Skill使用1-2天，你将彻底迈入100%识别准确率



## 详细功能介绍

### 语音识别（略）

### 文本处理：需配置API Key，效果受模型影响，可自行调整/添加Prompt

每个模式可以绑定独立的全局快捷键，支持「按住说话」和「按一下开始/再按停止」两种方式。

| 模式           | 说明                                                         |
| -------------- | ------------------------------------------------------------ |
| **快速模式**   | 实时识别出文字，识别完成即输入，零延迟                       |
| **语音润色**   | （简单说就是类似Typeless的体验吧- -）帮你优化表达、消除口头语、纠正等 |
| **英文翻译**   | 说中文，输出英文翻译                                         |
| **Prompt优化** | 说一句简单的原始prompt，帮你优化后直接粘贴                   |
| **自定义**     | 自己写 prompt，用 LLM 做任何后处理                           |

#### Prompt 变量高级玩法

Prompt 模板支持三种变量，让语音输入从"听写"升级为"语音命令"：

| 变量          | 含义                     |
| ------------- | ------------------------ |
| `{text}`      | 语音识别的文字           |
| `{selected}`  | 录音开始时光标选中的文字 |
| `{clipboard}` | 录音开始时剪切板的内容   |

**用法示例**：

<img src="https://github.com/user-attachments/assets/4b431890-49aa-405c-b707-72ea093cfbc4" width="400" />


### 词汇管理

- **ASR 热词**：添加专有名词（如 `Claude`、`Kubernetes`），提升识别准确率
- **片段替换**：语音说「我的邮箱」，自动替换为实际邮箱地址


## 架构概览

| 模块 | 说明 |
|------|------|
| `Type4Me/ASR/` | ASR 引擎抽象层，可插拔 Provider 架构 |
| `Type4Me/Audio/` | 音频采集 (16kHz mono PCM) |
| `Type4Me/Session/` | 核心状态机：录音 → ASR → 注入 |
| `Type4Me/Services/` | 凭证存储、热词、模型管理、Python 服务管理 |
| `Type4Me/LLM/` | LLM 文本处理 (13 个 provider) |
| `Type4Me/Input/` | 全局快捷键管理 |
| `Type4Me/Injection/` | 文本注入 (剪贴板 Cmd+V) |
| `Type4Me/Bridge/` | SherpaOnnx C API Swift 桥接 (可选) |
| `Type4Me/UI/` | SwiftUI 界面：浮窗 + 设置 |
| `qwen3-asr-server/` | Python Qwen3-ASR 校准服务 (Apple Silicon, MLX) |

ASR Provider 架构设计为可插拔：实现 `ASRProviderConfig`（定义凭证字段）和 `SpeechRecognizer`（实现识别逻辑），注册到 `ASRProviderRegistry` 即可添加新引擎。


## 参与贡献

欢迎提交 PR/Issue，这个项目是我全部自己用 Claude Code 写的。

对于 PR，即便有 bug/代码质量不好，我最常跟 Claude 说的一句话就是不要漏了人家的贡献。你大不了合完再改。


## 致谢

- [SenseVoice](https://github.com/FunAudioLLM/SenseVoice) - Alibaba FunAudioLLM
- [streaming-sensevoice](https://github.com/pengzhendong/streaming-sensevoice) - @pengzhendong
- [asr-decoder](https://github.com/pengzhendong/asr-decoder) - @pengzhendong
- [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) - k2-fsa
- [Qwen3-ASR](https://github.com/QwenLM/Qwen3-ASR) - Alibaba Qwen
- [mlx-qwen3-asr](https://github.com/moona3k/mlx-qwen3-asr) - @moona3k


## For AI Agents

If you're an AI agent (Claude Code, Cursor, Copilot, etc.) tasked with building, deploying, or contributing to Type4Me, here's everything you need.

### Read these files first

1. `CLAUDE.md` - full architecture guide, credential storage, key files, development patterns, and how to add new ASR/LLM providers
2. `Package.swift` - Swift Package Manager dependencies and build targets
3. `scripts/deploy.sh` - the build & deploy pipeline (calls `scripts/package-app.sh`)

### Prerequisites

- macOS 14.0+ (Sonoma)
- Xcode Command Line Tools: `xcode-select --install`
- Python 3.12: `brew install python@3.12` (for local ASR servers)
- CMake: `brew install cmake` (only if building SherpaOnnx punctuation engine)

### Build & deploy

```bash
# 1. Clone
git clone https://github.com/joewongjc/type4me.git && cd type4me

# 2. (Optional) Build SherpaOnnx punctuation engine (~5 min, needs cmake)
bash scripts/build-sherpa.sh

# 3. (Optional) Setup Qwen3-ASR server (needs python3.12, Apple Silicon only)
cd qwen3-asr-server && python3.12 -m venv .venv && source .venv/bin/activate && pip install -r requirements.txt && cd ..

# 4. Deploy (builds, bundles .app, signs, installs to /Applications, launches)
bash scripts/deploy.sh

# Subsequent updates
git pull && bash scripts/deploy.sh
```

Steps 2-3 are optional. Skipping them disables local ASR, but cloud ASR works fine.

### Code signing & permissions

`deploy.sh` handles code signing automatically to **preserve macOS permissions across rebuilds**:

- **First deploy** auto-creates a self-signed certificate ("Type4Me Local", valid 10 years) if no signing identity exists. This may trigger a **Keychain password prompt** that requires human interaction.
- **Subsequent deploys** reuse the same certificate. Accessibility/Microphone permissions persist, no re-grant needed.
- After first launch, the user must grant **Accessibility permission** once (System Settings → Privacy & Security → Accessibility → enable Type4Me).
- To override signing identity: `CODESIGN_IDENTITY="Your Cert" bash scripts/deploy.sh`
- Fallback to ad-hoc signing: `CODESIGN_IDENTITY="-" bash scripts/deploy.sh` (Accessibility permission will reset each build)

### Key architecture points

- **Swift Package Manager** project, no `.xcodeproj` needed
- **Local ASR**: dual-engine design. SenseVoice (streaming partial results) + Qwen3-ASR (final calibration via MLX/Metal). Both run as Python WebSocket servers managed by `SenseVoiceServerManager`
- **Cloud ASR**: 7 providers implemented (Volcano, OpenAI, Deepgram, AssemblyAI, Soniox, Bailian, Baidu)
- **Credentials**: stored at `~/Library/Application Support/Type4Me/credentials.json` (mode 0600), never in code or environment variables. GUI apps cannot read shell env vars from `~/.zshrc`
- **ASR provider architecture**: plugin-based. To add a new provider: implement `ASRProviderConfig` + `SpeechRecognizer` protocol, register in `ASRProviderRegistry.all`. See `CLAUDE.md` for details
- **Audio format**: 16kHz mono PCM16-LE, 200ms chunks (6400 bytes)
- **Text injection**: clipboard-based Cmd+V paste with save/restore


## 演示视频

<video src="https://github.com/user-attachments/assets/d5ad6da9-b924-4fd6-9812-d0d9868563a4" width="600" title="demo" controls>demo</video>


## 许可证

[MIT License](LICENSE)
