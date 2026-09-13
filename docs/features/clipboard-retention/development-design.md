# Type4Me 剪贴板保留策略开发设计

> 分支：`feat/menubar-control-center`
> 文档类型：开发设计
> 文档状态：已实现（待 DEV App 手动验收）
> 设计日期：2026-08-23
> 对应产品设计：`docs/features/clipboard-retention/product-design.md`

## 数据与迁移

`ClipboardOutputPolicy` 使用 `tf_clipboardOutputPolicy` 持久化四个 raw value：`alwaysCopy`、`cancelProcessed`、`cancelRawTranscript` 和 `neverCopy`。

首次读取时兼容迁移旧的反向布尔 key `tf_preserveClipboard`：旧值 `false` 映射为 `alwaysCopy`，旧值 `true` 或缺失映射为 `cancelProcessed`。迁移在应用启动时执行，也在独立读取策略时防御性执行。

## 会话与注入

`RecognitionSession` 在 `startRecording` 冻结当前策略，并以 `CompletionIntent.normal` 或 `.cancelled` 表示本轮收尾。取消后的原始识别和从不复制策略会跳过 LLM 后处理；若正在飞行的停止后请求返回，其结果会被忽略，最终输出恢复为最终 ASR 文本。

这两种无需 LLM 的取消路径会通知 `AppState` 隐藏浮层，而不是切换到 `.processing`。最终 ASR 结果仍可写入历史与剪贴板；若需要显示结果，`.finalized` 从这个受控隐藏状态恢复为短暂的完成提示。新一轮录音会清除该受控状态，避免旧会话事件覆盖新录音。

`TextInjectionEngine` 的 `ClipboardRetention` 与输入成功状态独立：

- `retainResult` 保留输入结果；
- `restoreOriginal` 为任何输入结果（包括没有可输入目标）保留快照并恢复原剪贴板。

`InjectionOutcome.notInserted` 用于“没有可输入目标且结果没有保留”的情形，避免把未保留的结果错误描述为“已复制到剪贴板”。

取消结果不会向目标应用发送 Cmd+V；只有策略允许时才直接写入剪贴板。正常完成与恢复识别根据冻结策略选择保留或恢复。

## UI 与验证

设置页和菜单栏输出格式菜单使用同一组 `ClipboardOutputPolicy` 单选项。测试覆盖策略矩阵、旧 key 迁移和无输入目标的反馈文案；会话路径通过现有识别、历史与输出格式测试共同保护。交付时运行相关 XCTest 和 release build，并由用户手动验证四种策略。
