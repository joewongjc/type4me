# Type4Me 历史与用量看板（History & Usage Analytics）产品设计

> 文档类型：产品设计  
> 文档状态：当前有效（已实现，持续验证）
> 适用平台：Type4Me macOS (Apple Silicon & Intel)  
> 文档范围：历史记录页面重组、ASR 语音引擎用量看板、LLM 全局大模型用量与成本看板、交互规范与动效物理规则  
> 设计日期：2026-09-14  
> 最后校验：2026-09-24
> 实现基线：`927f84b`（PR #318）
> 下游文档：`docs/features/usage-analytics/development-design.md`  

---

## 1. 执行摘要与产品背景

### 1.1 现状与痛点
Type4Me 作为“语音输入 + LLM 智能处理”双引擎驱动的桌面生产力工具，用户在实际使用中面临着严重的**用量黑盒与成本盲区**：
1. **大模型调用感知极其微弱**：用户配置了自己的 API Key（DeepSeek、Claude、OpenAI 等），但在历史记录中只能勉强看到转写后的文本，完全不知道每次输入消耗了多少 Token、响应延迟如何、调用是否成功，遇到超时或报错只能盲猜。
2. **ASR 用量统计与历史流水耦合且受限**：原先的 ASR 引擎用量明细藏在“累计时长”指标点击后的折叠浮层中，不仅在列表滚动与数据刷新时容易造成布局抖动，且受限于狭小卡片空间，无法展示更丰富的多维分析与趋势。
3. **缺少全局维度的宏观成本核算**：用户不仅在听写润色（Intelli Sense）时调用 LLM，在局部语音改写（Voice Revise）、随手问答（Ask Anything）、智能词库建议（Smart Correction）、Mac Action 意图识别等场景也在持续消耗 Token。用户极度渴望一个一目了然的“账单与用量体检报告”。

### 1.2 核心方案决策
- **保留「历史 (History)」作为侧边栏单一顶级入口**：不增加额外的侧边栏项目，避免“历史”与“统计”双一级入口产生的语义重叠与冗余感。
- **引入顶部单层三段切换（Single-tier Segmented Control）**：
  - `[ 听写记录 (Transcripts) ]`：纯粹的文字流水、搜索、编辑、复制、批量导出与管理。
  - `[ 语音引擎用量 (Speech Engines) ]`：原 ASR 引擎明细升级为独立看板（录音时长、识别字数、语速、引擎分布、差评率）。
  - `[ 大模型用量 (LLM Analytics) ]`：全新构建的全局 AI 消耗与成本看板（Tokens、预估费用、延迟、模型明细、业务场景分布）。
- **秉承 Apple Design 哲学**：
  - 零层级嵌套，动效遵循连续物理弹簧（Critically Damped Spring, damping 1.0, response 0.35s）；
  - 触控即时响应，无任何人为锁死或延迟；
  - 采用系统原生毛玻璃与层次化视觉材质，兼顾全分辨率与动态字体排印（Dynamic Type & Monospaced Digits）。

---

## 2. 页面结构与导航设计

### 2.1 顶级视图框架

进入侧边栏的「历史」页面后，顶部常驻一个 macOS 原生风格的胶囊分段选择器（Segmented Picker）：

```
┌────────────────────────────────────────────────────────────────────────────────────────┐
│  历史 (History)                                                                        │
│                                                                                        │
│          [ 听写记录 (Transcripts) ]   [ 语音引擎 (ASR) ]   [ 大模型用量 (LLM) ]          │
├────────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                        │
│  [选中的子视图内容：TranscriptsView / ASRAnalyticsView / LLMAnalyticsView]              │
│                                                                                        │
└────────────────────────────────────────────────────────────────────────────────────────┘
```

### 2.2 三大分段视图的定位与职责划分

| 分段名称 (中/英) | 核心定位 | 核心交互与承载内容 |
|---|---|---|
| **听写记录**<br>`Transcripts` | **微观流水与文字管理** | • 现有搜索栏、日期范围筛选、批量选择与删除<br>• 顶部保留三个精简指标卡（总时长、总字数、平均语速），**取消原先点击展开折叠抽屉的复杂交互**<br>• 纯粹的时间轴流水列表、单条展开看详情与回放 |
| **语音引擎**<br>`Speech Engines` | **ASR 耗时与质量分析** | • 统一时间范围筛选器：`[ 今天 \| 近 7 天 \| 近 30 天 \| 全部 ]`<br>• ASR 核心 KPI 卡片：总录音时长、总字数、平均识别语速、整体差评率<br>• 引擎/模型明细表：各 ASR 引擎（SenseVoice、ElevenLabs、Volcano、Deepgram 等）在 1天/7天/30天/全量的时长与差评率分布 |
| **大模型用量**<br>`LLM Analytics` | **宏观 Token 与成本对账** | • 统一时间范围筛选器：`[ 今天 \| 近 7 天 \| 近 30 天 \| 全部 ]` 及 `[ 导出报表 ▾ ]`<br>• 核心 KPI 指标卡：总消耗 Token (Prompt/Completion)、预估总费用 (USD / CNY)、请求次数与平均耗时<br>• 每日 Token 消耗趋势柱状图<br>• 模型明细表格：按 Provider/Model 列出调用次数、Token 构成、平均耗时、预估费用<br>• 全场景功能分布占比（Intelli Sense、Voice Revise、Ask Anything、其他） |

