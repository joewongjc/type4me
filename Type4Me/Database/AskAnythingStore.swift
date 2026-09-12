import Foundation
import SQLite3

extension Notification.Name {
    static let askAnythingStoreDidChange = Notification.Name("Type4Me.askAnythingStoreDidChange")
}

struct AskAnythingSession: Identifiable, Equatable, Sendable {
    enum Status: String, Codable, Sendable {
        case active
        case answering
        case failed
    }

    let id: UUID
    var title: String
    var usesCustomTitle: Bool
    var sourceText: String
    var createdAt: Date
    var updatedAt: Date
    var status: Status
}

struct AskAnythingTurn: Identifiable, Equatable, Sendable {
    enum Status: String, Codable, Sendable {
        case pending
        case streaming
        case completed
        case failed
        case interrupted
    }

    let id: UUID
    let sessionID: UUID
    let ordinal: Int
    var question: String
    var answer: String
    var status: Status
    var errorMessage: String?
    var createdAt: Date
    var updatedAt: Date
    var completedAt: Date?
}

struct AskAnythingConversation: Equatable, Sendable {
    var session: AskAnythingSession
    var turns: [AskAnythingTurn]
}

struct AskAnythingSessionSummary: Identifiable, Equatable, Sendable {
    let id: UUID
    var title: String
    var sourceText: String
    var createdAt: Date
    var updatedAt: Date
    var status: AskAnythingSession.Status
    var lastAnswerPreview: String
    var turnCount: Int
}

struct AskAnythingSessionCursor: Equatable, Sendable {
    let updatedAt: Date
    let id: UUID
}

enum AskAnythingStoreError: LocalizedError, Equatable {
    case openFailed(String)
    case prepareFailed(String)
    case executeFailed(String)
    case invalidRecord

    var errorDescription: String? {
        switch self {
        case .openFailed(let message): return "Unable to open Ask Anything history: \(message)"
        case .prepareFailed(let message): return "Unable to prepare Ask Anything query: \(message)"
        case .executeFailed(let message): return "Unable to update Ask Anything history: \(message)"
        case .invalidRecord: return "Ask Anything history contains an invalid record."
        }
    }
}

