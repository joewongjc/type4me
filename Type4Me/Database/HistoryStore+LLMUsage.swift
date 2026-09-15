import Foundation
import SQLite3

// MARK: - LLM Usage Analytics DTOs

extension HistoryStore {

    /// Summary KPI metrics across all LLM requests within a timeframe.
    public struct LLMSummaryStats: Sendable, Equatable {
        public let totalPromptTokens: Int
        public let totalCompletionTokens: Int
        public let totalTokens: Int
        public let totalCostUSD: Double
        public let totalRequests: Int
        public let successfulRequests: Int
        public let failedRequests: Int
        public let averageDurationSeconds: Double
        public let estimatedRequestCount: Int

        public var hasEstimatedUsage: Bool {
            estimatedRequestCount > 0
        }

        public var successRate: Double {
            guard totalRequests > 0 else { return 1.0 }
            return Double(successfulRequests) / Double(totalRequests)
        }

        public init(
            totalPromptTokens: Int = 0,
            totalCompletionTokens: Int = 0,
            totalTokens: Int = 0,
            totalCostUSD: Double = 0.0,
            totalRequests: Int = 0,
            successfulRequests: Int = 0,
            failedRequests: Int = 0,
            averageDurationSeconds: Double = 0.0,
            estimatedRequestCount: Int = 0
        ) {
            self.totalPromptTokens = totalPromptTokens
            self.totalCompletionTokens = totalCompletionTokens
            self.totalTokens = totalTokens
            self.totalCostUSD = totalCostUSD
            self.totalRequests = totalRequests
            self.successfulRequests = successfulRequests
            self.failedRequests = failedRequests
            self.averageDurationSeconds = averageDurationSeconds
            self.estimatedRequestCount = estimatedRequestCount
        }
    }

    /// Daily aggregated token consumption and costs.
    public struct LLMDailyUsage: Identifiable, Sendable, Equatable {
        public let dayIdentifier: String        // "YYYY-MM-DD"
        public let promptTokens: Int
        public let completionTokens: Int
        public let totalTokens: Int
        public let costUSD: Double
        public let requestCount: Int

        public var id: String { dayIdentifier }

        public init(
            dayIdentifier: String,
            promptTokens: Int,
            completionTokens: Int,
            totalTokens: Int,
            costUSD: Double,
            requestCount: Int
        ) {
            self.dayIdentifier = dayIdentifier
            self.promptTokens = promptTokens
            self.completionTokens = completionTokens
            self.totalTokens = totalTokens
            self.costUSD = costUSD
            self.requestCount = requestCount
        }
    }

    /// Breakdown of usage by model name and provider.
    public struct LLMModelBreakdown: Identifiable, Sendable, Equatable {
        public let modelName: String
        public let provider: String
        public let requestCount: Int
        public let failedCount: Int
        public let promptTokens: Int
        public let completionTokens: Int
        public let totalTokens: Int
        public let averageDurationSeconds: Double
        public let costUSD: Double
        public let isFreeTier: Bool
        public let hasEstimatedUsage: Bool

        public var id: String { "\(provider):\(modelName)" }

        public init(
            modelName: String,
            provider: String,
            requestCount: Int,
            failedCount: Int,
            promptTokens: Int,
            completionTokens: Int,
            totalTokens: Int,
            averageDurationSeconds: Double,
            costUSD: Double,
            isFreeTier: Bool,
            hasEstimatedUsage: Bool
        ) {
            self.modelName = modelName
            self.provider = provider
            self.requestCount = requestCount
            self.failedCount = failedCount
            self.promptTokens = promptTokens
            self.completionTokens = completionTokens
            self.totalTokens = totalTokens
            self.averageDurationSeconds = averageDurationSeconds
            self.costUSD = costUSD
            self.isFreeTier = isFreeTier
            self.hasEstimatedUsage = hasEstimatedUsage
        }
    }

    /// Breakdown of usage by feature source and mode name (polish, revise, ask, etc.).
    public struct LLMFeatureBreakdown: Identifiable, Sendable, Equatable {
        public let feature: LLMFeatureSource
        public let modeName: String?
        public let requestCount: Int
        public let totalTokens: Int
        public let costUSD: Double

        public var id: String {
            if let modeName, !modeName.isEmpty {
                return "\(feature.rawValue)_\(modeName)"
            }
            return feature.rawValue
        }