---

## 3. 大模型用量 (LLM Analytics) 详尽功能规格

### 3.1 核心 KPI 指标卡（Summary Cards）
位于面板最上方，并排展示 3 张卡片（在大屏下 3 列，小屏自动换行）：

1. **总消耗 Tokens (Total Tokens)**
   - 主数字：格式化大数（例如 `142.8 K`，大于 1M 显示 `1.25 M`，采用 `monospacedDigit`）。
   - 副文本：清晰拆分为 `输入: 108.2 K` 与 `输出: 34.6 K`。
   - 辅助标签：若包含估算数据，打上轻量角标或说明 `包含部分无回传预估`。
2. **预估总成本 (Estimated Cost)**
   - 主数字：`$0.24`（保留 2~4 位小数，视金额量级而定）。
   - 副文本：自动换算本地货币 `≈ ¥1.73`（固定参考汇率 1 USD ≈ 7.2 CNY）。
   - 标注：`主流模型计费`；纯免费模型（如 Ollama）消耗不计入费用。
3. **调用总量与性能 (Requests & Latency)**
   - 主数字：`486 次`。
   - 副文本：`平均耗时 1.2s`，成功率 `99.4%`（或以 `失败 3 次` 醒目标注）。

### 3.2 每日消耗趋势（Daily Usage Trend）
- **形态**：轻量级每日堆叠柱状图（Stack Bar Chart）。
- **维度**：X 轴为日期（根据选定时间范围自适应：7 天或 30 天），Y 轴为 Token 数。
- **图例**：
  - 柱子下半部：`输入 (Prompt Tokens)`
  - 柱子上半部：`输出 (Completion Tokens)`
- **悬停交互（Apple Fluid Hover）**：
  - 鼠标滑过某一天时，弹出轻量 Tooltip，显示：
    - 日期（如 `2026-09-12`）
    - 输入 / 输出 Tokens
    - 当日预估费用（如 `$0.042`）
    - 当日调用次数（如 `42 次`）

### 3.3 模型明细表格（Model Breakdown）
按模型汇总的详细明细表，支持点击表头排序（默认按调用次数或消耗 Tokens 降序）：

| 列头 | 含义说明 | 示例值 |
|---|---|---|
| **模型 / 供应商** | 聚合后的 Model 标识与 Vendor | `DeepSeek-V3` / `DeepSeek`<br>`Claude 3.5 Sonnet` / `Anthropic`<br>`Qwen 2.5 (Local)` / `Ollama` |
| **请求次数** | 成功调用的总请求量（括号带失败数） | `320 次` `(1 失败)` |
| **输入 Tokens** | Prompt Tokens 总量 | `78,400` |
| **输出 Tokens** | Completion Tokens 总量 | `21,200` |
| **平均耗时** | 客户端测得的完整端到端响应时间 | `1.1s` |
| **预估费用** | 基于模型定价规则核算的费用 | `$0.038`（本地或免费模型显式显示绿色胶囊标签 `免费 / Free`） |

### 3.4 业务场景分布（Feature Breakdown）
全应用所有触发 LLM 的业务场景百分比横向进度条与明细：

- **语音智能润色 (Intelli Sense)**：听写主流程后的文字润色与格式化。
- **局部改写 (Voice Revise)**：用户呼出 `fn+R` 发起的指令级局部修改。
- **随手问答 (Ask Anything)**：独立问答会话中的多轮问答。
- **词库建议 (Vocabulary Suggestion)**：智能纠错生成的发音变体与热词推荐。
- **系统动作 (Mac Action)**：将自然语言语音解析为系统操作工具调用。
- **批量后台修复 (Batch Correction)**：静默生成的替换建议。

---

## 4. 计费与主流模型价格体系

系统内置常见主流大模型的基准费率（单位：USD / 1M Tokens = $ / MTok）：

