import Foundation
import SQLite3

extension HistoryStore {

    /// Result container for paginated LLM usage records.
    public struct PaginatedLLMUsageRecords: Sendable {
        public let records: [LLMUsageRecord]
        public let totalCount: Int
        public let hasMore: Bool

        public init(records: [LLMUsageRecord], totalCount: Int, hasMore: Bool) {
            self.records = records
            self.totalCount = totalCount
            self.hasMore = hasMore
        }
    }

    /// Fetches individual LLM usage request records with pagination support (page & pageSize).
    public func getPaginatedLLMUsageRecords(
        page: Int = 1,
        pageSize: Int = 20,
        from fromDate: Date? = nil,
        to toDate: Date? = nil
    ) async -> PaginatedLLMUsageRecords {
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

        // 1. Fetch total count
        let countSQL = "SELECT COUNT(*) FROM llm_usage_history \(whereClause);"
        var totalCount = 0
        var countStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, countSQL, -1, &countStmt, nil) == SQLITE_OK {
            for (i, p) in params.enumerated() {
                bind(countStmt, Int32(i + 1), p)
            }
            if sqlite3_step(countStmt) == SQLITE_ROW {
                totalCount = Int(sqlite3_column_int(countStmt, 0))
            }
            sqlite3_finalize(countStmt)
        }

        // 2. Fetch page records
        let offset = max(0, (page - 1) * pageSize)
        let sql = """
        SELECT
            id,
            created_at,
            feature_source,
            provider,
            model,
            prompt_tokens,
            completion_tokens,
            total_tokens,
            duration_seconds,
            cost_usd,
            status,
            is_estimated,
            mode_name
        FROM llm_usage_history \(whereClause)
        ORDER BY created_at DESC
        LIMIT ? OFFSET ?;
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return PaginatedLLMUsageRecords(records: [], totalCount: totalCount, hasMore: false)
        }
        defer { sqlite3_finalize(stmt) }

        var bindIdx: Int32 = 1
        for p in params {
            bind(stmt, bindIdx, p)
            bindIdx += 1
        }
        sqlite3_bind_int(stmt, bindIdx, Int32(pageSize))
        sqlite3_bind_int(stmt, bindIdx + 1, Int32(offset))

        var records: [LLMUsageRecord] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = column(stmt, 0)
            let createdAtStr = column(stmt, 1)
            let createdAt = iso.date(from: createdAtStr) ?? Date()
            let rawFeature = column(stmt, 2)
            let feature = LLMFeatureSource(rawValue: rawFeature) ?? .other
            let provider = column(stmt, 3)
            let model = column(stmt, 4)
            let promptTokens = Int(sqlite3_column_int(stmt, 5))
            let completionTokens = Int(sqlite3_column_int(stmt, 6))
            let totalTokens = Int(sqlite3_column_int(stmt, 7))
            let duration = sqlite3_column_double(stmt, 8)
            let costUSD = sqlite3_column_double(stmt, 9)
            let status = column(stmt, 10)
            let isEstimated = sqlite3_column_int(stmt, 11) != 0
            let rawMode = column(stmt, 12)
            let modeName = rawMode.isEmpty ? nil : rawMode

            records.append(LLMUsageRecord(
                id: id,
                createdAt: createdAt,
                featureSource: feature,
                provider: provider,
                model: model,
                promptTokens: promptTokens,
                completionTokens: completionTokens,
                totalTokens: totalTokens,
                durationSeconds: duration,
                costUSD: costUSD,
                status: status,
                isEstimated: isEstimated,
                modeName: modeName
            ))
        }

        let hasMore = (offset + records.count) < totalCount
        return PaginatedLLMUsageRecords(records: records, totalCount: totalCount, hasMore: hasMore)
    }

    /// Legacy convenience wrapper
    public func getRecentLLMUsageRecords(
        limit: Int = 100,
        from fromDate: Date? = nil,
        to toDate: Date? = nil
    ) async -> [LLMUsageRecord] {
        let result = await getPaginatedLLMUsageRecords(page: 1, pageSize: limit, from: fromDate, to: toDate)
        return result.records
    }
}
