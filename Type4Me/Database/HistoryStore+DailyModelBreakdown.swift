import Foundation
import SQLite3

extension HistoryStore {

    /// Item breakdown for a single model on a specific day.
    public struct LLMDailyModelItem: Identifiable, Sendable, Equatable {
        public let dayIdentifier: String
        public let model: String
        public let promptTokens: Int
        public let completionTokens: Int
        public let totalTokens: Int
        public let costUSD: Double
        public let requestCount: Int

        public var id: String { "\(dayIdentifier)_\(model)" }

        public init(
            dayIdentifier: String,
            model: String,
            promptTokens: Int,
            completionTokens: Int,
            totalTokens: Int,
            costUSD: Double,
            requestCount: Int
        ) {
            self.dayIdentifier = dayIdentifier
            self.model = model
            self.promptTokens = promptTokens
            self.completionTokens = completionTokens
            self.totalTokens = totalTokens
            self.costUSD = costUSD
            self.requestCount = requestCount
        }
    }

    /// Fetches daily usage breakdown segmented by model name for chart stacking and hover inspection.
    public func fetchLLMDailyModelBreakdown(from fromDate: Date? = nil, to toDate: Date? = nil) async -> [LLMDailyModelItem] {
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
        let sql = """
        SELECT
            date(created_at, 'localtime') AS day_str,
            model,
            COALESCE(SUM(prompt_tokens), 0),
            COALESCE(SUM(completion_tokens), 0),
            COALESCE(SUM(total_tokens), 0),
            COALESCE(SUM(cost_usd), 0.0),
            COUNT(*)
        FROM llm_usage_history \(whereClause)
        GROUP BY day_str, model
        ORDER BY day_str ASC, 5 DESC;
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        for (i, p) in params.enumerated() {
            bind(stmt, Int32(i + 1), p)
        }

        var results: [LLMDailyModelItem] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            results.append(LLMDailyModelItem(
                dayIdentifier: column(stmt, 0),
                model: column(stmt, 1),
                promptTokens: Int(sqlite3_column_int(stmt, 2)),
                completionTokens: Int(sqlite3_column_int(stmt, 3)),
                totalTokens: Int(sqlite3_column_int(stmt, 4)),
                costUSD: sqlite3_column_double(stmt, 5),
                requestCount: Int(sqlite3_column_int(stmt, 6))
            ))
        }
        return results
    }
}
