import Foundation
import SQLite3

extension Notification.Name {
    static let historyStoreDidChange = Notification.Name("Type4Me.historyStoreDidChange")
}

actor HistoryStore {

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
                character_count INTEGER
            );
            """
            sqlite3_exec(db, sql, nil, nil, nil)

            // Migration: add character_count column if it doesn't exist (for existing databases)
            let alterSQL = "ALTER TABLE recognition_history ADD COLUMN character_count INTEGER;"
            sqlite3_exec(db, alterSQL, nil, nil, nil)
        }
    }

    // MARK: - CRUD

    func insert(_ record: HistoryRecord) {
        let sql = """
        INSERT OR REPLACE INTO recognition_history
        (id, created_at, duration_seconds, raw_text, processing_mode, processed_text, final_text, status, character_count)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
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
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

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
                characterCount: sqlite3_column_type(stmt, 8) == SQLITE_NULL ? nil : Int(sqlite3_column_int(stmt, 8))
            ))
        }
        return records
    }

    func count(from start: Date? = nil, to end: Date? = nil) -> Int {
        var sql = "SELECT COUNT(*) FROM recognition_history"
        let iso = ISO8601DateFormatter()
        if let start, let end {
            sql += " WHERE created_at >= '\(iso.string(from: start))' AND created_at < '\(iso.string(from: end))'"
        }
        sql += ";"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
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

    func deleteAll() {
        if sqlite3_exec(db, "DELETE FROM recognition_history;", nil, nil, nil) == SQLITE_OK {
            postDidChangeNotification()
        }
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

    struct Statistics: Sendable {
        let totalDuration: Double
        let totalCharacters: Int
        let recordCount: Int

        var averageSpeed: Double {
            guard totalDuration > 0 else { return 0 }
            return Double(totalCharacters) / totalDuration * 60  // 字/分钟
        }
    }

    /// 获取全部记录的统计信息（使用数据库聚合查询，高效）
    func getStatistics() async -> Statistics {
        // Only sum duration for rows that have character_count, so averageSpeed
        // is accurate even if some legacy rows haven't been migrated yet.
        let sql = """
        SELECT
            COALESCE(SUM(CASE WHEN character_count IS NOT NULL THEN duration_seconds ELSE 0 END), 0),
            COALESCE(SUM(character_count), 0),
            COUNT(*)
        FROM recognition_history;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return Statistics(totalDuration: 0, totalCharacters: 0, recordCount: 0)
        }
        defer { sqlite3_finalize(stmt) }

        if sqlite3_step(stmt) == SQLITE_ROW {
            let duration = sqlite3_column_double(stmt, 0)
            let chars = Int(sqlite3_column_int(stmt, 1))
            let count = Int(sqlite3_column_int(stmt, 2))
            return Statistics(totalDuration: duration, totalCharacters: chars, recordCount: count)
        }
        return Statistics(totalDuration: 0, totalCharacters: 0, recordCount: 0)
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

    private func column(_ stmt: OpaquePointer?, _ index: Int32) -> String {
        String(cString: sqlite3_column_text(stmt, index))
    }

    private func optionalColumn(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        sqlite3_column_text(stmt, index).map { String(cString: $0) }
    }

    private func postDidChangeNotification() {
        Task { @MainActor in
            NotificationCenter.default.post(name: .historyStoreDidChange, object: nil)
        }
    }
}