        public var displayName: String {
            if let modeName, !modeName.isEmpty {
                return modeName
            }
            return feature.localizedDisplayName
        }

        public init(
            feature: LLMFeatureSource,
            modeName: String? = nil,
            requestCount: Int,
            totalTokens: Int,
            costUSD: Double
        ) {
            self.feature = feature
            self.modeName = modeName
            self.requestCount = requestCount
            self.totalTokens = totalTokens
            self.costUSD = costUSD
        }
    }

    /// Comprehensive usage report bundle.
    public struct LLMUsageReport: Sendable, Equatable {
        public let summary: LLMSummaryStats
        public let dailyTrend: [LLMDailyUsage]
        public let modelBreakdowns: [LLMModelBreakdown]
        public let featureBreakdowns: [LLMFeatureBreakdown]

        public init(
            summary: LLMSummaryStats = .init(),
            dailyTrend: [LLMDailyUsage] = [],
            modelBreakdowns: [LLMModelBreakdown] = [],
            featureBreakdowns: [LLMFeatureBreakdown] = []
        ) {
            self.summary = summary
            self.dailyTrend = dailyTrend
            self.modelBreakdowns = modelBreakdowns
            self.featureBreakdowns = featureBreakdowns
        }
    }
}

// MARK: - HistoryStore LLM Usage CRUD & Aggregations

extension HistoryStore {

    /// Inserts a new LLM usage entry into the database.
    public func insertLLMUsage(_ record: LLMUsageRecord) {
        let sql = """
        INSERT OR REPLACE INTO llm_usage_history
        (id, created_at, feature_source, provider, model, prompt_tokens, completion_tokens, total_tokens, duration_seconds, cost_usd, status, is_estimated, mode_name)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        let iso = ISO8601DateFormatter()
        bind(stmt, 1, record.id)
        bind(stmt, 2, iso.string(from: record.createdAt))
        bind(stmt, 3, record.featureSource.rawValue)
        bind(stmt, 4, record.provider)
        bind(stmt, 5, record.model)
        sqlite3_bind_int(stmt, 6, Int32(record.promptTokens))
        sqlite3_bind_int(stmt, 7, Int32(record.completionTokens))
        sqlite3_bind_int(stmt, 8, Int32(record.totalTokens))
        sqlite3_bind_double(stmt, 9, record.durationSeconds)
        sqlite3_bind_double(stmt, 10, record.costUSD)
        bind(stmt, 11, record.status)
        sqlite3_bind_int(stmt, 12, record.isEstimated ? 1 : 0)
        bindOptional(stmt, 13, record.modeName)
        if sqlite3_step(stmt) == SQLITE_DONE {
            postLLMUsageDidChangeNotification()
        }
    }

    /// Fetches the aggregated report for a given time window.
    public func getLLMUsageReport(from fromDate: Date? = nil, to toDate: Date? = nil) async -> LLMUsageReport {
        let iso = ISO8601DateFormatter()
        var conditions: [String] = []
        var params: [String] = []

        if let fromDate {
            conditions.append("created_at >= ?")
            params.append(iso.string(from: fromDate))
        }
        if let toDate {
            conditions.append("created_at < ?")
            params.append(iso.string(from: toDate))
        }

        let whereClause = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")

        let summary = await fetchLLMSummary(whereClause: whereClause, params: params)
        let daily = await fetchLLMDailyUsage(whereClause: whereClause, params: params)
        let models = await fetchLLMModelBreakdowns(whereClause: whereClause, params: params)
        let features = await fetchLLMFeatureBreakdowns(whereClause: whereClause, params: params)

        return LLMUsageReport(
            summary: summary,
            dailyTrend: daily,
            modelBreakdowns: models,
            featureBreakdowns: features
        )
    }

    private func fetchLLMSummary(whereClause: String, params: [String]) async -> LLMSummaryStats {
        let sql = """
        SELECT
            COALESCE(SUM(prompt_tokens), 0),
            COALESCE(SUM(completion_tokens), 0),
            COALESCE(SUM(total_tokens), 0),
            COALESCE(SUM(cost_usd), 0.0),
            COUNT(*),
            COALESCE(SUM(CASE WHEN status = 'success' THEN 1 ELSE 0 END), 0),
            COALESCE(SUM(CASE WHEN status != 'success' THEN 1 ELSE 0 END), 0),
            COALESCE(AVG(duration_seconds), 0.0),
            COALESCE(SUM(CASE WHEN is_estimated = 1 THEN 1 ELSE 0 END), 0)
        FROM llm_usage_history \(whereClause);
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return .init() }
        defer { sqlite3_finalize(stmt) }

