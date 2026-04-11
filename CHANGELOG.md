# Changelog

## v1.9.0 — Developer ID 签名 + 蓝牙支持 + 注入改进 (2026-04-11)

### 重要变更: Apple Developer ID 签名
本版本起使用 Apple Developer ID 签名并通过 Apple 公证 (Notarization)。安装不再提示"已损坏"或需要手动信任。

**升级用户请注意**: 由于签名身份变更，首次启动需要重新授予辅助功能和麦克风权限，以及确认钥匙串访问（输入 Mac 登录密码放行即可）。

### 新功能
- 蓝牙音频支持：提示音在 BT 音箱/耳机上完整播放，不再丢失前几百毫秒
- 音箱保活 & 麦克风保活开关，防止 BT 设备休眠断开
- 麦克风 & 提示音输出设备选择，可指定录音和播放设备
- 鼠标中键/侧键可用作录音快捷键
- 文本注入兼容性改进：支持 Electron (VS Code)、微信、飞书等更多应用
- 剪贴板行为改进：录音不再意外覆盖原有剪贴板内容
- 新增提示音风格：拨弦、沉浸、乒
- 双语 README (中文 + English)

### 改进
- ASR 停止流程优化：录完到出结果延迟显著降低
- 超短音频 (<0.3s) 自动跳过，减少噪声幻觉
- 浮窗进度条改为两阶段动画，体验更流畅
- 移除订阅/Cloud 代理功能，开源版更轻量

## v1.8.1 — ElevenLabs 修复 + 百炼国际版支持 (2026-04-07)

