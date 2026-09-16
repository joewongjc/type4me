# Type4Me 历史与用量看板（History & Usage Analytics）技术实现设计

> 文档类型：技术设计  
> 文档状态：当前有效（已实现，持续验证）
> 适用平台：Type4Me macOS (Swift 6 Concurrency, SQLite)  
> 上游文档：`docs/features/usage-analytics/product-design.md`  
> 核心模块：`HistoryStore` (SQLite 数据底座), `LLMPricingRegistry` (计价服务), `LLMClient` (协议与 Token 提取改造), `UsageAnalyticsUI` (SwiftUI 界面层)  
> 设计日期：2026-09-14  
> 最后校验：2026-09-16
> 实现基线：`b627606`（PR #310）

---

## 1. 架构总览与数据流

整体技术架构划分为三层：**采集层（Ingestion）**、**存储与计算层（Persistence & Aggregation）**、**展示层（Presentation）**。

```
                     ┌────────────────────────────────────────────────────────┐
                     │                       业务场景触发                      │
                     │  (IntelliSense, Revise, AskAnything, VocabGen, Action) │
                     └───────────────────────────┬────────────────────────────┘
                                                 │ 统一调用
                                                 ▼
                     ┌────────────────────────────────────────────────────────┐
                     │                   LLMClient 统一链路                   │
                     │  (DoubaoChatClient / ClaudeChatClient / CodexCLI / …)  │
                     │  - 解析 SSE chunk/message 中的 usage (prompt/comp tokens)│
                     │  - 计算端到端耗时 (ContinuousClock)                     │
                     │  - 若未返回 usage 则启用内置规则启发式估算 (Fallback)   │
                     └───────────────────────────┬────────────────────────────┘
                                                 │ 异步记账 (Fire-and-Forget)
                                                 ▼
                     ┌────────────────────────────────────────────────────────┐
                     │                   LLMPricingRegistry                   │
                     │       匹配模型单价 -> 计算 costUSD -> 生成记账 Record    │
                     └───────────────────────────┬────────────────────────────┘
                                                 │ 插入
                                                 ▼
                     ┌────────────────────────────────────────────────────────┐
                     │                 HistoryStore (SQLite)                  │
                     │  - llm_usage_history 独立表 (轻量、高效、索引优化)        │
                     │  - 提供按时间范围聚合查询接口 (KPI, Daily, Model, Feature)│
                     └───────────────────────────┬────────────────────────────┘
                                                 │ 状态驱动刷新
                                                 ▼
                     ┌────────────────────────────────────────────────────────┐
                     │                     UI 展示体系                         │
                     │  HistoryTab (单层胶囊分段选择器)                        │
                     │  ├── HistoryTranscriptsView (现有听写记录)             │
                     │  ├── ASRUsageAnalyticsView (独立语音引擎看板)           │
                     │  └── LLMUsageAnalyticsView (独立大模型用量看板)        │
                     └────────────────────────────────────────────────────────┘
```

---

## 2. 数据模型与 SQLite 存储方案

为了保证全量 LLM 调用的审计完整性，同时避免大文本字段影响统计查询性能，我们在 SQLite 中建立独立的 `llm_usage_history` 审计表。

### 2.1 数据库 Schema

在 `HistoryStore.swift` 初始化迁移脚本中执行：

```sql
CREATE TABLE IF NOT EXISTS llm_usage_history (
    id TEXT PRIMARY KEY,
    created_at TEXT NOT NULL,         -- ISO8601 格式，与主表统一
    feature_source TEXT NOT NULL,      -- 场景来源标识
    provider TEXT NOT NULL,            -- 供应商，如 'deepseek', 'claude', 'openai', 'ollama'
    model TEXT NOT NULL,               -- 模型名，如 'deepseek-chat', 'claude-3-5-sonnet'
    prompt_tokens INTEGER NOT NULL,    -- 输入 tokens
    completion_tokens INTEGER NOT NULL,-- 输出 tokens
    total_tokens INTEGER NOT NULL,     -- 总 tokens
    duration_seconds REAL NOT NULL,    -- 请求总耗时
    cost_usd REAL NOT NULL,            -- 预估成本 (美元)
    status TEXT NOT NULL,              -- 'success', 'error', 'cancelled'
    is_estimated INTEGER NOT NULL DEFAULT 0 -- 1 表示 usage 为估算值，0 表示官方返回
);

-- 加速时间过滤查询
CREATE INDEX IF NOT EXISTS idx_llm_usage_created_at ON llm_usage_history(created_at DESC);
-- 加速按模型分组统计
CREATE INDEX IF NOT EXISTS idx_llm_usage_model ON llm_usage_history(model);
-- 加速按场景分组统计
CREATE INDEX IF NOT EXISTS idx_llm_usage_feature ON llm_usage_history(feature_source);
```

