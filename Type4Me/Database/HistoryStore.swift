import Foundation
import SQLite3
import Type4MeReviseCore

extension Notification.Name {
    static let historyStoreDidChange = Notification.Name("Type4Me.historyStoreDidChange")
}
actor HistoryStore {

    static let shared = HistoryStore()

    private var db: OpaquePointer?

    init(path: String? = nil) {
        let dbPath: String
        if let path {
            dbPath = path
        } else {
            let appSupport = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            ).first!.appendingPathComponent("Type4Me", isDirectory: true)
            try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
            dbPath = appSupport.appendingPathComponent("history.db").path
        }

        if sqlite3_open(dbPath, &db) == SQLITE_OK {
            let fkStatus = sqlite3_exec(db, "PRAGMA foreign_keys = ON;", nil, nil, nil)
            if fkStatus != SQLITE_OK {
                NSLog("[HistoryStore] Failed to enable foreign keys: %d", fkStatus)
            }
            sqlite3_exec(db, "PRAGMA cache_size = -2000;", nil, nil, nil)
            sqlite3_exec(db, "PRAGMA temp_store = MEMORY;", nil, nil, nil)
            sqlite3_exec(db, "PRAGMA mmap_size = 2097152;", nil, nil, nil)

            let sql = """
            CREATE TABLE IF NOT EXISTS recognition_history (
                id TEXT PRIMARY KEY,
                created_at TEXT NOT NULL,
                duration_seconds REAL,
                raw_text TEXT NOT NULL,
                processing_mode TEXT,
                processed_text TEXT,
                final_text TEXT NOT NULL,
                status TEXT NOT NULL,
                character_count INTEGER,
                asr_provider TEXT,
                asr_model TEXT,
                intelli_sense_trace TEXT,
                llm_provider TEXT,
                llm_model TEXT,
                asr_duration_seconds REAL,
                llm_duration_seconds REAL,
                user_edited_text TEXT,
                user_edit_status TEXT,
                user_edit_observed_at TEXT,
                user_edit_version INTEGER
            );
            """
            sqlite3_exec(db, sql, nil, nil, nil)

            // Keep quality feedback separate from recognition_history so
            // marking a transcription bad does not change the history schema.
            let feedbackTableSQL = """
            CREATE TABLE IF NOT EXISTS recognition_feedback (
                record_id TEXT PRIMARY KEY,
                quality_score INTEGER NOT NULL DEFAULT 0,
                marked_at TEXT NOT NULL,
                FOREIGN KEY(record_id)
                    REFERENCES recognition_history(id)
                    ON DELETE CASCADE
            );
            """
            sqlite3_exec(db, feedbackTableSQL, nil, nil, nil)
            sqlite3_exec(db, "CREATE INDEX IF NOT EXISTS idx_feedback_record_id ON recognition_feedback(record_id);", nil, nil, nil)

            let revisionTableSQL = """
            CREATE TABLE IF NOT EXISTS recognition_revisions (
                id TEXT PRIMARY KEY,
                source_record_id TEXT NOT NULL,
                sequence INTEGER NOT NULL,
                created_at TEXT NOT NULL,
                instruction_text TEXT NOT NULL,
                before_text TEXT NOT NULL,
                after_text TEXT NOT NULL,
                intent TEXT NOT NULL,
                scope_kind TEXT NOT NULL,
                status TEXT NOT NULL,
                undone_at TEXT,
                asr_provider TEXT,
                asr_model TEXT,
                llm_provider TEXT,
                llm_model TEXT,
                asr_duration_seconds REAL,
                llm_duration_seconds REAL,
                validation_trace TEXT,
                user_edited_text TEXT,
                user_edit_status TEXT,
                user_edit_observed_at TEXT,
                user_edit_version INTEGER,
                FOREIGN KEY(source_record_id)
                    REFERENCES recognition_history(id)
                    ON DELETE CASCADE,
                UNIQUE(source_record_id, sequence)
            );
            """
            sqlite3_exec(db, revisionTableSQL, nil, nil, nil)
            sqlite3_exec(db, "CREATE INDEX IF NOT EXISTS idx_revisions_source_sequence ON recognition_revisions(source_record_id, sequence ASC);", nil, nil, nil)

            // Migration: add character_count column if it doesn't exist (for existing databases)
            let alterSQL = "ALTER TABLE recognition_history ADD COLUMN character_count INTEGER;"
            sqlite3_exec(db, alterSQL, nil, nil, nil)

            // Migration: add asr_provider column if it doesn't exist
            let alterASRSQL = "ALTER TABLE recognition_history ADD COLUMN asr_provider TEXT;"
            sqlite3_exec(db, alterASRSQL, nil, nil, nil)

            // Migration: add asr_model column if it doesn't exist
            let alterASRModelSQL = "ALTER TABLE recognition_history ADD COLUMN asr_model TEXT;"
            sqlite3_exec(db, alterASRModelSQL, nil, nil, nil)

            // Versioned privacy-safe metadata for expanded Intelli Sense history details.
            let alterIntelliSenseTraceSQL = "ALTER TABLE recognition_history ADD COLUMN intelli_sense_trace TEXT;"
            sqlite3_exec(db, alterIntelliSenseTraceSQL, nil, nil, nil)

            // Freeze the LLM actually used by this record. These follow the
            // trace column so new and migrated databases keep identical SELECT * indexes.
            let alterLLMProviderSQL = "ALTER TABLE recognition_history ADD COLUMN llm_provider TEXT;"
            sqlite3_exec(db, alterLLMProviderSQL, nil, nil, nil)
            let alterLLMModelSQL = "ALTER TABLE recognition_history ADD COLUMN llm_model TEXT;"
            sqlite3_exec(db, alterLLMModelSQL, nil, nil, nil)

            let alterASRDurationSQL = "ALTER TABLE recognition_history ADD COLUMN asr_duration_seconds REAL;"
            sqlite3_exec(db, alterASRDurationSQL, nil, nil, nil)
            let alterLLMDurationSQL = "ALTER TABLE recognition_history ADD COLUMN llm_duration_seconds REAL;"
            sqlite3_exec(db, alterLLMDurationSQL, nil, nil, nil)

            // User-edit evidence fields are appended in the same order for new
            // and migrated databases because row decoding uses stable indexes.
            sqlite3_exec(db, "ALTER TABLE recognition_history ADD COLUMN user_edited_text TEXT;", nil, nil, nil)
            sqlite3_exec(db, "ALTER TABLE recognition_history ADD COLUMN user_edit_status TEXT;", nil, nil, nil)
            sqlite3_exec(db, "ALTER TABLE recognition_history ADD COLUMN user_edit_observed_at TEXT;", nil, nil, nil)
            sqlite3_exec(db, "ALTER TABLE recognition_history ADD COLUMN user_edit_version INTEGER;", nil, nil, nil)

            // Index for ORDER BY created_at DESC pagination
            sqlite3_exec(db, "CREATE INDEX IF NOT EXISTS idx_history_created_at ON recognition_history(created_at DESC);", nil, nil, nil)
        } else if let db {
            sqlite3_close_v2(db)
            self.db = nil
        }
    }

    deinit {
        if let db {
            sqlite3_close_v2(db)
        }
    }

    // MARK: - CRUD

    func insert(_ record: HistoryRecord) {
        let sql = """
        INSERT OR REPLACE INTO recognition_history
        (id, created_at, duration_seconds, raw_text, processing_mode, processed_text, final_text, status, character_count, asr_provider, asr_model, intelli_sense_trace, llm_provider, llm_model, asr_duration_seconds, llm_duration_seconds, user_edited_text, user_edit_status, user_edit_observed_at, user_edit_version)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        let iso = ISO8601DateFormatter()
        bind(stmt, 1, record.id)
        bind(stmt, 2, iso.string(from: record.createdAt))
        sqlite3_bind_double(stmt, 3, record.durationSeconds)
        bind(stmt, 4, record.rawText)
        bindOptional(stmt, 5, record.processingMode)
        bindOptional(stmt, 6, record.processedText)
        bind(stmt, 7, record.finalText)
        bind(stmt, 8, record.status)
        if let count = record.characterCount {
            sqlite3_bind_int(stmt, 9, Int32(count))
        } else {
            sqlite3_bind_null(stmt, 9)
        }
        bindOptional(stmt, 10, record.asrProvider)
        bindOptional(stmt, 11, record.asrModel)
        bindOptional(stmt, 12, record.intelliSenseTraceJSON)
        bindOptional(stmt, 13, record.llmProvider)
        bindOptional(stmt, 14, record.llmModel)
        bindOptionalDouble(stmt, 15, record.asrDurationSeconds)
        bindOptionalDouble(stmt, 16, record.llmDurationSeconds)
        bindOptional(stmt, 17, record.userEditedText)
        bindOptional(stmt, 18, record.userEditStatus?.rawValue)
        bindOptional(stmt, 19, record.userEditObservedAt.map(iso.string(from:)))
        if let version = record.userEditVersion {
            sqlite3_bind_int(stmt, 20, Int32(version))
        } else {
            sqlite3_bind_null(stmt, 20)
        }
        if sqlite3_step(stmt) == SQLITE_DONE {
            postDidChangeNotification()
        }
    }

    func fetchAll(limit: Int? = nil, offset: Int = 0) -> [HistoryRecord] {
        let sql: String
        if let limit {
            sql = "SELECT * FROM recognition_history ORDER BY created_at DESC LIMIT \(limit) OFFSET \(offset);"
        } else {
            sql = "SELECT * FROM recognition_history ORDER BY created_at DESC;"
        }
        return executeQuery(sql)
    }

    /// Returns the effective final text of the most recent completed record
    /// for the menu-bar recovery action. A later applied Voice Revise result
    /// supersedes the record's original final text; an undone revision does
    /// not. The caller deliberately does not receive a record or any other
    /// history metadata, which keeps the menu snapshot free of dictated
    /// content.
    func latestCopyableFinalText() -> String? {
        let sql = """
        SELECT COALESCE(
            (
                SELECT revision.after_text
                FROM recognition_revisions AS revision
                WHERE revision.source_record_id = history.id
                  AND revision.status = 'applied'
                ORDER BY revision.sequence DESC
                LIMIT 1
            ),
            history.final_text
        )
        FROM recognition_history AS history
        WHERE history.status = 'completed'
          AND TRIM(COALESCE(
              (
                  SELECT revision.after_text
                  FROM recognition_revisions AS revision
                  WHERE revision.source_record_id = history.id
                    AND revision.status = 'applied'
                  ORDER BY revision.sequence DESC
                  LIMIT 1
              ),
              history.final_text
          )) != ''
        ORDER BY history.created_at DESC
        LIMIT 1;
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return column(statement, 0)
    }

    /// Cursor-based pagination with optional date range filter.
    /// Pass `cursor` for subsequent pages, `from`/`to` as ISO8601 strings for date filtering.
    func fetchPage(limit: Int, before cursor: String? = nil, from: String? = nil, to: String? = nil) -> [HistoryRecord] {
        var conditions: [String] = []
        var params: [String] = []
        if let cursor {
            conditions.append("created_at < ?")
            params.append(cursor)
        }
        if let from {
            conditions.append("created_at >= ?")
            params.append(from)
        }
        if let to {
            conditions.append("created_at < ?")
            params.append(to)
        }
        let whereClause = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")
        let sql = "SELECT * FROM recognition_history \(whereClause) ORDER BY created_at DESC LIMIT \(limit);"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        for (i, param) in params.enumerated() {
            bind(stmt, Int32(i + 1), param)
        }
        return readRows(stmt)
    }

    private func executeQuery(_ sql: String) -> [HistoryRecord] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        return readRows(stmt)
    }

    private func readRows(_ stmt: OpaquePointer?) -> [HistoryRecord] {
        let iso = ISO8601DateFormatter()
        var records: [HistoryRecord] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            records.append(HistoryRecord(
                id: column(stmt, 0),
                createdAt: iso.date(from: column(stmt, 1)) ?? Date(),
                durationSeconds: sqlite3_column_double(stmt, 2),
                rawText: column(stmt, 3),
                processingMode: optionalColumn(stmt, 4),
                processedText: optionalColumn(stmt, 5),
                finalText: column(stmt, 6),
                status: column(stmt, 7),
                characterCount: sqlite3_column_type(stmt, 8) == SQLITE_NULL ? nil : Int(sqlite3_column_int(stmt, 8)),
                asrProvider: optionalColumn(stmt, 9),
                asrModel: optionalColumn(stmt, 10),
                llmProvider: optionalColumn(stmt, 12),
                llmModel: optionalColumn(stmt, 13),
                asrDurationSeconds: optionalDoubleColumn(stmt, 14),
                llmDurationSeconds: optionalDoubleColumn(stmt, 15),
                intelliSenseTraceJSON: optionalColumn(stmt, 11),
                userEditedText: optionalColumn(stmt, 16),
                userEditStatus: optionalColumn(stmt, 17).flatMap(UserEditObservationStatus.init(rawValue:)),
                userEditObservedAt: optionalColumn(stmt, 18).flatMap(iso.date(from:)),
                userEditVersion: optionalIntColumn(stmt, 19)
            ))
        }
        return records
    }

    /// Fetch recent records with non-empty rawText for smart correction UI.
    func recentForCorrection(limit: Int = 20) -> [(id: String, date: Date, rawText: String)] {
        let sql = """
        SELECT id, created_at, raw_text FROM recognition_history
        WHERE raw_text != '' AND status = 'completed'
        ORDER BY created_at DESC LIMIT \(limit);
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        let iso = ISO8601DateFormatter()
        var results: [(id: String, date: Date, rawText: String)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            results.append((
                id: column(stmt, 0),
                date: iso.date(from: column(stmt, 1)) ?? Date(),
                rawText: column(stmt, 2)
            ))
        }
        return results
    }

    func fetchUserEditEvidenceRecords(
        version: Int = UserEditObservationFormat.currentVersion
    ) -> [HistoryRecord] {
        let sql = """
        SELECT * FROM recognition_history
        WHERE user_edit_version = ?
          AND user_edit_status IN ('edited', 'clearedAfterEdit')
          AND user_edited_text IS NOT NULL
          AND user_edited_text != ''
          AND final_text != ''
        ORDER BY user_edit_observed_at DESC, created_at DESC;
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(version))
        return readRows(statement)
    }

    func count(from start: Date? = nil, to end: Date? = nil) -> Int {
        let sql: String
        if start != nil && end != nil {
            sql = "SELECT COUNT(*) FROM recognition_history WHERE created_at >= ? AND created_at < ?;"
        } else {
            sql = "SELECT COUNT(*) FROM recognition_history;"
        }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        if let start, let end {
            let iso = ISO8601DateFormatter()
            bind(stmt, 1, iso.string(from: start))
            bind(stmt, 2, iso.string(from: end))
        }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int(stmt, 0)) : 0
    }

    func delete(id: String) {
        let sql = "DELETE FROM recognition_history WHERE id = ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, id)
        if sqlite3_step(stmt) == SQLITE_DONE {
            postDidChangeNotification()
        }
    }

    /// Deletes multiple rows in one transaction; posts a single change notification on success.
    func delete(ids: [String]) {
        guard !ids.isEmpty else { return }
        let chunkSize = 500
        guard sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else { return }
        var ok = true
        for chunkStart in stride(from: 0, to: ids.count, by: chunkSize) {
            let chunk = Array(ids[chunkStart ..< min(chunkStart + chunkSize, ids.count)])
            let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
            let sql = "DELETE FROM recognition_history WHERE id IN (\(placeholders));"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                ok = false
                break
            }
            defer { sqlite3_finalize(stmt) }
            for (idx, id) in chunk.enumerated() {
                bind(stmt, Int32(idx + 1), id)
            }
            if sqlite3_step(stmt) != SQLITE_DONE {
                ok = false
                break
            }
        }
        if ok {
            if sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK {
                postDidChangeNotification()
            } else {
                sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            }
        } else {
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
        }
    }

    func deleteAll() {
        if sqlite3_exec(db, "DELETE FROM recognition_history;", nil, nil, nil) == SQLITE_OK {
            postDidChangeNotification()
        }
    }

    func fetchQualityScores() -> [String: Int] {
        let sql = "SELECT record_id, quality_score FROM recognition_feedback;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [:] }
        defer { sqlite3_finalize(stmt) }

        var scores: [String: Int] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            scores[column(stmt, 0)] = Int(sqlite3_column_int(stmt, 1))
        }
        return scores
    }

    @discardableResult
    func setRecordQualityScore(recordID: String, score: Int) -> Bool {
        let sql = "INSERT OR REPLACE INTO recognition_feedback (record_id, quality_score, marked_at) VALUES (?, ?, ?);"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }

        bind(stmt, 1, recordID)
        sqlite3_bind_int(stmt, 2, Int32(clamping: score))
        bind(stmt, 3, ISO8601DateFormatter().string(from: Date()))
        guard sqlite3_step(stmt) == SQLITE_DONE else { return false }
        postDidChangeNotification()
        return true
    }

    @discardableResult
    func updateUserEditObservation(
        recordID: String,
        text: String?,
        status: UserEditObservationStatus,
        observedAt: Date?,
        version: Int = UserEditObservationFormat.currentVersion
    ) -> Bool {
        let selectSQL = """
        SELECT user_edited_text, user_edit_status, user_edit_observed_at, user_edit_version
        FROM recognition_history WHERE id = ?;
        """
        var selectStatement: OpaquePointer?
        guard sqlite3_prepare_v2(db, selectSQL, -1, &selectStatement, nil) == SQLITE_OK else {
            return false
        }
        defer { sqlite3_finalize(selectStatement) }
        bind(selectStatement, 1, recordID)
        guard sqlite3_step(selectStatement) == SQLITE_ROW else {
            DebugFileLogger.log("user edit observation update skipped: missing history record")
            return false
        }

        let iso = ISO8601DateFormatter()
        let existingText = optionalColumn(selectStatement, 0)
        let existingStatus = optionalColumn(selectStatement, 1)
            .flatMap(UserEditObservationStatus.init(rawValue:))
        let existingObservedAt = optionalColumn(selectStatement, 2).flatMap(iso.date(from:))
        let existingVersion = optionalIntColumn(selectStatement, 3)

        if let existingObservedAt, let observedAt {
            if existingObservedAt > observedAt { return true }
            if existingObservedAt == observedAt,
               (existingStatus?.informationRank ?? -1) > status.informationRank {
                return true
            }
        } else if existingObservedAt != nil, observedAt == nil {
            return true
        }

        if existingText == text,
           existingStatus == status,
           existingObservedAt == observedAt,
           existingVersion == version {
            return true
        }

        let updateSQL = """
        UPDATE recognition_history
        SET user_edited_text = ?, user_edit_status = ?, user_edit_observed_at = ?, user_edit_version = ?
        WHERE id = ?;
        """
        var updateStatement: OpaquePointer?
        guard sqlite3_prepare_v2(db, updateSQL, -1, &updateStatement, nil) == SQLITE_OK else {
            return false
        }
        defer { sqlite3_finalize(updateStatement) }
        bindOptional(updateStatement, 1, text)
        bind(updateStatement, 2, status.rawValue)
        bindOptional(updateStatement, 3, observedAt.map(iso.string(from:)))
        sqlite3_bind_int(updateStatement, 4, Int32(version))
        bind(updateStatement, 5, recordID)
        guard sqlite3_step(updateStatement) == SQLITE_DONE, sqlite3_changes(db) > 0 else {
            return false
        }
        postDidChangeNotification()
        return true
    }

    // MARK: - Migration

    /// 为旧记录计算并保存字数。应在应用启动时调用一次。
    func migrateCharacterCounts() async {
        let sql = """
        SELECT id, final_text FROM recognition_history
        WHERE character_count IS NULL;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        var updates: [(id: String, count: Int)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = column(stmt, 0)
            let text = column(stmt, 1)
            updates.append((id: id, count: text.count))
        }

        guard !updates.isEmpty else { return }

        sqlite3_exec(db, "BEGIN TRANSACTION", nil, nil, nil)
        for update in updates {
            let updateSQL = "UPDATE recognition_history SET character_count = ? WHERE id = ?;"
            var updateStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, updateSQL, -1, &updateStmt, nil) == SQLITE_OK {
                sqlite3_bind_int(updateStmt, 1, Int32(update.count))
                bind(updateStmt, 2, update.id)
                sqlite3_step(updateStmt)
                sqlite3_finalize(updateStmt)
            }
        }
        sqlite3_exec(db, "COMMIT", nil, nil, nil)
        NSLog("[HistoryStore] Migrated %d records with character counts", updates.count)
    }

    // MARK: - Statistics

    /// Effective recognition/activity statuses that represent successful or
    /// delivered user input (including completed dictations, fallbacks, and Mac actions).
    static let activeStatuses: [String] = [
        "completed",
        "stream_recovered",
        "llm_error",
        "translation_error",
        "action_success",
        "action_failed",
        "action_unmatched"
    ]

    static let activeStatusSQLCondition: String =
        "status IN ('completed', 'stream_recovered', 'llm_error', 'translation_error', 'action_success', 'action_failed', 'action_unmatched')"

    struct Statistics: Sendable {
        let totalDuration: Double
        let totalCharacters: Int
        let recordCount: Int

        var averageSpeed: Double {
            guard totalDuration > 0 else { return 0 }
            return Double(totalCharacters) / totalDuration * 60  // 字/分钟
        }
    }

    struct ActivityDay: Equatable, Sendable {
        let dayIdentifier: String
        let recordCount: Int
        let durationSeconds: Double
        let characterCount: Int

        init(
            dayIdentifier: String,
            recordCount: Int,
            durationSeconds: Double = 0,
            characterCount: Int = 0
        ) {
            self.dayIdentifier = dayIdentifier
            self.recordCount = recordCount
            self.durationSeconds = durationSeconds
            self.characterCount = characterCount
        }
    }

    struct UsageBreakdown: Identifiable, Sendable {
        let modelName: String
        let lastDayDuration: Double
        let last7DaysDuration: Double
        let last30DaysDuration: Double
        let allTimeDuration: Double
        let recordCount: Int
        let badCount: Int

        var badPercentage: Double {
            guard recordCount > 0 else { return 0 }
            return Double(badCount) / Double(recordCount)
        }

        var id: String { modelName }
    }

    /// 获取统计信息，可选日期范围过滤（ISO8601 字符串）
    func getStatistics(from: String? = nil, to: String? = nil) async -> Statistics {
        var conditions: [String] = [Self.activeStatusSQLCondition]
        var params: [String] = []
        if let from {
            conditions.append("created_at >= ?")
            params.append(from)
        }
        if let to {
            conditions.append("created_at < ?")
            params.append(to)
        }
        let whereClause = "WHERE " + conditions.joined(separator: " AND ")
        let sql = """
        SELECT
            COALESCE(SUM(CASE WHEN character_count IS NOT NULL THEN duration_seconds ELSE 0 END), 0),
            COALESCE(SUM(character_count), 0),
            COUNT(*)
        FROM recognition_history \(whereClause);
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return Statistics(totalDuration: 0, totalCharacters: 0, recordCount: 0)
        }
        defer { sqlite3_finalize(stmt) }
        for (i, param) in params.enumerated() {
            bind(stmt, Int32(i + 1), param)
        }
        if sqlite3_step(stmt) == SQLITE_ROW {
            let duration = sqlite3_column_double(stmt, 0)
            let chars = Int(sqlite3_column_int(stmt, 1))
            let count = Int(sqlite3_column_int(stmt, 2))
            return Statistics(totalDuration: duration, totalCharacters: chars, recordCount: count)
        }
        return Statistics(totalDuration: 0, totalCharacters: 0, recordCount: 0)
    }

    /// Returns one compact row per local calendar day that contains an active
    /// dictation or action. The dashboard uses this for its heatmap and streak summaries,
    /// avoiding loading dictated text or full history records into memory.
    func getActivityDays() async -> [ActivityDay] {
        let sql = """
        SELECT
            date(created_at, 'localtime') AS local_day,
            COUNT(*),
            COALESCE(SUM(duration_seconds), 0),
            COALESCE(SUM(COALESCE(character_count, 0)), 0)
        FROM recognition_history
        WHERE \(Self.activeStatusSQLCondition)
        GROUP BY local_day
        ORDER BY local_day ASC;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        var days: [ActivityDay] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            days.append(ActivityDay(
                dayIdentifier: column(stmt, 0),
                recordCount: Int(sqlite3_column_int(stmt, 1)),
                durationSeconds: sqlite3_column_double(stmt, 2),
                characterCount: Int(sqlite3_column_int(stmt, 3))
            ))
        }
        return days
    }

    func getUsageBreakdown(now: Date = Date()) async -> [UsageBreakdown] {
        let iso = ISO8601DateFormatter()
        let lastDay = iso.string(from: now.addingTimeInterval(-24 * 60 * 60))
        let last7Days = iso.string(from: now.addingTimeInterval(-7 * 24 * 60 * 60))
        let last30Days = iso.string(from: now.addingTimeInterval(-30 * 24 * 60 * 60))
        let unknown = L("未知", "Unknown")

        let sql = """
        SELECT
            CASE
                -- Older history rows recorded only the provider. These providers
                -- have one supported/default model, so fold those rows into the
                -- same model-qualified bucket as newer rows.
                WHEN lower(trim(COALESCE(asr_provider, ''))) = 'elevenlabs'
                     AND (NULLIF(trim(asr_model), '') IS NULL
                          OR lower(trim(asr_model)) = 'elevenlabs')
                    THEN 'ElevenLabs · scribe_v2_realtime'
                -- Keep provider-only legacy rows separate from rows with a
                -- recorded model; the old model cannot be inferred reliably.
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
        WHERE \(Self.activeStatusSQLCondition)
        GROUP BY 1
        ORDER BY CASE WHEN model_name = ? THEN 1 ELSE 0 END,
                 5 DESC,
                 model_name COLLATE NOCASE ASC;
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

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

    // MARK: - SQLite Helpers

    private func bind(_ stmt: OpaquePointer?, _ index: Int32, _ value: String) {
        sqlite3_bind_text(stmt, index, (value as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }

    private func bindOptional(_ stmt: OpaquePointer?, _ index: Int32, _ value: String?) {
        if let value {
            bind(stmt, index, value)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    private func bindOptionalDouble(_ stmt: OpaquePointer?, _ index: Int32, _ value: Double?) {
        if let value, value.isFinite, value >= 0 {
            sqlite3_bind_double(stmt, index, value)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    private func optionalDoubleColumn(_ stmt: OpaquePointer?, _ index: Int32) -> Double? {
        sqlite3_column_type(stmt, index) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, index)
    }

    private func optionalIntColumn(_ stmt: OpaquePointer?, _ index: Int32) -> Int? {
        sqlite3_column_type(stmt, index) == SQLITE_NULL ? nil : Int(sqlite3_column_int(stmt, index))
    }

    private func column(_ stmt: OpaquePointer?, _ index: Int32) -> String {
        String(cString: sqlite3_column_text(stmt, index))
    }

    private func optionalColumn(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        sqlite3_column_text(stmt, index).map { String(cString: $0) }
    }

    // MARK: - Revisions CRUD

    @discardableResult
    func insertRevision(_ record: RecognitionRevisionRecord) -> Bool {
        guard sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else { return false }

        // Check if parent record exists
        let checkParentSQL = "SELECT 1 FROM recognition_history WHERE id = ?;"
        var checkStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, checkParentSQL, -1, &checkStmt, nil) == SQLITE_OK else {
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            return false
        }
        bind(checkStmt, 1, record.sourceRecordID)
        let parentExists = (sqlite3_step(checkStmt) == SQLITE_ROW)
        sqlite3_finalize(checkStmt)

        guard parentExists else {
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            return false
        }

        // Determine sequence
        var sequence = record.sequence
        if sequence <= 0 {
            let seqSQL = "SELECT COALESCE(MAX(sequence), 0) + 1 FROM recognition_revisions WHERE source_record_id = ?;"
            var seqStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, seqSQL, -1, &seqStmt, nil) == SQLITE_OK {
                bind(seqStmt, 1, record.sourceRecordID)
                if sqlite3_step(seqStmt) == SQLITE_ROW {
                    sequence = Int(sqlite3_column_int(seqStmt, 0))
                }
                sqlite3_finalize(seqStmt)
            }
            if sequence <= 0 { sequence = 1 }
        }

        let insertSQL = """
        INSERT OR REPLACE INTO recognition_revisions
        (id, source_record_id, sequence, created_at, instruction_text, before_text, after_text, intent, scope_kind, status, undone_at, asr_provider, asr_model, llm_provider, llm_model, asr_duration_seconds, llm_duration_seconds, validation_trace, user_edited_text, user_edit_status, user_edit_observed_at, user_edit_version)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, insertSQL, -1, &stmt, nil) == SQLITE_OK else {
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            return false
        }
        defer { sqlite3_finalize(stmt) }

        let iso = ISO8601DateFormatter()
        bind(stmt, 1, record.id)
        bind(stmt, 2, record.sourceRecordID)
        sqlite3_bind_int(stmt, 3, Int32(sequence))
        bind(stmt, 4, iso.string(from: record.createdAt))
        bind(stmt, 5, record.instructionText)
        bind(stmt, 6, record.beforeText)
        bind(stmt, 7, record.afterText)
        bind(stmt, 8, record.intent.rawValue)
        bind(stmt, 9, record.scopeKind.rawValue)
        bind(stmt, 10, record.status)
        bindOptional(stmt, 11, record.undoneAt.map(iso.string(from:)))
        bindOptional(stmt, 12, record.asrProvider)
        bindOptional(stmt, 13, record.asrModel)
        bindOptional(stmt, 14, record.llmProvider)
        bindOptional(stmt, 15, record.llmModel)
        bindOptionalDouble(stmt, 16, record.asrDurationSeconds)
        bindOptionalDouble(stmt, 17, record.llmDurationSeconds)
        bindOptional(stmt, 18, record.validationTraceJSON)
        bindOptional(stmt, 19, record.userEditedText)
        bindOptional(stmt, 20, record.userEditStatus?.rawValue)
        bindOptional(stmt, 21, record.userEditObservedAt.map(iso.string(from:)))
        if let v = record.userEditVersion {
            sqlite3_bind_int(stmt, 22, Int32(v))
        } else {
            sqlite3_bind_null(stmt, 22)
        }

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            return false
        }

        guard sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK else {
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            return false
        }

        postDidChangeNotification()
        return true
    }

    func fetchRevisions(sourceRecordID: String) -> [RecognitionRevisionRecord] {
        let sql = """
        SELECT id, source_record_id, sequence, created_at, instruction_text, before_text, after_text, intent, scope_kind, status, undone_at, asr_provider, asr_model, llm_provider, llm_model, asr_duration_seconds, llm_duration_seconds, validation_trace, user_edited_text, user_edit_status, user_edit_observed_at, user_edit_version
        FROM recognition_revisions
        WHERE source_record_id = ?
        ORDER BY sequence ASC;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, sourceRecordID)

        let iso = ISO8601DateFormatter()
        var results: [RecognitionRevisionRecord] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let intentStr = column(stmt, 7)
            let scopeStr = column(stmt, 8)
            let intent = ReviseIntent(rawValue: intentStr) ?? .rewrite
            let scopeKind = ReviseScopeDescriptor.Kind(rawValue: scopeStr) ?? .whole

            results.append(RecognitionRevisionRecord(
                id: column(stmt, 0),
                sourceRecordID: column(stmt, 1),
                sequence: Int(sqlite3_column_int(stmt, 2)),
                createdAt: iso.date(from: column(stmt, 3)) ?? Date(),
                instructionText: column(stmt, 4),
                beforeText: column(stmt, 5),
                afterText: column(stmt, 6),
                intent: intent,
                scopeKind: scopeKind,
                status: column(stmt, 9),
                undoneAt: optionalColumn(stmt, 10).flatMap(iso.date(from:)),
                asrProvider: optionalColumn(stmt, 11),
                asrModel: optionalColumn(stmt, 12),
                llmProvider: optionalColumn(stmt, 13),
                llmModel: optionalColumn(stmt, 14),
                asrDurationSeconds: optionalDoubleColumn(stmt, 15),
                llmDurationSeconds: optionalDoubleColumn(stmt, 16),
                validationTraceJSON: optionalColumn(stmt, 17),
                userEditedText: optionalColumn(stmt, 18),
                userEditStatus: optionalColumn(stmt, 19).flatMap(UserEditObservationStatus.init(rawValue:)),
                userEditObservedAt: optionalColumn(stmt, 20).flatMap(iso.date(from:)),
                userEditVersion: optionalIntColumn(stmt, 21)
            ))
        }
        return results
    }

    func fetchRevisions(sourceRecordIDs: [String]) -> [String: [RecognitionRevisionRecord]] {
        guard !sourceRecordIDs.isEmpty else { return [:] }
        let placeholders = sourceRecordIDs.map { _ in "?" }.joined(separator: ",")
        let sql = """
        SELECT id, source_record_id, sequence, created_at, instruction_text, before_text, after_text, intent, scope_kind, status, undone_at, asr_provider, asr_model, llm_provider, llm_model, asr_duration_seconds, llm_duration_seconds, validation_trace, user_edited_text, user_edit_status, user_edit_observed_at, user_edit_version
        FROM recognition_revisions
        WHERE source_record_id IN (\(placeholders))
        ORDER BY source_record_id ASC, sequence ASC;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [:] }
        defer { sqlite3_finalize(stmt) }
        for (i, id) in sourceRecordIDs.enumerated() {
            bind(stmt, Int32(i + 1), id)
        }

        let iso = ISO8601DateFormatter()
        var dict: [String: [RecognitionRevisionRecord]] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            let srcID = column(stmt, 1)
            let intent = ReviseIntent(rawValue: column(stmt, 7)) ?? .rewrite
            let scopeKind = ReviseScopeDescriptor.Kind(rawValue: column(stmt, 8)) ?? .whole

            let rev = RecognitionRevisionRecord(
                id: column(stmt, 0),
                sourceRecordID: srcID,
                sequence: Int(sqlite3_column_int(stmt, 2)),
                createdAt: iso.date(from: column(stmt, 3)) ?? Date(),
                instructionText: column(stmt, 4),
                beforeText: column(stmt, 5),
                afterText: column(stmt, 6),
                intent: intent,
                scopeKind: scopeKind,
                status: column(stmt, 9),
                undoneAt: optionalColumn(stmt, 10).flatMap(iso.date(from:)),
                asrProvider: optionalColumn(stmt, 11),
                asrModel: optionalColumn(stmt, 12),
                llmProvider: optionalColumn(stmt, 13),
                llmModel: optionalColumn(stmt, 14),
                asrDurationSeconds: optionalDoubleColumn(stmt, 15),
                llmDurationSeconds: optionalDoubleColumn(stmt, 16),
                validationTraceJSON: optionalColumn(stmt, 17),
                userEditedText: optionalColumn(stmt, 18),
                userEditStatus: optionalColumn(stmt, 19).flatMap(UserEditObservationStatus.init(rawValue:)),
                userEditObservedAt: optionalColumn(stmt, 20).flatMap(iso.date(from:)),
                userEditVersion: optionalIntColumn(stmt, 21)
            )
            dict[srcID, default: []].append(rev)
        }
        return dict
    }

    @discardableResult
    func markRevisionUndone(id: String, at: Date = Date()) -> Bool {
        let sql = "UPDATE recognition_revisions SET status = 'undone', undone_at = ? WHERE id = ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }

        let iso = ISO8601DateFormatter()
        bind(stmt, 1, iso.string(from: at))
        bind(stmt, 2, id)

        if sqlite3_step(stmt) == SQLITE_DONE {
            postDidChangeNotification()
            return true
        }
        return false
    }

    @discardableResult
    func updateRevisionUserEditObservation(
        revisionID: String,
        text: String?,
        status: UserEditObservationStatus,
        observedAt: Date?,
        version: Int = UserEditObservationFormat.currentVersion
    ) -> Bool {
        let sql = """
        UPDATE recognition_revisions
        SET user_edited_text = ?,
            user_edit_status = ?,
            user_edit_observed_at = ?,
            user_edit_version = ?
        WHERE id = ?;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }

        let iso = ISO8601DateFormatter()
        bindOptional(stmt, 1, text)
        bind(stmt, 2, status.rawValue)
        bindOptional(stmt, 3, observedAt.map(iso.string(from:)))
        sqlite3_bind_int(stmt, 4, Int32(version))
        bind(stmt, 5, revisionID)

        if sqlite3_step(stmt) == SQLITE_DONE {
            postDidChangeNotification()
            return true
        }
        return false
    }

    func shrinkMemory() {
        guard let db else { return }
        sqlite3_db_release_memory(db)
    }

    private func postDidChangeNotification() {
        Task { @MainActor in
            NotificationCenter.default.post(name: .historyStoreDidChange, object: nil)
        }
    }
}

