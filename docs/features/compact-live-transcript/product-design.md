# Type4Me Compact 实时识别文本产品设计

> 文档类型：产品设计
> 文档状态：当前有效（已实现，持续验证）
> 设计日期：2026-08-27
> 最后校验：2026-08-30
> 实现基线：`a90f8d2`
> 关联开发设计：[development-design.md](development-design.md)
> 说明：本文档是独立功能设计，不修改或替代 `docs/features/compact-recording-indicator/` 下的既有文档。

## 1. 背景

Type4Me 已经提供 Regular / Compact 两套录音指示器外观。

当前 Compact 的核心优势是占用空间小：录音阶段固定为 180 × 24 pt，底部一行包含 Finish、动态 Audio Indicator 和 Cancel；录音结束后的 Processing / Recovering / Done / Error 继续使用 24pt 高的 Compact 状态提示。

当前 Compact 不展示实时识别文本，因此用户只能从声纹确认“正在录音”，无法在录音过程中快速确认 ASR 是否识别正确。

本功能在不放弃 Compact 固定宽度和低占屏特性的前提下，为 Compact 增加可选的内嵌实时识别文本。

## 2. 产品目标

1. Compact 支持现有 `Live Transcript / 实时展示文本` 设置；
2. Live Transcript 开启时，Compact 的 Preparing / Recording 录音态从 180 × 24 pt 扩展为 180 × 48 pt；
3. 48pt 高度拆成上下两个 24pt 区域：上方实时文本，下方保持现有录音控制和声纹；
4. 实时文本使用 12pt 单行文本，从左侧开始自然向右增长；
5. 文本尚未填满可用宽度时保持左对齐，不发生滚动；
6. 文本达到右边界后进入 follow-tail 行为：旧内容向左移动，最新识别内容持续保持可见；
7. Compact 的宽度始终保持 180pt，不因为实时文本长度增长；
8. Live Transcript 关闭时，Compact 继续保持现有 180 × 24 pt 录音态；
9. Finish 后 Processing / Recovering / Done / Error 不继承 48pt 高度，继续使用现有 24pt Compact 状态提示；
10. 不引入新的 ASR 数据源、录音状态或独立 transcript preference。

## 3. 非目标

本功能不包含：

- 把 Compact 录音态宽度改成随文字变化；
- 多行实时文本；
- 垂直滚动 transcript；
- 跑马灯式循环滚动；
- Compact Transcript Popup；
- 通过 hover 展开完整实时文字；
- 改变现有 Compact Audio Indicator 的声纹规格；
- 改变 Finish / Cancel 的交互语义；
- 改变 Processing / Recovering / Done / Error 的宽度自适应策略；
- 新增 Compact 专属的 Live Transcript UserDefaults key。

## 4. 设置语义

### 4.1 复用现有 Live Transcript

继续复用：

```text
tf_showLiveTranscript
```

不新增 `tf_compactLiveTranscript`。

`Live Transcript` 从“Regular-only 能力”调整为“Regular 与 Compact 共用能力”。

### 4.2 Compact + Live Transcript On

录音阶段显示：

```text
180 × 48 pt
```

上层为实时文字，下层为原有 Compact controls / waveform。

### 4.3 Compact + Live Transcript Off

录音阶段继续显示：

```text
180 × 24 pt
```

与当前 Compact 行为完全一致。

### 4.4 Settings 页面

当 Indicator Style = Compact 时：

- `Live Transcript` 保持显示并可操作；
- `Recording Visual` 仍然属于 Regular-only，不在 Compact 中显示；
- `Hover Text Preview` 仍然属于 Regular-only，不在 Compact 中显示；
- `Show Tooltips` 与 `Show Cancel Button` 行为不变。

因此 Compact 设置项建议呈现为：

```text
Indicator Style     Compact
Live Transcript     On / Off
Show Tooltips       On / Off
Show Cancel Button  On / Off
```

Regular 继续保留现有完整设置组合。

## 5. 录音态总体布局

### 5.1 Live Transcript 开启

```text
┌────────────────────────────────────┐
│ 你好，这是一段录音，它将被 Type… │  ← 24pt transcript lane
│ [■]   ▁▃▆▂▅▇▃▂▅▃▆▂▅          [×] │  ← 24pt control lane
└────────────────────────────────────┘
                 180 × 48 pt
```

上下两层属于同一个 Compact capsule，不增加内部边框或分隔线。

### 5.2 Live Transcript 关闭

```text
┌────────────────────────────────────┐
│ [■]   ▁▃▆▂▅▇▃▂▅▃▆▂▅          [×] │
└────────────────────────────────────┘
                 180 × 24 pt
```

### 5.3 尺寸原则