### 2.2 Swift 数据实体定义

```swift
/// LLM 业务场景分类
enum LLMFeatureSource: String, Sendable, CaseIterable, Identifiable {
    case dictationPolish = "dictation_polish"   // 语音听写智能润色 (Intelli Sense)
    case voiceRevise     = "voice_revise"       // 局部改写 (Voice Revise)
    case askAnything     = "ask_anything"       // 随手问 (Ask Anything)
    case vocabSuggestion = "vocab_suggestion"   // 词库学习与热词推荐
    case macAction       = "mac_action"         // Mac Action 意图工具识别
    case batchCorrection = "batch_correction"   // 后台静默纠错
    case other           = "other"

    var id: String { rawValue }

    var localizedDisplayName: String {
        switch self {
        case .dictationPolish: return L("语音润色", "Dictation Polish")
        case .voiceRevise:     return L("局部改写", "Voice Revise")
        case .askAnything:     return L("随手问", "Ask Anything")
        case .vocabSuggestion: return L("词库建议", "Vocabulary Suggestion")
        case .macAction:       return L("系统操作", "Mac Action")
        case .batchCorrection: return L("批量纠错", "Batch Correction")
        case .other:           return L("其他", "Other")
        }
    }
}

/// 单条 LLM 调用消费记账实体
struct LLMUsageRecord: Identifiable, Sendable {
    let id: String
    let createdAt: Date
    let featureSource: LLMFeatureSource
    let provider: String
    let model: String
    let promptTokens: Int
    let completionTokens: Int
    let totalTokens: Int
    let durationSeconds: Double
    let costUSD: Double
    let status: String
    let isEstimated: Bool
}
```

### 2.3 聚合查询接口与返回结构

在 `HistoryStore` 中新增统一查询 API：

```swift
extension HistoryStore {

    /// 核心 KPI 汇总统计
    struct LLMSummaryStats: Sendable {
        let totalPromptTokens: Int
        let totalCompletionTokens: Int
        let totalTokens: Int
        let totalCostUSD: Double
        let totalRequests: Int
        let successfulRequests: Int
        let failedRequests: Int
        let averageDurationSeconds: Double
        let estimatedRequestCount: Int      // 包含估算 Token 的请求数

        var hasEstimatedUsage: Bool {
            estimatedRequestCount > 0
        }

        var successRate: Double {
            guard totalRequests > 0 else { return 1.0 }
            return Double(successfulRequests) / Double(totalRequests)
        }
    }

    /// 每日聚合趋势
    struct LLMDailyUsage: Identifiable, Sendable {
        let dayIdentifier: String        // "YYYY-MM-DD"
        let promptTokens: Int
        let completionTokens: Int
        let totalTokens: Int
        let costUSD: Double
        let requestCount: Int

        var id: String { dayIdentifier }
    }

    /// 按模型细分明细
    struct LLMModelBreakdown: Identifiable, Sendable {
        let modelName: String
        let provider: String
        let requestCount: Int
        let failedCount: Int
        let promptTokens: Int
        let completionTokens: Int
        let totalTokens: Int
        let averageDurationSeconds: Double
        let costUSD: Double
        let priceSource: ModelPriceSource
        let hasEstimatedUsage: Bool

        var id: String { "\(provider):\(modelName)" }
    }

    /// 按业务场景细分
    struct LLMFeatureBreakdown: Identifiable, Sendable {
        let feature: LLMFeatureSource
        let requestCount: Int
        let totalTokens: Int
        let costUSD: Double

        var id: String { feature.rawValue }
    }

    /// 整体用量聚合包
    struct LLMUsageReport: Sendable {
        let summary: LLMSummaryStats
        let dailyTrend: [LLMDailyUsage]
        let modelBreakdowns: [LLMModelBreakdown]
        let featureBreakdowns: [LLMFeatureBreakdown]
    }

    /// 获取指定时间区间的完整大模型用量报告
    func getLLMUsageReport(from: Date?, to: Date?) async -> LLMUsageReport
}
```