struct RecognitionRevisionRecord: Identifiable, Hashable, Sendable {
    let id: String
    let sourceRecordID: String
    let sequence: Int
    let createdAt: Date
    let instructionText: String
    let beforeText: String
    let afterText: String
    let intent: ReviseIntent
    let scopeKind: ReviseScopeDescriptor.Kind
    let status: String
    let undoneAt: Date?
    let asrProvider: String?
    let asrModel: String?
    let llmProvider: String?
    let llmModel: String?
    let asrDurationSeconds: Double?
    let llmDurationSeconds: Double?
    let validationTraceJSON: String?
    let userEditedText: String?
    let userEditStatus: UserEditObservationStatus?
    let userEditObservedAt: Date?
    let userEditVersion: Int?

    init(
        id: String = UUID().uuidString,
        sourceRecordID: String,
        sequence: Int = 0,
        createdAt: Date = Date(),
        instructionText: String,
        beforeText: String,
        afterText: String,
        intent: ReviseIntent,
        scopeKind: ReviseScopeDescriptor.Kind,
        status: String = "applied",
        undoneAt: Date? = nil,
        asrProvider: String? = nil,
        asrModel: String? = nil,
        llmProvider: String? = nil,
        llmModel: String? = nil,
        asrDurationSeconds: Double? = nil,
        llmDurationSeconds: Double? = nil,
        validationTraceJSON: String? = nil,
        userEditedText: String? = nil,
        userEditStatus: UserEditObservationStatus? = nil,
        userEditObservedAt: Date? = nil,
        userEditVersion: Int? = nil
    ) {
        self.id = id
        self.sourceRecordID = sourceRecordID
        self.sequence = sequence
        self.createdAt = createdAt
        self.instructionText = instructionText
        self.beforeText = beforeText
        self.afterText = afterText
        self.intent = intent
        self.scopeKind = scopeKind
        self.status = status
        self.undoneAt = undoneAt
        self.asrProvider = asrProvider
        self.asrModel = asrModel
        self.llmProvider = llmProvider
        self.llmModel = llmModel
        self.asrDurationSeconds = asrDurationSeconds
        self.llmDurationSeconds = llmDurationSeconds
        self.validationTraceJSON = validationTraceJSON
        self.userEditedText = userEditedText
        self.userEditStatus = userEditStatus
        self.userEditObservedAt = userEditObservedAt
        self.userEditVersion = userEditVersion
    }
}