| 模型家族 | 标识匹配规则 (Case-insensitive) | 输入单价 (Prompt) | 输出单价 (Completion) | 货币类型 |
|---|---|---|---|---|
| **DeepSeek V3** | 包含 `deepseek-chat` 或 `deepseek-v3` | $0.14 | $0.28 | USD |
| **DeepSeek R1** | 包含 `deepseek-reasoner` 或 `deepseek-r1` | $0.55 | $2.19 | USD |
| **Claude 3.5 Sonnet** | 包含 `claude-3-5-sonnet` | $3.00 | $15.00 | USD |
| **Claude 3.5 Haiku** | 包含 `claude-3-5-haiku` | $0.80 | $4.00 | USD |
| **GPT-4o** | 包含 `gpt-4o` 且不包含 `mini` | $2.50 | $10.00 | USD |
| **GPT-4o mini** | 包含 `gpt-4o-mini` | $0.15 | $0.60 | USD |
| **o3-mini** | 包含 `o3-mini` | $1.10 | $4.40 | USD |
| **火山 / 豆包 Pro** | 包含 `doubao-pro` | $0.12 (≈ ¥0.8) | $0.28 (≈ ¥2.0) | USD 折算 |
| **火山 / 豆包 Lite** | 包含 `doubao-lite` | $0.04 (≈ ¥0.3) | $0.08 (≈ ¥0.6) | USD 折算 |
| **本地 / 开源引擎** | 包含 `ollama`、`local`、`mlx`、`qwen` 本地运行 | **$0.00 (免费)** | **$0.00 (免费)** | Free |
| **未知 / 自定义模型** | 无法匹配任何主流特征 | $0.00 (标注未计价) | $0.00 (标注未计价) | N/A |

---

## 5. Apple Design 交互与视觉规范

严格遵循 Apple 人机交互规范及《Designing Fluid Interfaces》设计原则：

### 5.1 响应与连续性（Response & Fluidity）
- **即时反馈（Zero Latency）**：切换分段选择器时，选块背景与文本高亮在 Pointer-Down 瞬间激活，绝不等待 Pointer-Up。
- **无缝物理弹簧（Spring Physics）**：
  - 分段选择器的滑动高亮滑块采用 **无过冲临界阻尼弹簧**：`response: 0.35s`, `dampingRatio: 1.0`，干脆、平稳、无眩晕感；
  - 视图切换时采用温和的原生淡入与微小位移复合过渡（Cross-fade with subtle offset），不使用机械生硬的平移撞墙动效。

### 5.2 视觉层次与材质（Materials & Depth）
- **系统背景与卡片反差**：
  - 顶栏控件与 KPI 卡片使用 `TF.settingsCard` 与平滑连续圆角（`RoundedRectangle(cornerRadius: 10, style: .continuous)`）；
  - 表格行交替或边框使用极其微弱的 `TF.settingsTextTertiary.opacity(0.08)`，避免强分割线割裂视野。
- **字阶与排版（Typography & Optical Sizing）**：
  - 数字一律启用 `.monospacedDigit()`，避免数字跳变时字符抖动；
  - 大标题与大指标使用紧凑字距（Tracking -0.5 ~ -1.0），小标签正文使用标准字距；
  - 中英文首选 SF Pro / PingFang SC 原生动态字体排印。

### 5.3 辅助功能与动效减弱（Accessibility & Reduced Motion）
- 检测系统 `@Environment(\.accessibilityReduceMotion)`：
  - 开启减弱动效时，将所有弹簧切换与滑块平移动画替换为即时纯透明度交叉淡入（`opacity cross-fade 150ms`），杜绝位移眩晕。
- 文本对比度严格符合 WCAG AA 级标准，确保暗色模式（Dark Mode）与浅色模式（Light Mode）下数字与辅助文本具备足够对比度。

---

## 6. 国际化与本地化（Localization）

所有界面文案均支持中文与英文双语，并在切换语言时实时刷新：

| 标识 Key | 中文 (zh-Hans) | 英文 (en) |
|---|---|---|
| `tab.transcripts` | 听写记录 | Transcripts |
| `tab.asr_engines` | 语音引擎 | Speech Engines |
| `tab.llm_analytics` | 大模型用量 | LLM Analytics |
| `llm.total_tokens` | 总消耗 Token | Total Tokens |
| `llm.estimated_cost` | 预估总成本 | Estimated Cost |
| `llm.total_requests` | 请求次数与耗时 | Requests & Duration |
| `llm.input_tokens` | 输入: %@ | Input: %@ |
| `llm.output_tokens` | 输出: %@ | Output: %@ |
| `llm.avg_duration` | 平均耗时: %.1fs | Avg Duration: %.1fs |
| `llm.success_rate` | 成功率: %.1f%% | Success Rate: %.1f%% |
| `llm.daily_trend` | 每日消耗趋势 | Daily Usage Trend |
| `llm.by_model` | 模型用量明细 | Usage by Model |
| `llm.by_feature` | 业务场景分布 | Usage by Feature |
| `llm.free_badge` | 免费 | Free |
| `llm.export_csv` | 导出用量报表 | Export Usage CSV |