actor AskAnythingStore {
    private var db: OpaquePointer?
    private var initializationError: AskAnythingStoreError?

    init(path: String? = nil) {
        let dbPath: String
        if let path {
            dbPath = path
        } else {
            let appSupport = AppDataLocation.directory
            try? FileManager.default.createDirectory(
                at: appSupport,
                withIntermediateDirectories: true
            )
            dbPath = appSupport.appendingPathComponent("ask-anything.db").path
        }

        guard sqlite3_open(dbPath, &db) == SQLITE_OK else {
            initializationError = .openFailed(Self.errorMessage(db))
            sqlite3_close(db)
            db = nil
            return
        }

        do {
            try Self.execute(db, sql: "PRAGMA foreign_keys = ON;")
            _ = try? Self.execute(db, sql: "PRAGMA journal_mode = WAL;")
            try Self.execute(db, sql: "PRAGMA cache_size = -2000;")
            try Self.execute(db, sql: "PRAGMA temp_store = MEMORY;")
            try Self.execute(db, sql: "PRAGMA mmap_size = 2097152;")
            try Self.migrate(db)
        } catch let error as AskAnythingStoreError {
            initializationError = error
        } catch {
            initializationError = .executeFailed(error.localizedDescription)
        }
    }

    deinit {
        sqlite3_close(db)
    }

    func shrinkMemory() {
        guard let db else { return }
        sqlite3_db_release_memory(db)
    }

    func createConversation(
        session: AskAnythingSession,
        firstTurn: AskAnythingTurn
    ) throws {
        try requireReady()
        guard firstTurn.sessionID == session.id, firstTurn.ordinal == 1 else {
            throw AskAnythingStoreError.invalidRecord
        }

        try transaction {
            let sessionSQL = """
            INSERT INTO ask_sessions
            (id, title, uses_custom_title, source_text, status, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?);
            """
            let sessionStatement = try prepare(sessionSQL)
            defer { sqlite3_finalize(sessionStatement) }
            bind(session.id.uuidString, to: sessionStatement, at: 1)
            bind(session.title, to: sessionStatement, at: 2)
            sqlite3_bind_int(sessionStatement, 3, session.usesCustomTitle ? 1 : 0)
            bind(session.sourceText, to: sessionStatement, at: 4)
            bind(session.status.rawValue, to: sessionStatement, at: 5)
            bind(Self.dateString(session.createdAt), to: sessionStatement, at: 6)
            bind(Self.dateString(session.updatedAt), to: sessionStatement, at: 7)
            try stepDone(sessionStatement)

            try insertTurn(firstTurn)
        }
        postDidChange()
    }

    func appendTurn(_ turn: AskAnythingTurn) throws {
        try requireReady()
        try transaction {
            try insertTurn(turn)
            try touchSession(
                id: turn.sessionID,
                status: .answering,
                updatedAt: turn.updatedAt
            )
        }
        postDidChange()
    }

    func updateTurnAnswer(
        id: UUID,
        answer: String,
        status: AskAnythingTurn.Status,
        errorMessage: String?,
        updatedAt: Date = Date(),
        notify: Bool = true
    ) throws {
        try requireReady()
        let sessionID = try sessionID(forTurn: id)
        let completedAt: Date? = switch status {
        case .completed, .failed, .interrupted: updatedAt
        case .pending, .streaming: nil
        }
        let sessionStatus: AskAnythingSession.Status = switch status {
        case .pending, .streaming: .answering
        case .completed, .interrupted: .active
        case .failed: .failed
        }

        try transaction {
            let sql = """
            UPDATE ask_turns
            SET answer = ?, status = ?, error_message = ?, updated_at = ?, completed_at = ?
            WHERE id = ?;
            """
            let statement = try prepare(sql)
            defer { sqlite3_finalize(statement) }
            bind(answer, to: statement, at: 1)
            bind(status.rawValue, to: statement, at: 2)
            bindOptional(errorMessage, to: statement, at: 3)
            bind(Self.dateString(updatedAt), to: statement, at: 4)
            bindOptional(completedAt.map(Self.dateString), to: statement, at: 5)
            bind(id.uuidString, to: statement, at: 6)
            try stepDone(statement)
            guard sqlite3_changes(db) == 1 else {
                throw AskAnythingStoreError.invalidRecord
            }
            try touchSession(id: sessionID, status: sessionStatus, updatedAt: updatedAt)
        }
        if notify { postDidChange() }
    }

    func fetchConversation(id: UUID) throws -> AskAnythingConversation? {
        try requireReady()
        guard let session = try fetchSession(id: id) else { return nil }
        let sql = """
        SELECT id, session_id, ordinal, question, answer, status, error_message,
               created_at, updated_at, completed_at
        FROM ask_turns
        WHERE session_id = ?
        ORDER BY ordinal ASC;
        """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        bind(id.uuidString, to: statement, at: 1)
        var turns: [AskAnythingTurn] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let turn = readTurn(statement) else {
                throw AskAnythingStoreError.invalidRecord
            }
            turns.append(turn)
        }
        return AskAnythingConversation(session: session, turns: turns)
    }

    func fetchSessions(
        pageSize: Int,
        before cursor: AskAnythingSessionCursor? = nil
    ) throws -> [AskAnythingSessionSummary] {
        try requireReady()
        let boundedSize = max(1, min(pageSize, 200))
        let condition = cursor == nil
            ? ""
            : "WHERE s.updated_at < ? OR (s.updated_at = ? AND s.id < ?)"
        let sql = """
        SELECT s.id, s.title, s.source_text, s.created_at, s.updated_at, s.status,
               COALESCE((
                   SELECT t.answer FROM ask_turns t
                   WHERE t.session_id = s.id
                   ORDER BY t.ordinal DESC LIMIT 1
               ), ''),
               (SELECT COUNT(*) FROM ask_turns t WHERE t.session_id = s.id)
        FROM ask_sessions s
        \(condition)
        ORDER BY s.updated_at DESC, s.id DESC
        LIMIT ?;
        """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        var index: Int32 = 1
        if let cursor {
            let date = Self.dateString(cursor.updatedAt)
            bind(date, to: statement, at: index); index += 1
            bind(date, to: statement, at: index); index += 1
            bind(cursor.id.uuidString, to: statement, at: index); index += 1
        }
        sqlite3_bind_int(statement, index, Int32(boundedSize))
        return try readSummaries(statement)
    }

    func searchSessions(query: String, limit: Int = 100) throws -> [AskAnythingSessionSummary] {
        try requireReady()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return try fetchSessions(pageSize: limit)
        }
        let pattern = "%\(Self.escapeLike(trimmed))%"
        let sql = """
        SELECT s.id, s.title, s.source_text, s.created_at, s.updated_at, s.status,
               COALESCE((
                   SELECT latest.answer FROM ask_turns latest
                   WHERE latest.session_id = s.id
                   ORDER BY latest.ordinal DESC LIMIT 1
               ), ''),
               (SELECT COUNT(*) FROM ask_turns count_turn WHERE count_turn.session_id = s.id)
        FROM ask_sessions s
        WHERE s.title LIKE ? ESCAPE '\\'
           OR s.source_text LIKE ? ESCAPE '\\'
           OR EXISTS (
               SELECT 1 FROM ask_turns matched
               WHERE matched.session_id = s.id
                 AND (matched.question LIKE ? ESCAPE '\\' OR matched.answer LIKE ? ESCAPE '\\')
           )
        ORDER BY s.updated_at DESC, s.id DESC
        LIMIT ?;
        """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        for index in 1...4 {
            bind(pattern, to: statement, at: Int32(index))
        }
        sqlite3_bind_int(statement, 5, Int32(max(1, min(limit, 500))))
        return try readSummaries(statement)
    }

    func renameSession(id: UUID, title: String, updatedAt: Date = Date()) throws {
        try requireReady()
        let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { throw AskAnythingStoreError.invalidRecord }
        let sql = """
        UPDATE ask_sessions
        SET title = ?, uses_custom_title = 1, updated_at = ?
        WHERE id = ?;
        """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        bind(normalized, to: statement, at: 1)
        bind(Self.dateString(updatedAt), to: statement, at: 2)
        bind(id.uuidString, to: statement, at: 3)
        try stepDone(statement)
        guard sqlite3_changes(db) == 1 else { throw AskAnythingStoreError.invalidRecord }
        postDidChange()
    }

    func deleteSession(id: UUID) throws {
        try requireReady()
        let statement = try prepare("DELETE FROM ask_sessions WHERE id = ?;")
        defer { sqlite3_finalize(statement) }
        bind(id.uuidString, to: statement, at: 1)
        try stepDone(statement)
        guard sqlite3_changes(db) == 1 else { throw AskAnythingStoreError.invalidRecord }
        postDidChange()
    }

    func deleteAll() throws {
        try requireReady()
        try Self.execute(db, sql: "DELETE FROM ask_sessions;")
        postDidChange()
    }

    func markUnfinishedTurnsInterrupted(at date: Date = Date()) throws {
        try requireReady()
        let timestamp = Self.dateString(date)
        try transaction {
            let sql = """
            UPDATE ask_turns
            SET status = 'interrupted', updated_at = ?, completed_at = ?
            WHERE status IN ('pending', 'streaming');
            """
            let statement = try prepare(sql)
            defer { sqlite3_finalize(statement) }
            bind(timestamp, to: statement, at: 1)
            bind(timestamp, to: statement, at: 2)
            try stepDone(statement)

            try Self.execute(db, sql: """
            UPDATE ask_sessions
            SET status = 'active'
            WHERE status = 'answering';
            """)
        }
        postDidChange()
    }

    // MARK: - Schema

    private static func migrate(_ db: OpaquePointer?) throws {
        let version = try scalarInt(db, sql: "PRAGMA user_version;")
        guard version <= 1 else {
            throw AskAnythingStoreError.executeFailed("Unsupported schema version \(version)")
        }
        guard version == 0 else { return }
        try execute(db, sql: "BEGIN IMMEDIATE;")
        do {
            try execute(db, sql: """
            CREATE TABLE IF NOT EXISTS ask_sessions (
                id TEXT PRIMARY KEY,
                title TEXT NOT NULL,
                uses_custom_title INTEGER NOT NULL DEFAULT 0,
                source_text TEXT NOT NULL DEFAULT '',
                status TEXT NOT NULL,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL
            );
            """)
            try execute(db, sql: """
            CREATE TABLE IF NOT EXISTS ask_turns (
                id TEXT PRIMARY KEY,
                session_id TEXT NOT NULL,
                ordinal INTEGER NOT NULL,
                question TEXT NOT NULL,
                answer TEXT NOT NULL DEFAULT '',
                status TEXT NOT NULL,
                error_message TEXT,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL,
                completed_at TEXT,
                FOREIGN KEY(session_id) REFERENCES ask_sessions(id) ON DELETE CASCADE,
                UNIQUE(session_id, ordinal)
            );
            """)
            try execute(db, sql: """
            CREATE INDEX IF NOT EXISTS idx_ask_sessions_updated
            ON ask_sessions(updated_at DESC, id DESC);
            """)
            try execute(db, sql: """
            CREATE INDEX IF NOT EXISTS idx_ask_turns_session_ordinal
            ON ask_turns(session_id, ordinal ASC);
            """)
            try execute(db, sql: "PRAGMA user_version = 1;")
            try execute(db, sql: "COMMIT;")
        } catch {
            try? execute(db, sql: "ROLLBACK;")
            throw error
        }
    }

    // MARK: - Queries

    private func fetchSession(id: UUID) throws -> AskAnythingSession? {
        let sql = """
        SELECT id, title, uses_custom_title, source_text, status, created_at, updated_at
        FROM ask_sessions WHERE id = ?;
        """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        bind(id.uuidString, to: statement, at: 1)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return readSession(statement)
    }

    private func readSession(_ statement: OpaquePointer?) -> AskAnythingSession? {
        guard
            let id = UUID(uuidString: column(statement, 0)),
            let status = AskAnythingSession.Status(rawValue: column(statement, 4)),
            let createdAt = Self.date(column(statement, 5)),
            let updatedAt = Self.date(column(statement, 6))
        else { return nil }
        return AskAnythingSession(
            id: id,
            title: column(statement, 1),
            usesCustomTitle: sqlite3_column_int(statement, 2) != 0,
            sourceText: column(statement, 3),
            createdAt: createdAt,
            updatedAt: updatedAt,
            status: status
        )
    }

    private func readTurn(_ statement: OpaquePointer?) -> AskAnythingTurn? {
        guard
            let id = UUID(uuidString: column(statement, 0)),
            let sessionID = UUID(uuidString: column(statement, 1)),
            let status = AskAnythingTurn.Status(rawValue: column(statement, 5)),
            let createdAt = Self.date(column(statement, 7)),
            let updatedAt = Self.date(column(statement, 8))
        else { return nil }
        return AskAnythingTurn(
            id: id,
            sessionID: sessionID,
            ordinal: Int(sqlite3_column_int(statement, 2)),
            question: column(statement, 3),
            answer: column(statement, 4),
            status: status,
            errorMessage: optionalColumn(statement, 6),
            createdAt: createdAt,
            updatedAt: updatedAt,
            completedAt: optionalColumn(statement, 9).flatMap(Self.date)
        )
    }

    private func readSummaries(_ statement: OpaquePointer?) throws -> [AskAnythingSessionSummary] {
        var summaries: [AskAnythingSessionSummary] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard
                let id = UUID(uuidString: column(statement, 0)),
                let createdAt = Self.date(column(statement, 3)),
                let updatedAt = Self.date(column(statement, 4)),
                let status = AskAnythingSession.Status(rawValue: column(statement, 5))
            else { throw AskAnythingStoreError.invalidRecord }
            summaries.append(AskAnythingSessionSummary(
                id: id,
                title: column(statement, 1),
                sourceText: column(statement, 2),
                createdAt: createdAt,
                updatedAt: updatedAt,
                status: status,
                lastAnswerPreview: column(statement, 6),
                turnCount: Int(sqlite3_column_int(statement, 7))
            ))
        }
        return summaries
    }

    private func insertTurn(_ turn: AskAnythingTurn) throws {
        let sql = """
        INSERT INTO ask_turns
        (id, session_id, ordinal, question, answer, status, error_message,
         created_at, updated_at, completed_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        bind(turn.id.uuidString, to: statement, at: 1)
        bind(turn.sessionID.uuidString, to: statement, at: 2)
        sqlite3_bind_int(statement, 3, Int32(turn.ordinal))
        bind(turn.question, to: statement, at: 4)
        bind(turn.answer, to: statement, at: 5)
        bind(turn.status.rawValue, to: statement, at: 6)
        bindOptional(turn.errorMessage, to: statement, at: 7)
        bind(Self.dateString(turn.createdAt), to: statement, at: 8)
        bind(Self.dateString(turn.updatedAt), to: statement, at: 9)
        bindOptional(turn.completedAt.map(Self.dateString), to: statement, at: 10)
        try stepDone(statement)
    }

    private func touchSession(
        id: UUID,
        status: AskAnythingSession.Status,
        updatedAt: Date
    ) throws {
        let statement = try prepare(
            "UPDATE ask_sessions SET status = ?, updated_at = ? WHERE id = ?;"
        )
        defer { sqlite3_finalize(statement) }
        bind(status.rawValue, to: statement, at: 1)
        bind(Self.dateString(updatedAt), to: statement, at: 2)
        bind(id.uuidString, to: statement, at: 3)
        try stepDone(statement)
        guard sqlite3_changes(db) == 1 else { throw AskAnythingStoreError.invalidRecord }
    }

    private func sessionID(forTurn id: UUID) throws -> UUID {
        let statement = try prepare("SELECT session_id FROM ask_turns WHERE id = ?;")
        defer { sqlite3_finalize(statement) }
        bind(id.uuidString, to: statement, at: 1)
        guard
            sqlite3_step(statement) == SQLITE_ROW,
            let id = UUID(uuidString: column(statement, 0))
        else { throw AskAnythingStoreError.invalidRecord }
        return id
    }

    // MARK: - SQLite helpers

    private func requireReady() throws {
        if let initializationError { throw initializationError }
        guard db != nil else { throw AskAnythingStoreError.openFailed("No database handle") }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw AskAnythingStoreError.prepareFailed(Self.errorMessage(db))
        }
        return statement
    }

    private func stepDone(_ statement: OpaquePointer?) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw AskAnythingStoreError.executeFailed(Self.errorMessage(db))
        }
    }

    private func transaction(_ operation: () throws -> Void) throws {
        try Self.execute(db, sql: "BEGIN IMMEDIATE;")
        do {
            try operation()
            try Self.execute(db, sql: "COMMIT;")
        } catch {
            try? Self.execute(db, sql: "ROLLBACK;")
            throw error
        }
    }

    private func bind(_ value: String, to statement: OpaquePointer?, at index: Int32) {
        sqlite3_bind_text(statement, index, value, -1, Self.sqliteTransient)
    }

    private func bindOptional(_ value: String?, to statement: OpaquePointer?, at index: Int32) {
        if let value {
            bind(value, to: statement, at: index)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    private func column(_ statement: OpaquePointer?, _ index: Int32) -> String {
        guard let text = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: text)
    }

    private func optionalColumn(_ statement: OpaquePointer?, _ index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return column(statement, index)
    }

    private static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private static func execute(_ db: OpaquePointer?, sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &message) == SQLITE_OK else {
            let text = message.map { String(cString: $0) } ?? errorMessage(db)
            sqlite3_free(message)
            throw AskAnythingStoreError.executeFailed(text)
        }
    }

    private static func scalarInt(_ db: OpaquePointer?, sql: String) throws -> Int {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw AskAnythingStoreError.prepareFailed(errorMessage(db))
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw AskAnythingStoreError.executeFailed(errorMessage(db))
        }
        return Int(sqlite3_column_int(statement, 0))
    }

    private static func errorMessage(_ db: OpaquePointer?) -> String {
        db.flatMap { sqlite3_errmsg($0) }.map(String.init(cString:)) ?? "Unknown SQLite error"
    }

    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static func dateString(_ date: Date) -> String {
        formatter.string(from: date)
    }

    private static func date(_ value: String) -> Date? {
        formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    private static func escapeLike(_ query: String) -> String {
        query
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    private func postDidChange() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .askAnythingStoreDidChange, object: nil)
        }
    }
}
