# Changelog

## Unreleased

### ✨ 新功能

- 新增 Apple ASR Provider，可在设置页中作为正式识别引擎直接选择
- Apple ASR 走统一 `ASRProviderRegistry -> RecognitionSession` 链路，兼容 direct mode、自定义模式、LLM 后处理、历史记录与文本注入
- 无需 API Key，首次使用时会请求系统语音识别权限

### 🔧 改进

- `SpeechRecognizer` 协议新增 PCM buffer 输入通道，支持原生 `SFSpeechRecognizer`
- `KeychainService.loadASRConfig` 支持从 provider 默认字段构造配置，减少 Apple ASR 这类低配置 provider 的初始化样板
- Apple ASR 在设置页支持直接选择识别语言，并保留统一的连接测试入口

## v1.5.1 — Bug 修复 + 稳定性改进 (2026-03-30)

- 修复片段替换链式叠加 bug：正则缺少 word boundary，导致前一条替换的产物被后续规则二次匹配（如 "Cloud Code" → "Claudee Code"）
- 快捷键 event tap 健康检查：每 10 秒检测 tap 是否存活，静默失效时自动重建
- 辅助功能权限重试改进：5 次重试失败后弹窗提示重启 App，附带一键重启
- 新增 `type4me://reload-vocabulary` URL scheme，支持外部工具（如 Claude Code skill）触发热词/片段词表刷新
- 签名优化：首次构建自动创建持久化自签名证书 "Type4Me Local"，避免 ad-hoc 签名每次重编译后辅助功能权限失效
- 构建时自动移除 quarantine flag，防止 Accessibility 权限静默失效
- 设置向导增加辅助功能权限提示文案

## v1.5.0 — Dual-ASR + 三版本发布 (2026-03-30)

### 🎯 Dual-ASR 架构

全新双模型并行识别架构，大幅提升转写准确率：

- **SenseVoice** 负责流式实时识别，说话时即时出字
- **Qwen3-ASR** 负责精准校验，停顿时增量投机转录，松手后全量 final 校正
- 设置页新增两个模型独立启停按钮 + 状态显示
- 支持 Qwen3-only 模式（悬浮窗显示"录音中"）

### 📦 两种 DMG 版本

| 版本 | 包含内容 |
|------|---------|
| Cloud | 纯云端识别，最小体积 (~23MB) |
| Local | SenseVoice + Qwen3-ASR 双模型本地识别，开箱即用 (~1.2GB) |

### 🗂 存储架构升级

- 热词从 UserDefaults 迁移到双 JSON 文件 (builtin-hotwords.json + hotwords.json)
- 片段替换同步迁移 (builtin-snippets.json + snippets.json)
- 139 个内置默认热词
- 词汇表 UI 全新设计：内置词数统计、Finder 一键打开编辑、刷新按钮

### 🔧 LLM 管理

- 设置页新增 LLM 启停按钮
- `/llm/unload` 端点释放内存，`/llm/load` 重新加载
- LLM 与 ASR 共享 GPU 推理锁，避免并发 Metal 冲突

### 🐛 Bug 修复

- 进程泄漏：PID 文件管理替代 pgrep 误杀
- App 退出：同步 killAllServerProcesses 替代 fire-and-forget Task
- PyTorch detach()：3 处 `.numpy()` 前补 `.detach()`
- PyInstaller email-validator 依赖补全
- 配置持久化：`UserDefaults.bool` → `object(forKey:) as? Bool ?? true`
- onChange 初始化误触发防护
- SenseVoice 端口检测：`isRunning` → `currentPort != nil`

---

## v1.3.7 — 保留剪贴板 + Dock 图标 (2026-03-29)

### ✨ 新功能