### Bug 修复
- 修复 ElevenLabs 录音结束后最长延迟 5 秒才注入文字的问题 (#105)
- 修复 ElevenLabs 流式识别累积模式下文字重复的问题 (#105)

### 新功能
- 百炼 ASR 新增 Base URL 配置项，支持国际版端点 (#106)

## v1.8.0 — 语音润色升级 + Qwen3 校准 + 断句优化 (2026-04-06)

### 语音润色
- Prompt 全面升级：支持自我修正识别（"不对，应该是..."自动处理）、口语数字转阿拉伯数字、多要点自动分点结构化、语境感知（正式/非正式内容区别处理）
- 语音润色升级为内置模式，模式详情页支持「还原为官方版」一键恢复
- 新增短文本跳过润色选项（10-50 字阈值可选），短句直接用 ASR 结果

### 语音识别
- SenseVoice 录音结束后自动调用 Qwen3 HTTP API 做二次校准，提升最终识别准确率
- 火山引擎断句参数优化：end_window_size 1.5s→3s，force_to_speech_time 关闭，减少思考停顿被截断
- Soniox 端点检测延迟 3s→10s，适应更长停顿
- ASR 标点始终开启，不再因有 LLM ���关闭
- CJK 字符间多余空格自动清除（ASR 分段拼接产生的空格）

### 交互改进
- 新增去句末标点选项（关闭/仅句号/全部标点）
- ESC 打断改进：`onESCAbort` 返回处理状态，无活跃录音时 ESC 穿透到系统
- ESC 打断始终启用，移除用户设置开关

### 音频反馈
- 开始音改用 cachedPlayer，新增静音预热（primeAudioOutput），首次提示音不再丢失开头
- 停止音按样式独立处理（chime/水滴1/水滴2/键盘/关闭）

### 设置 UI
- 本地模型区域重设计为双栏卡片：SenseVoice（始终运行）+ Qwen3-ASR（可控启停）
- 模式编辑表单样式统一，Prompt 编辑器自动高度
- 历史记录新增「纠错」按钮，快速打开纠错弹窗
- 切��� ASR 引擎时自动释放 SenseVoice 缓存模型

## v1.7.0 — 社区 PR 合并 + Keychain 迁移 + 注入性能优化 (2026-04-04)

### 社区贡献
- 历史记录显示 ASR 引擎名称 (#99, @jovezhong)
- Deepgram 数字转换开关 (#100, @jovezhong)
- ElevenLabs Scribe v2 流式识别引擎 (#101, @jovezhong)
- API Key 迁移到 macOS Keychain + 日志脱敏 (#102, @jasonwong2001)
- 空录音不保存历史 + 按钮点击区域优化 (#103, @ShaneLevs)

### 词汇管理
- 内置热词/片段脱钩，改为纯用户管理
- 热词和片段替换支持批量编辑（Sheet 弹窗，每行一条）
- 批量编辑按钮移到标题行，与排序按钮并排
- Soniox 二次校准死代码清理

### 性能优化
- 文本注入后立即通知 UI，剪贴板恢复延迟执行，减少粘贴→完成的感知延迟
- 快捷键停止和 ESC 中断改用 MainActor.assumeIsolated，减少调度延迟
- 防止旧 session 的 stale finalized 覆盖新录音

### 构建
- DMG 构建自动检测 variant/sherpa 状态变化，清理过期缓存
- 签名跳过优化：同 identity + 有效签名时不重签

## v1.6.2 — Soniox 重构 + 异步校准 + 并发安全 (2026-04-01)

- Soniox 客户端重构：去掉 ConnectionGate/Delegate，简化为直连 WebSocket
- Soniox 异步校准：录音结束后并行启动完整音频转录，自动替换更准确的结果
- Soniox 协议优化：start message 加 language_hints (zh/en)、max_endpoint_delay_ms
- Soniox 配置简化：移除 model 选择字段，默认使用最新模型
- SonioxAsyncClient：新增文件级异步转录（上传 → 轮询 → 获取结果）
- 火山引擎热词逻辑优化：有云端词表 (boosting_table_id) 时跳过 inline hotwords，避免冲突
- 并发安全修复：KeychainService 凭证缓存、SnippetStorage/HotwordStorage 文件缓存加锁
- SystemVolumeManager：CoreAudio 操作移到专用后台队列，避免蓝牙设备卡主线程
- SenseVoiceServerManager：currentQwen3Port 改用 OSAllocatedUnfairLock
- PromptContext.capture() 改为 async，AX 读取用 detached task + timeout 防死锁
- DebugFileLogger：ISO8601DateFormatter 复用，避免重复创建
- HotwordStorage：新增 builtinVersion 版本号 + loadCloudCompatible() 过滤方法

## v1.6.1 — 流式识别韧性 + 代理绕过 + 词库优化 (2026-03-31)

- 流式识别韧性大幅增强：按停止立即响应、不再重复粘贴、超时自动恢复
- 连接中途断开时自动用完整录音重新识别（batch fallback）
- 中断/失败的识别也保存到历史记录
- 新增「绕过系统代理」选项（关闭/仅 ASR/全部）
- Deepgram 热词受 URL 长度限制，自动截取前 30 个并在设置页提示
- 词库管理界面优化：替换映射按组显示、热词和替换映射支持排序
- ASR 设置：新 provider 自动填充默认值、凭证校验优化
- 自动更新修复：不再对已签名 DMG 重复签名（修复 Gatekeeper「已损坏」错误）
- AssemblyAI 多语言模型支持
- 6 个 ASR 客户端发送计数修正，避免误判连接状态

## v1.6.0 — 应用内更新 + Apple Speech + Bug 修复 (2026-03-30)

- 应用内更新：设置页 About 标签直接下载新版本并自动安装重启，Local 版更新时自动保留本地 ASR 模型
- 新增 Apple Speech 识别引擎：macOS 原生语音识别，无需 API Key，支持多语言
- 修复长录音（40-70s+）按快捷键停止时文字丢失：toggle 状态反转导致 onStart 触发 forceReset，现在安全重定向到 stop
- 火山引擎模型选项简化命名（"流式语音识别模型 2.0" → "模型 2.0（推荐，更便宜）"）
- ASR 服务启动时显示「启动中」状态提示
- 片段替换引擎优化，移除冗余映射词条和编译缓存
- CLAUDE.md 更新为 SenseVoice + Qwen3-ASR 双引擎架构描述

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