- width：固定 180pt；
- transcript lane：24pt；
- control lane：24pt；
- expanded height：48pt；
- collapsed height：24pt；
- 外轮廓继续使用当前 Compact 的深色 capsule 视觉语言；
- 48pt 只适用于 Preparing / Recording 且 Live Transcript 开启的情况。

> 本文使用 macOS 逻辑坐标 `pt`。Retina 屏幕的物理像素由系统缩放处理。

## 6. 实时文本视觉规格

### 6.1 字体

```text
font size: 12pt
weight: medium
line count: 1
```

颜色使用现有 Floating Bar 文本 Design Token，不在组件内写死 `.white`。

### 6.2 文本区域

建议：

```text
horizontal inset: 8pt
viewport width: 180 - 8 - 8 = 164pt
lane height: 24pt
```

文本在 24pt lane 内垂直居中。

### 6.3 空内容

Preparing 阶段和第一段 ASR partial 到达之前：

- transcript lane 保持空白；
- 不显示 `倾听中 / Listening` placeholder；
- 下方声纹已经承担录音状态反馈，因此不额外重复状态文字。

这样第一段识别文本出现时可以直接从左侧自然长出。

## 7. Follow-tail 文本行为

这是本功能的核心交互。

### 7.1 未溢出

当当前文本实际宽度小于等于 transcript viewport：

```text
你好，这是
↑
左侧起始位置固定
```

行为：

- 左对齐；
- 不滚动；
- 不居中；
- 不因为每个 partial update 横向抖动。

### 7.2 到达右边界

文本不断向右增长，直到触达可用区域右侧。

在触达右边界之前，不移动已有内容。

### 7.3 溢出后

一旦文本宽度超过 viewport：

- 整段文字向左移动；
- 最新识别的文本尾部保持在右侧可视范围；
- 新内容继续到达时，视口跟随 transcript 尾部；
- 用户始终能看到最新识别结果。

示意：

```text
初始：
| 你好，这是一段录音               |

接近边界：
| 你好，这是一段录音，它将被 Type4 |

溢出后：
| 一段录音，它将被 Type4Me 转换为文字 |
```

### 7.4 不是 Marquee

禁止实现成循环跑马灯：

```text
末尾 → 消失 → 从右侧重新进入
```

文本只跟随当前 transcript 尾部，不循环播放历史内容。

### 7.5 左侧溢出提示

当 transcript 已经发生左侧溢出时，可在左边缘使用约 10pt 的轻量 fade mask。

目的：

- 表达左侧仍有更早内容；
- 避免文字在 capsule 边缘生硬裁切。

右侧不增加 fade，因为右侧代表当前最新识别内容。

## 8. ASR Partial 与修正行为

实时 ASR 不一定只做 append，也可能修正上一段 partial。

Compact transcript 始终渲染当前 `state.transcriptionText`，不自己缓存“用户已经看过的旧文本”。

### Append

当新文本是在现有文本尾部追加时：

- 未溢出：继续向右增长；
- 已溢出：平滑跟随新的尾部位置。

### Correction / Rewrite

当 ASR 回改已有 partial 时：

- 立即以最新 `state.transcriptionText` 为准；
- 不保留已被 ASR 替换的旧字符；
- 如果修正后文本变短但仍溢出，继续显示最新尾部；
- 如果修正后文本重新短于 viewport，恢复左对齐。

不使用类似 Regular `recordingPeakWidth` 的 high-water mark，因为 Compact 宽度始终固定。

## 9. Phase 行为

### Preparing

Live Transcript On：

```text
180 × 48
上层空白 transcript lane
下层 controls + idle waveform
```

Live Transcript Off：

```text
180 × 24
controls + idle waveform
```

### Recording

Live Transcript On：

```text
180 × 48
上层实时识别文字
下层 controls + dynamic waveform
```

Live Transcript Off：维持 180 × 24。

### Processing / Recovering / Done / Error

无论 Live Transcript On / Off：

- 不显示 transcript lane；
- 高度恢复为 24pt；
- 宽度继续沿用当前 Compact status intrinsic-width 策略；
- 不回退 Regular renderer。

因此典型 transition 为：

```text
Recording  180 × 48
    ↓ Finish
Processing intrinsic(content) × 24
    ↓
Done       intrinsic(content) × 24
```

## 10. Tooltips 与按钮

现有 Compact 模式提示和按钮悬停提示继续保留。

Live Transcript 开启后：

- mode hint 仍位于整个 48pt capsule 上方；
- Finish / Cancel tooltip 仍然水平对齐底部两个 control 的中心；
- tooltip 的 vertical positioning 以新的 capsule height 计算；
- transcript lane 本身不响应 hover，不触发 Transcript Popup。

## 11. Show Cancel Button

当 `Show Cancel Button = Off`：

