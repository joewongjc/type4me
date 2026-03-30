# MacOS语音输入法

- **语音识别**：内置本地识别引擎、媲美云端引擎准确率；支持多家云端引擎厂商；支持流式识别、边说边出字，说完无需等待、快速输入；
- **文本处理**：内置润色、Prompt优化、翻译功能，可自定义添加任意处理模版（比如改人设、改语气、小语种翻译等等）；
- **模型接入**：支持主流厂商API接入；文本处理支持使用Ollama接本地模型；
- **词汇管理**：支持热词、映射词，2种模式。热词用于校正语音识别引擎，映射词可作为兜底或个性化场景使用（如 Web coding -> Vibe Coding, "我的邮箱地址" -> xxx@gmail.com）；
- **历史记录**：存储所有历史识别记录，包括原始文本和处理后文本，支持导出CSV；
- **配套Skill：精准提高识别准确率**，[点这里安装Skill](https://github.com/joewongjc/type4me-vocab-skill)后跟你的agent说"Qwen3.5 不要识别成 Queen 3.5"，他就能自动帮你管理热词和映射词，同类错误不再犯。

![Xnip2026-03-30_21-41-09](https://github.com/user-attachments/assets/3a830341-5a10-4123-89ee-d107c6ff39dd)


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

**Prompt 变量高级玩法**

Prompt 模板支持三种变量，让语音输入从"听写"升级为"语音命令"：

| 变量          | 含义                     |
| ------------- | ------------------------ |
| `{text}`      | 语音识别的文字           |
| `{selected}`  | 录音开始时光标选中的文字 |
| `{clipboard}` | 录音开始时剪切板的内容   |

**用法示例**：
<img width="1112" height="630" alt="3936267ac86804406b1066d51735f7e5" src="https://github.com/user-attachments/assets/4b431890-49aa-405c-b707-72ea093cfbc4" />


### 词汇管理

- **ASR 热词**：添加专有名词（如 `Claude`、`Kubernetes`），提升识别准确率
- **片段替换**：语音说「我的邮箱」，自动替换为实际邮箱地址



## 开始使用

### 方式一：直接下载DMG（推荐）

提供两个版本，功能完全相同，共享配置文件，可随时替换安装：  

> 作者使用方式：我自己是全用云端引擎。目前版本的本地模型也是可用状态，但太占内存。Mac Studio 36G内存依旧显得不够宽裕。火山引擎的速度和准确性都会更好一些。但本地你配置够高的话，速度也很快很快。

| 版本                                                         | 说明                                                         | 大小   |
| ------------------------------------------------------------ | ------------------------------------------------------------ | ------ |
| **[Type4Me-v1.5.1-local.dmg](https://github.com/joewongjc/type4me/releases/download/v1.5.1/Type4Me-v1.5.1-local.dmg)** | 内嵌 SenseVoice（实时流式识别展示） + Qwen3-ASR（完整语音校准），支持单选1个模型使用或一起用。开箱即用。 | ~1.2GB |
| **[Type4Me-v1.5.1-cloud.dmg](https://github.com/joewongjc/type4me/releases/download/v1.5.1/Type4Me-v1.5.1-cloud.dmg)** | 仅云端识别，需配置 API Key                                   | ~23MB  |

系统要求：macOS 14+ (Sonoma)

> **首次打开提示安全警告？** 这是 macOS 对所有非 App Store 应用的正常行为，不影响使用。
>
> **方法一：通过系统设置（推荐）**
>
> 1. 双击打开 Type4Me.app，弹出安全提示后点击「完成」
> 2. 打开「系统设置」→「隐私与安全性」，滚动到底部「安全性」部分
> 3. 找到 "已阻止打开 Type4Me" 的提示，点击「仍要打开」
> 4. 输入密码确认，再次点击「打开」
>
> 只需操作一次，之后可正常启动。
>
> **方法二：通过终端**
>
> ```bash
> xattr -d com.apple.quarantine /Applications/Type4Me.app
> ```


### 方式二：从源码构建

#### 前置条件

- macOS 14.0 (Sonoma) 或更高版本
- Xcode Command Line Tools（`xcode-select --install`）
- CMake（`brew install cmake`，编译 SherpaOnnx 本地识别引擎需要）
- Python 3.12（`brew install python@3.12`，本地 SenseVoice 服务需要）

#### 第一步：克隆项目

```bash
git clone https://github.com/joewongjc/type4me.git
cd type4me
```

#### 第二步：编译本地识别引擎（约 5 分钟，仅需一次）

```bash
bash scripts/build-sherpa.sh
```

> 跳过这一步也能用，只是没有本地识别功能，云端引擎正常可用。

#### 第三步：搭建 SenseVoice 服务

```bash
cd sensevoice-server
python3.12 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

首次运行会自动从 ModelScope 下载 SenseVoice 模型（~900MB）。

#### 第四步：构建并部署

```bash
cd ..
bash scripts/deploy.sh
```

脚本会自动完成：编译 → 打包为 `.app` → 签名 → 安装到 `/Applications/` → 启动。

#### 第五步：配置

- **本地识别**：设置里选择「本地识别 (SenseVoice)」即可使用
- **云端识别**：首次启动会弹出设置向导，填入火山引擎的 App Key、Access Key 和 Resource ID。详见[配置指引](https://my.feishu.cn/wiki/QdEnwBMfUi0mN4k3ucMcNYhUnXr)

#### 后续更新

```bash
cd type4me
git pull
bash scripts/deploy.sh
```

## 架构概览

```
Type4Me/
├── ASR/                    # ASR 引擎抽象层
│   ├── ASRProvider.swift          # Provider 枚举 + 协议
│   ├── ASRProviderRegistry.swift  # 注册表
│   ├── Providers/                 # 各厂商配置
│   ├── SenseVoiceWSClient.swift   # 本地 SenseVoice WebSocket 客户端
│   ├── VolcASRClient.swift        # 火山引擎流式 ASR
│   └── DeepgramASRClient.swift    # Deepgram 流式 ASR
├── Bridge/                 # SherpaOnnx C API Swift 桥接
├── Audio/                  # 音频采集
├── Session/                # 核心状态机：录音 → ASR → 注入
├── Services/               # 凭证存储、热词、模型管理、SenseVoice 服务管理
├── Input/                  # 全局快捷键管理
└── UI/                     # SwiftUI 界面
    ├── FloatingBar/               # 浮窗
    └── Settings/                  # 设置界面
sensevoice-server/          # Python SenseVoice 流式 ASR 服务
├── server.py                      # FastAPI WebSocket 服务
└── sensevoice_model.py            # 流式推理引擎
```

ASR Provider 架构设计为可插拔：每个云厂商实现 `ASRProviderConfig`（定义凭证字段）和 `SpeechRecognizer`（实现识别逻辑），注册到 `ASRProviderRegistry` 即可。

## 参与贡献：一起来做出最好用的开源语音输入法，超越闭源！

欢迎提交 PR/Issue，这个项目是我全部自己用 Claude Code 写的。

但对于 PR，即便有 bug/代码质量不好，我最常跟Claude说的一句话就是不要漏了人家的贡献。你大不了合完再改。

## 致谢

- [SenseVoice](https://github.com/FunAudioLLM/SenseVoice) - Alibaba FunAudioLLM
- [streaming-sensevoice](https://github.com/pengzhendong/streaming-sensevoice) - @pengzhendong
- [asr-decoder](https://github.com/pengzhendong/asr-decoder) - @pengzhendong
- [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) - k2-fsa

## For AI Agents

If you're an AI agent (Claude, Cursor, Copilot, etc.) tasked with building or deploying Type4Me, here's what you need to know:

**Read these files first:**

1. `CLAUDE.md` - architecture overview, credential storage, key files, and how to add new ASR providers
2. `Package.swift` - project dependencies and build targets
3. `scripts/deploy.sh` - the build & deploy pipeline

**Build & deploy steps:**

```bash
# 1. Clone
git clone https://github.com/joewongjc/type4me.git && cd type4me

# 2. Build local ASR engine (optional, ~5 min, needs cmake)
bash scripts/build-sherpa.sh

# 3. Setup SenseVoice server (optional, needs python3.12)
cd sensevoice-server && python3.12 -m venv .venv && source .venv/bin/activate && pip install -r requirements.txt && cd ..

# 4. Deploy as .app (builds, creates bundle, signs, and launches)
bash scripts/deploy.sh
```

**Key things to know:**

- This is a Swift Package Manager project, no `.xcodeproj` needed
- Local ASR uses a Python SenseVoice WebSocket service (`sensevoice-server/`), managed by `SenseVoiceServerManager`
- The ONNX int8 model is used for both streaming and full inference for best performance
- Credentials are stored locally at `~/Library/Application Support/Type4Me/credentials.json`, never in code or environment variables
- The ASR provider architecture is plugin-based: see `Type4Me/ASR/ASRProviderRegistry.swift`
- To add a new ASR provider, implement `ASRProviderConfig` + `SpeechRecognizer` protocol and register in `ASRProviderRegistry.all`

## 演示视频

<video src="https://github.com/user-attachments/assets/d5ad6da9-b924-4fd6-9812-d0d9868563a4" width="600" title="demo" controls>demo</video>




## 许可证

[MIT License](LICENSE)