- 新增「保留剪贴板」设置（偏好设置 → 通用 → 第二行）(#57)
  - 开启：使用键盘模拟输入，完全不碰剪贴板
  - 关闭（默认）：注入成功后自动恢复原始剪贴板，失败时保留识别文本作为 fallback
- 启动时显示 Dock 图标，关闭所有窗口后自动隐藏到菜单栏

### 🔧 改进

- 注入成功检测：非编辑角色从 4 个扩展到 27 个，减少误判
- 区分"无聚焦元素"（桌面）和"Electron nil role"（编辑区），避免桌面语音输入时文本丢失
- 剪贴板深拷贝支持所有类型（图片、文件、富文本），不只是纯文本

### 🐛 Bug 修复

- 修复剪贴板恢复时 changeCount 校验使用写入前的值导致恢复静默失败

---

## v1.3.5 — 修复菜单栏图标不显示 (2026-03-28)

### 🐛 Bug 修复

- 修复 macOS 26 Tahoe 安装后菜单栏图标不显示的问题（#54）
  - 根因：「Allow in Menu Bar」提示框每个版本只弹一次，卸载重装后 UserDefaults 仍保留导致提示不再出现
  - 改为每次启动都检测，只要图标不可见就提示用户去系统设置开启
- 修复多显示器环境下菜单栏图标可见性检测误判的问题
  - 原来只对主屏幕坐标范围做检测，多屏下可能漏报
  - 改为遍历所有已连接屏幕进行坐标判断

---

## v1.2.0 — Prompt 上下文变量 (2026-03-24)

### 🎯 Prompt 模板变量扩展

Prompt 模板新增 `{selected}` 和 `{clipboard}` 两个变量，让语音输入不再只是"听写"，而是可以**用语音对选中的文字下达命令**。

- **`{text}`**：语音识别的文字（原有）
- **`{selected}`**：录音开始时光标选中的文字（新增）
- **`{clipboard}`**：录音开始时剪切板的内容（新增）

#### 使用场景

语音识别的内容变成 LLM 的**命令**，选中的文字和剪切板变成**上下文**：

- 选中一段英文，按住快捷键说"翻译选中的文字"→ LLM 收到选中内容 + 翻译指令
- 复制一段代码到剪切板，说"解释一下剪切板里的代码"→ LLM 收到代码 + 解释指令
- 选中一段文字，说"把这段话改成正式的书面语"→ LLM 直接改写选中内容

### 📋 新增"命令模式"

内置新增"命令模式"处理模式，将语音输入作为 LLM 命令，结合 `{selected}` 和 `{clipboard}` 上下文执行：

```
命令如下：{text}
选择的内容：{selected}
剪切板的内容：{clipboard}
```

### 🛡 Accessibility 调用超时保护

读取选中文字通过 macOS Accessibility API 实现，部分应用（如 Electron 应用）的 AX 响应可能卡顿。已增加 200ms 超时保护，避免系统 UI 冻结。

---

## v1.1.0 — 本地语音识别 (2026-03-24)

### 🎯 本地 ASR（Paraformer / Zipformer）

无需申请云端 API Key，开箱即用。基于 SherpaOnnx 引擎，所有推理完全在设备端完成，无网络依赖。在 Apple Silicon (M1/M2/M3/M4) 大内存机型上表现尤佳。

- **三种模型可选**：
  - 极速轻量（~20 MB）：最小模型，适合快速输入，精度一般
  - 均衡推荐（~236 MB）：14000 小时训练数据，精度与体积的最佳平衡
  - 中英双语（~1 GB）：精度最高，支持中英文混合识别
- **流式 + 离线双通道**：流式识别实时出字，录音结束后离线模型二次修正
- **自动标点**：CT-Transformer 标点模型自动补全标点符号
- **模型管理 UI**：下载进度条、模型切换、测试、删除，一站管理
- **断点续传**：大文件下载中断后自动恢复，最多 20 次重试
- **首字优化**：录音开头跳过 400ms 静音/提示音区间，避免首字丢失或误识别

### 🔔 提示音自定义

录音开始提示音从开关升级为多选项：
- 电子提示音（原有）
- Water Drop 1（新增）
- Water Drop 2（新增）
- 关闭

### 🛠 其他改进

- 模型删除增加二次确认，防止误操作
- 未下载模型不再显示选择圆圈，下载按钮左置，UI 更直观
- 测试按钮移至识别引擎标题行右侧，远离删除区域
- ASR Provider 枚举新增 `.sherpa`，本地识别作为一等公民集成进 Provider 体系