- Compact width 仍然固定 180pt；
- Live Transcript On 时仍为 180 × 48；
- 上层 transcript viewport 不因为 Cancel 隐藏而改变宽度；
- 下层继续使用当前单按钮 Compact 布局策略；
- Esc 取消能力保持不变。

## 12. 无实时 Partial 的 ASR 场景

如果当前 ASR pipeline 在录音阶段不产生 realtime partial：

- Live Transcript 设置仍保持启用状态；
- 不伪造识别文本；
- transcript lane 在录音期间可以保持空白；
- 不使用 placeholder 代替 ASR 内容。

第一版不因为 provider 能力动态隐藏 transcript lane，避免同一设置产生不可预测的高度变化。

后续如需要，可单独设计 provider-capability-aware fallback。

## 13. Appearance Preview

Settings Preview 必须真实展示 Compact Live Transcript。

### Compact + Live Transcript On

Recording Preview：

- 180 × 48；
- 上方使用现有长 sample transcript；
- sample 足够长，能够直观看到 follow-tail 溢出状态；
- 下方 synthetic audio 持续驱动 waveform。

### Compact + Live Transcript Off

Recording Preview：180 × 24，不显示文本行。

### Processing Preview

继续显示现有 24pt Compact processing status，不保留 transcript lane。

## 14. 可访问性

实时文字 lane：

- accessibility label 暴露完整的当前 transcript；
- 视觉裁切或滚动不能影响辅助功能读取完整内容；
- transcript lane 不声明 button / text field 等可交互 trait；
- Finish / Cancel 继续保持现有 accessibility action。

## 15. 兼容性

### UserDefaults

不增加新的持久化 key。

继续使用：

```text
tf_recordingIndicatorStyle
tf_showLiveTranscript
tf_showTooltips
tf_showCancelButton
```

### 用户行为变化

此前 Compact 会忽略 `tf_showLiveTranscript`。

本功能上线后，如果用户：

```text
Indicator Style = Compact
Live Transcript = On
```

录音态将变为 180 × 48。

这是有意的语义修正：既有 Live Transcript preference 开始同时控制 Regular 与 Compact。

如果用户希望保持原来的最小 Compact，可关闭 Live Transcript，恢复 180 × 24。

## 16. 验收场景

### 16.1 Compact + Live Transcript Off

- Preparing / Recording 始终 180 × 24；
- 行为与当前 Compact 一致；
- 无 transcript lane。

### 16.2 Compact + Live Transcript On

- Preparing / Recording 始终 180 × 48；
- 下方 controls / waveform 几何不变；
- 上方显示 12pt transcript；
- 没有识别文字时上层为空白。

### 16.3 短文本

例如：

```text
你好，这是测试
```

- 从左边开始显示；
- 不居中；
- 不发生水平滚动。

### 16.4 长文本

当文字到达右边界：

- 开始向左移动；
- 最新文字保持在右侧可见；
- 左侧可出现轻微 fade；
- 整个 capsule width 始终 180pt。

### 16.5 ASR 修正

- partial 被修正时界面立即反映最新文本；
- 被替换的旧文本不继续残留；
- 文本缩短到 viewport 内时恢复左对齐。

### 16.6 Phase Transition

Finish 后：

- 48pt transcript lane 消失；
- Processing 高度变回 24pt；
- Processing / Done / Error 继续使用 Compact；
- 不出现 Regular 55pt UI。

### 16.7 Settings / Preview

- Compact 下可以直接开关 Live Transcript；
- Recording Visual / Hover Text Preview 仍只属于 Regular；
- Preview 与真实 Floating Bar 行为一致；
- 开关 Live Transcript 后 Preview 高度立即从 24 ↔ 48 更新。

## 17. 产品决策汇总

| 项目 | 决策 |
|---|---|
| 功能 | Compact 内嵌 Live Transcript |
| Preference | 复用现有 `tf_showLiveTranscript` |
| Compact Live On | Preparing / Recording = 180 × 48 |
| Compact Live Off | Preparing / Recording = 180 × 24 |
| Transcript lane | 24pt 高 |
| Controls lane | 24pt 高，保持现状 |
| Transcript font | 12pt Medium |
| Width | 固定 180pt，不随 transcript 变化 |
| 初始文本 | leading aligned |
| 未溢出 | 不滚动 |
| 溢出后 | follow-tail，最新内容保持可见 |
| 左侧 overflow | 可使用约 10pt fade mask |
| 右侧 overflow | 不使用 fade |
| Empty state | 空白，不显示 Listening placeholder |
| Transcript Popup | Compact 不支持 |
| Tooltips | 保持现有 Compact 行为 |
| Processing / Result | 继续 24pt Compact status |
| New storage key | 无 |
| Existing Compact docs | 不修改，本文独立维护 |