---

## 3. 模型计价体系：`LLMPricingRegistry`

### 3.1 价格结构与计算逻辑

```swift
struct ModelPriceRate: Sendable {
    let inputPricePerMTok: Double   // 每百万输入 Token 价格 (USD)
    let outputPricePerMTok: Double  // 每百万输出 Token 价格 (USD)
    let isFree: Bool
}

enum LLMPricingRegistry {
    /// 参考汇率 (USD -> CNY)
    static let usdToCnyRate: Double = 7.20

    /// 内置规则匹配
    static func rate(for model: String, provider: String) -> ModelPriceRate {
        let lowerModel = model.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let lowerProvider = provider.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        // 1. 本地模型/开源引擎判定为免费
        if lowerProvider == "ollama" || lowerProvider == "mlx" || lowerProvider == "local" ||
           lowerModel.contains("local") || lowerModel.contains("ollama") || lowerModel.contains("mlx") {
            return ModelPriceRate(inputPricePerMTok: 0, outputPricePerMTok: 0, isFree: true)
        }

        // 2. DeepSeek 系列
        if lowerModel.contains("deepseek-chat") || lowerModel.contains("deepseek-v3") {
            return ModelPriceRate(inputPricePerMTok: 0.14, outputPricePerMTok: 0.28, isFree: false)
        }
        if lowerModel.contains("deepseek-reasoner") || lowerModel.contains("deepseek-r1") {
            return ModelPriceRate(inputPricePerMTok: 0.55, outputPricePerMTok: 2.19, isFree: false)
        }

        // 3. Claude 系列
        if lowerModel.contains("claude-3-5-sonnet") || lowerModel.contains("claude-3.5-sonnet") {
            return ModelPriceRate(inputPricePerMTok: 3.00, outputPricePerMTok: 15.00, isFree: false)
        }
        if lowerModel.contains("claude-3-5-haiku") || lowerModel.contains("claude-3.5-haiku") {
            return ModelPriceRate(inputPricePerMTok: 0.80, outputPricePerMTok: 4.00, isFree: false)
        }

        // 4. OpenAI 系列
        if lowerModel.contains("gpt-4o-mini") {
            return ModelPriceRate(inputPricePerMTok: 0.15, outputPricePerMTok: 0.60, isFree: false)
        }
        if lowerModel.contains("gpt-4o") {
            return ModelPriceRate(inputPricePerMTok: 2.50, outputPricePerMTok: 10.00, isFree: false)
        }
        if lowerModel.contains("o3-mini") {
            return ModelPriceRate(inputPricePerMTok: 1.10, outputPricePerMTok: 4.40, isFree: false)
        }

        // 5. 豆包 / 火山方舟 (折合成 USD)
        if lowerModel.contains("doubao-pro") {
            return ModelPriceRate(inputPricePerMTok: 0.12, outputPricePerMTok: 0.28, isFree: false)
        }
        if lowerModel.contains("doubao-lite") {
            return ModelPriceRate(inputPricePerMTok: 0.04, outputPricePerMTok: 0.08, isFree: false)
        }

        // 6. 默认未匹配 (未知模型，不收费计入)
        return ModelPriceRate(inputPricePerMTok: 0, outputPricePerMTok: 0, isFree: false)
    }

    /// 计算单次调用花费
    static func calculateCostUSD(model: String, provider: String, promptTokens: Int, completionTokens: Int) -> Double {
        let price = rate(for: model, provider: provider)
        if price.isFree { return 0.0 }
        let inputCost = (Double(promptTokens) / 1_000_000.0) * price.inputPricePerMTok
        let outputCost = (Double(completionTokens) / 1_000_000.0) * price.outputPricePerMTok
        return inputCost + outputCost
    }
}
```

---

## 4. LLM 链路 Token 采集与记账上报

### 4.1 Token 提取与回传

在 `LLMClient` 协议中，扩展返回元数据结构：

