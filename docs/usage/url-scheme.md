# URL Scheme / 外部自动化

> 文档类型：用户指南 · 状态：当前有效 · 最后校验：2026-10-06 · 对应版本：v2.10.0

[English](url-scheme.en.md) · [返回 README](../../README.md)

Type4Me 提供 URL Scheme，可以从浏览器、终端、macOS 快捷指令、Raycast、Alfred、脚本或 AI Agent 调用常用功能。

## Scheme 名称

不同构建默认注册不同的 Scheme；**单个安装包只接受自己实际注册的 Scheme**：

| 构建 | 默认 Scheme | 示例 |
| --- | --- | --- |
| 正式版 / Public | `type4me://` | `type4me://settings` |
| Dev 开发版 | `type4me-dev://` | `type4me-dev://settings` |
| Personal / CtriXin | `type4me-ctrixin://` | `type4me-ctrixin://settings` |

下面示例统一使用正式版 `type4me://`。开发版或个人版只需要替换 Scheme 前缀。

## 录音控制（Recording Commands）

为 Stream Deck、Raycast、Alfred、BetterTouchTool、Hammerspoon、macOS 快捷指令等自动化工具提供免模拟键盘事件的直接控制接口：

### 开始录音
```text
type4me://start
```
- 使用 Type4Me 当前选中的模式（`AppState.currentMode`）开始录音；
- 幂等命令：若已经在准备中或录音中，不会重复触发或中断当前录音；
- 在处理中（processing）或恢复中（recovering）安全忽略，不会并发开启第二轮录音。

### 结束录音
```text
type4me://stop
```
- 结束当前录音并正常进入后续语音识别、LLM 处理与文本注入流程；
- 仅在准备中（preparing）或录音中（recording）生效；空闲或处理中安全忽略；
- 不等价于取消（cancel），会完整保留已录音内容。

### 录音开关（Toggle）
```text
type4me://toggle
```
- 空闲时开始录音，录音中结束录音；适合 Stream Deck 单键绑定；
- 在处理中或恢复中安全忽略。

> **最佳实践（推荐使用 `-g` 后台调用）**：
> - 在终端、脚本或第三方工具（Stream Deck、Raycast、Alfred、BetterTouchTool、Hammerspoon、快捷指令等）中触发时，推荐使用 **`open -g 'type4me://toggle'`**（`-g` / `--background` 选项）；
> - `-g` 会让系统直接在后台传递事件，**完全不激活 Type4Me 也不会抢占前台焦点**，彻底消除前台界面切换与光标抖动，实现 100% 丝滑无感的录音与文本注入体验。
>
> 说明：
> - 录音控制命令默认使用 Type4Me 当前选中的模式，第一版不接受 `?mode=` 等 query 参数（带有未知参数将被拒绝）；
> - 通过 URL 启动的录音是标准的 Type4Me 录音会话，可以随时通过浮动条、菜单栏或键盘快捷键正常结束或取消。

## 打开设置

```text
type4me://settings
```

`preferences` 是等价别名：

```text
type4me://preferences
```

## 热词（Hotwords）

打开热词管理：

```text
type4me://vocabulary/hotwords
```

预填一个热词并打开设置：

```text
type4me://vocabulary/hotwords?word=Ghostty
```

中文或特殊字符需要进行 URL 编码，例如：

```text
type4me://vocabulary/hotwords?word=%E9%98%B6%E8%B7%83%E6%98%9F%E8%BE%B0
```

静默添加热词，不打开 Settings：

```text
type4me://vocabulary/hotwords?word=Ghostty&silent=true
```

`silent=1` 同样有效。静默模式下 `word` 为必填参数；已存在的热词会按大小写不敏感方式去重。

## 片段替换（Snippets）

打开片段替换：

```text
type4me://vocabulary/snippets
```

只预填 trigger：

```text
type4me://vocabulary/snippets?trigger=ghosty
```

同时预填 trigger 和 replacement：

```text
type4me://vocabulary/snippets?trigger=ghosty&replacement=Ghostty
```

静默添加片段替换：

```text
type4me://vocabulary/snippets?trigger=ghosty&replacement=Ghostty&silent=true
```

静默模式下 `trigger` 和 `replacement` 都是必填参数。若同名 trigger 已存在且 replacement 相同，则视为已存在；若 replacement 不同，则不会静默覆盖原规则。

## 重新加载词表

```text
type4me://reload-vocabulary
```

该命令会刷新 Hotwords / Snippets 缓存、发送词汇变更通知，并触发本地热词同步与相关服务刷新。

## 已废弃：`auth`

```text
type4me://auth
```

这个入口仅为历史兼容保留。认证流程已经改为 code-based auth，因此当前 `auth` 是 **no-op**，新集成不应再使用。

## 参数限制

Vocabulary URL 会执行严格校验：

- URL 最大 **8 KB**；
- `word` 最大 **256 字符**；
- `trigger` 最大 **256 字符**；
- `replacement` 最大 **4096 字符**；
- 不接受空值或控制字符；
- 不接受未知 query 参数；
- 同名 query 参数不能重复；
- `silent` 只接受 `true` / `1` / `false` / `0`；
- Vocabulary 路径只支持 `/hotwords` 与 `/snippets`。

## Terminal 示例

```bash
open 'type4me://settings'
open 'type4me://vocabulary/hotwords?word=Ghostty'
open 'type4me://vocabulary/snippets?trigger=ghosty&replacement=Ghostty&silent=true'
```

> 对带有空格、中文、`&`、`?` 等特殊字符的参数，请先进行 URL 编码。