        for (i, p) in params.enumerated() {
            bind(stmt, Int32(i + 1), p)
        }

        if sqlite3_step(stmt) == SQLITE_ROW {
            return LLMSummaryStats(
                totalPromptTokens: Int(sqlite3_column_int(stmt, 0)),
                totalCompletionTokens: Int(sqlite3_column_int(stmt, 1)),
                totalTokens: Int(sqlite3_column_int(stmt, 2)),
                totalCostUSD: sqlite3_column_double(stmt, 3),
                totalRequests: Int(sqlite3_column_int(stmt, 4)),
                successfulRequests: Int(sqlite3_column_int(stmt, 5)),
                failedRequests: Int(sqlite3_column_int(stmt, 6)),
                averageDurationSeconds: sqlite3_column_double(stmt, 7),
                estimatedRequestCount: Int(sqlite3_column_int(stmt, 8))
            )
        }
        return .init()
    }

    private func fetchLLMDailyUsage(whereClause: String, params: [String]) async -> [LLMDailyUsage] {
        let sql = """
        SELECT
            date(created_at, 'localtime') AS day_str,
            COALESCE(SUM(prompt_tokens), 0),
            COALESCE(SUM(completion_tokens), 0),
            COALESCE(SUM(total_tokens), 0),
            COALESCE(SUM(cost_usd), 0.0),
            COUNT(*)
        FROM llm_usage_history \(whereClause)
        GROUP BY day_str
        ORDER BY day_str ASC;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        for (i, p) in params.enumerated() {
            bind(stmt, Int32(i + 1), p)
        }

        var results: [LLMDailyUsage] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            results.append(LLMDailyUsage(
                dayIdentifier: column(stmt, 0),
                promptTokens: Int(sqlite3_column_int(stmt, 1)),
                completionTokens: Int(sqlite3_column_int(stmt, 2)),
                totalTokens: Int(sqlite3_column_int(stmt, 3)),
                costUSD: sqlite3_column_double(stmt, 4),
                requestCount: Int(sqlite3_column_int(stmt, 5))
            ))
        }
        return results
    }

    private func fetchLLMModelBreakdowns(whereClause: String, params: [String]) async -> [LLMModelBreakdown] {
        let sql = """
        SELECT
            model,
            provider,
            COUNT(*),
            COALESCE(SUM(CASE WHEN status != 'success' THEN 1 ELSE 0 END), 0),
            COALESCE(SUM(prompt_tokens), 0),
            COALESCE(SUM(completion_tokens), 0),
            COALESCE(SUM(total_tokens), 0),
            COALESCE(AVG(duration_seconds), 0.0),
            COALESCE(SUM(cost_usd), 0.0),
            COALESCE(SUM(CASE WHEN is_estimated = 1 THEN 1 ELSE 0 END), 0)
        FROM llm_usage_history \(whereClause)
        GROUP BY model, provider
        ORDER BY 3 DESC, 7 DESC;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        for (i, p) in params.enumerated() {
            bind(stmt, Int32(i + 1), p)
        }

        var results: [LLMModelBreakdown] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let model = column(stmt, 0)
            let provider = column(stmt, 1)
            let estimatedCount = Int(sqlite3_column_int(stmt, 9))
            let isFree = LLMPricingRegistry.rate(for: model, provider: provider).isFree

            results.append(LLMModelBreakdown(
                modelName: model,
                provider: provider,
                requestCount: Int(sqlite3_column_int(stmt, 2)),
                failedCount: Int(sqlite3_column_int(stmt, 3)),
                promptTokens: Int(sqlite3_column_int(stmt, 4)),
                completionTokens: Int(sqlite3_column_int(stmt, 5)),
                totalTokens: Int(sqlite3_column_int(stmt, 6)),
                averageDurationSeconds: sqlite3_column_double(stmt, 7),
                costUSD: sqlite3_column_double(stmt, 8),
                isFreeTier: isFree,
                hasEstimatedUsage: estimatedCount > 0
            ))
        }
        return results
    }

    private func fetchLLMFeatureBreakdowns(whereClause: String, params: [String]) async -> [LLMFeatureBreakdown] {
        let sql = """
        SELECT
            feature_source,
            mode_name,
            COUNT(*),
            COALESCE(SUM(total_tokens), 0),
            COALESCE(SUM(cost_usd), 0.0)
        FROM llm_usage_history \(whereClause)
        GROUP BY feature_source, mode_name
        ORDER BY 3 DESC;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        for (i, p) in params.enumerated() {
            bind(stmt, Int32(i + 1), p)
        }

        var results: [LLMFeatureBreakdown] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let rawFeature = column(stmt, 0)
            let feature = LLMFeatureSource(rawValue: rawFeature) ?? .other
            let rawMode = column(stmt, 1)
            let modeName = rawMode.isEmpty ? nil : rawMode
            results.append(LLMFeatureBreakdown(
                feature: feature,
                modeName: modeName,
                requestCount: Int(sqlite3_column_int(stmt, 2)),
                totalTokens: Int(sqlite3_column_int(stmt, 3)),
                costUSD: sqlite3_column_double(stmt, 4)
            ))
        }
        return results
    }

    /// Backfills historical recognition_history records into llm_usage_history once if needed.
    public func backfillHistoricalLLMUsageIfNeeded() async {
        let defaultsKey = "tf_llm_usage_backfill_completed"
        guard !UserDefaults.standard.bool(forKey: defaultsKey) else { return }

        // Check if llm_usage_history already has records
        let countSQL = "SELECT COUNT(*) FROM llm_usage_history;"
        var countStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, countSQL, -1, &countStmt, nil) == SQLITE_OK {
            if sqlite3_step(countStmt) == SQLITE_ROW {
                let count = sqlite3_column_int(countStmt, 0)
                if count > 0 {
                    UserDefaults.standard.set(true, forKey: defaultsKey)
                    sqlite3_finalize(countStmt)
                    return
                }
            }
            sqlite3_finalize(countStmt)
        }

        // Query historical records that used LLM
        let selectSQL = """
        SELECT id, created_at, raw_text, final_text, llm_provider, llm_model, llm_duration_seconds, status, processing_mode
        FROM recognition_history
        WHERE llm_provider IS NOT NULL AND trim(llm_provider) != '';
        """
        var selectStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, selectSQL, -1, &selectStmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(selectStmt) }

        let iso = ISO8601DateFormatter()
        var recordsToInsert: [LLMUsageRecord] = []

        while sqlite3_step(selectStmt) == SQLITE_ROW {
            let id = column(selectStmt, 0)
            let createdAtStr = column(selectStmt, 1)
            let createdAt = iso.date(from: createdAtStr) ?? Date()
            let rawText = column(selectStmt, 2)
            let finalText = column(selectStmt, 3)
            let provider = column(selectStmt, 4)
            let model = column(selectStmt, 5).isEmpty ? provider : column(selectStmt, 5)
            let duration = sqlite3_column_double(selectStmt, 6)
            let status = column(selectStmt, 7)
            let mode = column(selectStmt, 8)
            let modeName = mode.isEmpty ? nil : mode

            // Token heuristics: ~0.7 tokens per char for Chinese / word for English
            let promptTokens = max(1, Int(Double(rawText.count) * 0.7))
            let completionTokens = max(1, Int(Double(finalText.count) * 0.7))
            let costUSD = LLMPricingRegistry.calculateCostUSD(
                model: model,
                provider: provider,
                promptTokens: promptTokens,
                completionTokens: completionTokens
            )

            recordsToInsert.append(LLMUsageRecord(
                id: "backfill_\(id)",
                createdAt: createdAt,
                featureSource: .dictationPolish,
                provider: provider,
                model: model,
                promptTokens: promptTokens,
                completionTokens: completionTokens,
                totalTokens: promptTokens + completionTokens,
                durationSeconds: duration,
                costUSD: costUSD,
                status: status.contains("error") ? "error" : "success",
                isEstimated: true,
                modeName: modeName
            ))
        }

        if !recordsToInsert.isEmpty {
            for record in recordsToInsert {
                insertLLMUsage(record)
            }
            NSLog("[HistoryStore] Backfilled %d historical LLM usage records", recordsToInsert.count)
        }

        UserDefaults.standard.set(true, forKey: defaultsKey)
    }

    private func postLLMUsageDidChangeNotification() {
        Task { @MainActor in
            NotificationCenter.default.post(name: .llmUsageStoreDidChange, object: nil)
        }
    }
}

extension Notification.Name {
    public static let llmUsageStoreDidChange = Notification.Name("llmUsageStoreDidChange")
}