```swift
struct LLMExecutionMetrics: Sendable {
    let promptTokens: Int?
    let completionTokens: Int?
    let durationSeconds: Double
}
```

各客户端采集逻辑：
1. **OpenAI / DeepSeek 兼容流式协议（`DoubaoChatClient.swift`）**：
   - 请求体增加 `"stream_options": {"include_usage": true}`；
   - 监听流中最后一个携带 `usage` 对象的 chunk，解码并提取 `prompt_tokens` 与 `completion_tokens`。
2. **Claude 客户端（`ClaudeChatClient.swift`）**：
   - 监听 SSE 事件 `message_start`（获取并记录 `message.usage.input_tokens`）；
   - 监听 SSE 事件 `message_delta`（获取顶层 `usage.output_tokens` 最终累计值，注意并非在 `delta` 内部）；
   - 扩展 `ClaudeStreamEvent` 数据结构解码顶层 `usage` 字段。
3. **启发式兜底估算（Fallback Estimator）**：
   - 若模型接口未回传 usage，使用通用经验规则：
     - 中文字符数 $\times 0.7$
     - 英文词数 $\times 1.3$
   - 保证所有场景都能生成 Token 记录，并标明 `is_estimated = 1`。

### 4.2 记账上报中枢：`LLMUsageRecorder`

建立全局单例或通过 `HistoryStore` 进行异步非阻塞写入：

```swift
actor LLMUsageRecorder {
    static let shared = LLMUsageRecorder()

    func record(
        featureSource: LLMFeatureSource,
        provider: String,
        model: String,
        promptTokens: Int,
        completionTokens: Int,
        durationSeconds: Double,
        status: String,
        isEstimated: Bool = false
    ) {
        let costUSD = LLMPricingRegistry.calculateCostUSD(
            model: model,
            provider: provider,
            promptTokens: promptTokens,
            completionTokens: completionTokens
        )

        let record = LLMUsageRecord(
            id: UUID().uuidString,
            createdAt: Date(),
            featureSource: featureSource,
            provider: provider,
            model: model,
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            totalTokens: promptTokens + completionTokens,
            durationSeconds: durationSeconds,
            costUSD: costUSD,
            status: status,
            isEstimated: isEstimated
        )

        Task {
            await HistoryStore.shared.insertLLMUsage(record)
        }
    }
}
```

在各调用点注入上报：
- `RecognitionSession.swift`（智能润色）：上报 `dictationPolish`；
- `VoiceReviseSession.swift`（改口）：上报 `voiceRevise`；
- `AskAnythingSession.swift`（问答）：上报 `askAnything`；
- `ASRVariantGenerator.swift`（词库建议）：上报 `vocabSuggestion`；
- `MacAction` 调度链路：上报 `macAction`。

---

## 5. UI 架构重构与 Apple Design 动效规范

### 5.1 视图组件解耦与重组

现有的 `HistoryTab.swift` 文件庞大（1600+ 行），借此机会进行清晰的模块化重构：

```
Type4Me/UI/Settings/
├── HistoryTab.swift                   // 顶层容器，管理分段切换与子页面切换动画
├── History/
│   ├── HistoryTranscriptsView.swift   // 原有听写记录列表、搜索、过滤
│   ├── ASRUsageAnalyticsView.swift    // 独立 ASR 引擎分析看板
│   └── LLMUsageAnalyticsView.swift    // 独立大模型用量与成本看板
```

### 5.2 顶部单层胶囊分段器（Single-tier Segmented Control）

```swift
enum HistorySubtab: String, CaseIterable, Identifiable {
    case transcripts
    case asrEngines
    case llmAnalytics

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .transcripts:  return L("听写记录", "Transcripts")
        case .asrEngines:   return L("语音引擎", "Speech Engines")
        case .llmAnalytics: return L("大模型用量", "LLM Analytics")
        }
    }

    var icon: String {
        switch self {
        case .transcripts:  return "text.bubble"
        case .asrEngines:   return "waveform"
        case .llmAnalytics: return "sparkles"
        }
    }
}
```

#### 物理弹簧动效实现（遵循 `apple-design` 规范）：
- 滑块移动采用临界阻尼弹簧（注意 SwiftUI 标准 API 参数标签为 `dampingFraction`）：
  ```swift
  .animation(.spring(response: 0.35, dampingFraction: 1.0), value: selectedSubtab)
  ```
