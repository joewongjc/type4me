import Foundation
import SQLite3

extension HistoryStore {

    /// Fetches usage breakdown strictly filtered by optional date range (e.g. fromDate ~ toDate).
    public func getFilteredUsageBreakdown(
        now: Date = Date()
    ) async -> [UsageBreakdown] {
        let iso = ISO8601DateFormatter()
        let lastDay = iso.string(from: now.addingTimeInterval(-24 * 60 * 60))
        let last7Days = iso.string(from: now.addingTimeInterval(-7 * 24 * 60 * 60))
        let last30Days = iso.string(from: now.addingTimeInterval(-30 * 24 * 60 * 60))
        let unknown = L("未知", "Unknown")

        let whereClause = "WHERE " + Self.activeStatusSQLCondition
        let sql = """
        SELECT
            CASE
                WHEN lower(trim(COALESCE(asr_provider, ''))) = 'elevenlabs'
                     AND (NULLIF(trim(asr_model), '') IS NULL
                          OR lower(trim(asr_model)) = 'elevenlabs')
                    THEN 'ElevenLabs · scribe_v2_realtime'
                WHEN lower(trim(COALESCE(asr_provider, ''))) = 'deepgram'
                     AND (NULLIF(trim(asr_model), '') IS NULL
                          OR lower(trim(asr_model)) = 'deepgram')
                    THEN 'Deepgram'
                ELSE COALESCE(NULLIF(asr_model, ''), NULLIF(asr_provider, ''), ?)
            END AS model_name,
            COALESCE(SUM(CASE WHEN created_at >= ? THEN duration_seconds ELSE 0 END), 0),
            COALESCE(SUM(CASE WHEN created_at >= ? THEN duration_seconds ELSE 0 END), 0),
            COALESCE(SUM(CASE WHEN created_at >= ? THEN duration_seconds ELSE 0 END), 0),
            COALESCE(SUM(duration_seconds), 0),
            COUNT(*),
            COALESCE(SUM(CASE WHEN COALESCE(feedback.quality_score, 0) < 0 THEN 1 ELSE 0 END), 0)
        FROM recognition_history
        LEFT JOIN recognition_feedback AS feedback
            ON feedback.record_id = recognition_history.id
        \(whereClause)
        GROUP BY 1
        ORDER BY CASE WHEN model_name = ? THEN 1 ELSE 0 END,
                 5 DESC,
                 model_name COLLATE NOCASE ASC;
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        // Bind positional parameters:
        // 1: unknown (CASE default)
        // 2: lastDay
        // 3: last7Days
        // 4: last30Days
        // 5: unknown (ORDER BY)
        bind(stmt, 1, unknown)
        bind(stmt, 2, lastDay)
        bind(stmt, 3, last7Days)
        bind(stmt, 4, last30Days)
        bind(stmt, 5, unknown)
        var rows: [UsageBreakdown] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            rows.append(UsageBreakdown(
                modelName: column(stmt, 0),
                lastDayDuration: sqlite3_column_double(stmt, 1),
                last7DaysDuration: sqlite3_column_double(stmt, 2),
                last30DaysDuration: sqlite3_column_double(stmt, 3),
                allTimeDuration: sqlite3_column_double(stmt, 4),
                recordCount: Int(sqlite3_column_int(stmt, 5)),
                badCount: Int(sqlite3_column_int(stmt, 6))
            ))
        }
        return rows
    }
}