- **保持听写列表工作状态（State Preservation）**：
  - 绝不能简单使用 `switch selectedSubtab` 条件生成销毁 `HistoryTranscriptsView`，否则会重置用户的搜索文本（`searchText`）、日期筛选（`dateFilter`）、展开行（`expandedRecordIds`）以及分页加载进度。
  - 解决方案：采用父容器保有状态模型，或使用保留视图状态的容器方式（如 `.opacity()` + `.allowsHitTesting()`），确保切到用量看板再切回时历史记录上下文无损保留：
  ```swift
  ZStack {
      HistoryTranscriptsView()
          .opacity(selectedSubtab == .transcripts ? 1 : 0)
          .allowsHitTesting(selectedSubtab == .transcripts)

      ASRUsageAnalyticsView()
          .opacity(selectedSubtab == .asrEngines ? 1 : 0)
          .allowsHitTesting(selectedSubtab == .asrEngines)

      LLMUsageAnalyticsView()
          .opacity(selectedSubtab == .llmAnalytics ? 1 : 0)
          .allowsHitTesting(selectedSubtab == .llmAnalytics)
  }
  .animation(.easeInOut(duration: 0.2), value: selectedSubtab)
  ```
- 当用户开启“减弱动态效果”（`accessibilityReduceMotion`）时，禁用滑块位移动画，仅保留 `opacity cross-fade 0.15s`。

---

## 6. 版本兼容与历史数据回填（Backfill Migration）

### 6.1 数据库 Schema 向前/向后兼容性
1. **升级兼容（Forward Compatibility）**：
   - 新增的 `llm_usage_history` 为完全独立的表，使用 `CREATE TABLE IF NOT EXISTS` 创建。
   - **零侵入原有表结构**：不修改 `recognition_history`、`recognition_feedback` 或 `recognition_revisions` 的任何列，确保老代码依赖固定列序号读取时不受影响。
2. **降级兼容（Backward Compatibility）**：
   - 若用户从带有该功能的新版本降级回旧版应用，旧版客户端不会感知也不查询 `llm_usage_history` 表，旧版功能可正常运行，无崩溃或数据破坏风险。

### 6.2 历史听写数据冷启动回溯预填（Lazy Backfill）
为了避免老用户升级后大模型用量看板全部显示为 0，`HistoryStore` 在首次加载时执行一次只读历史回填：
1. 检查 `llm_usage_history` 是否为空，且 `recognition_history` 中存在 `llm_provider IS NOT NULL` 的记录；
2. 扫描历史记录中存在 LLM 调用的听写流水，基于已有字段进行估算与定价还原：
   - `prompt_tokens` = `max(1, Int(Double(raw_text.count) * 0.7))`
   - `completion_tokens` = `max(1, Int(Double(final_text.count) * 0.7))`
   - `cost_usd` = `LLMPricingRegistry.calculateCostUSD(...)`
   - `is_estimated` = `1`
   - `feature_source` = `dictation_polish`
3. 批量写入 `llm_usage_history`，并在完成时持久化 `UserDefaults` 标记 `tf_llm_usage_backfill_completed = true`，避免重复执行。
---

## 7. 测试与验证策略

1. **单元测试与计算验证**：
   - `LLMPricingRegistryTests`：验证 DeepSeek、Claude、GPT-4o、Ollama 免费模型单价计算的精确性；
   - `HistoryStoreLLMUsageTests`：验证 `insertLLMUsage`、按天汇总、按模型汇总、按场景汇总的 SQL 正确性与并发安全。
2. **端到端集成验证**：
   - 执行一次语音听写润色 $\to$ 验证 `llm_usage_history` 产生记账记录；
   - 执行一次 `fn + R` 改口 $\to$ 验证记账记录的 `feature_source` 为 `voice_revise`；
   - 切换「大模型用量」Tab $\to$ 验证 KPI 卡片实时更新，图表与表格正确渲染。
3. **UI 体验与性能检查**：
   - 连续在三大分段之间快速点击切换，确保动画中断平滑无卡顿，无多余布局刷新抖动；
   - 验证中英文切换时所有指标名称与图表标签即时更新；
   - 验证系统 Dark Mode / Light Mode 下的视觉对比度与字体清晰度。
