import XCTest
import SQLite3
@testable import Type4Me

/// #300 review. Replacement provenance is stored in two columns appended to
/// `recognition_history`. Dev and production share one profile, so the change has
/// to stay readable and writable by builds that predate it. Every test uses its
/// own temporary database, never `HistoryStore.shared`.
final class HistorySnippetProvenanceTests: XCTestCase {

    private var directory: URL!

    /// The columns as they were before this change, in order. Rows are decoded by
    /// position, so these indexes must never move.
    private let previousColumns = [
        "id", "created_at", "duration_seconds", "raw_text", "processing_mode",
        "processed_text", "final_text", "status", "character_count", "asr_provider",
        "asr_model", "intelli_sense_trace", "llm_provider", "llm_model",
        "asr_duration_seconds", "llm_duration_seconds", "user_edited_text",
        "user_edit_status", "user_edit_observed_at", "user_edit_version",
    ]

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("t4m-provenance-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Helpers

    private func databasePath() -> String {
        directory.appendingPathComponent("history-\(UUID().uuidString).db").path
    }

    private func record(
        id: String = UUID().uuidString,
        raw: String = "把 Doc 发我",
        final: String = "把 Docker 发我",
        postSnippetText: String? = nil,
        appliedSnippets: [AppliedSnippetRule]? = nil
    ) -> HistoryRecord {
        HistoryRecord(
            id: id,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            durationSeconds: 1.5,
            rawText: raw,
            processingMode: nil,
            processedText: nil,
            finalText: final,
            status: "completed",
            characterCount: final.count,
            asrProvider: "test",
            postSnippetText: postSnippetText,
            appliedSnippets: appliedSnippets
        )
    }

    private func withDatabase(at path: String, _ body: (OpaquePointer?) throws -> Void) rethrows {
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &handle), SQLITE_OK)
        defer { sqlite3_close(handle) }
        try body(handle)
    }

    private func exec(_ handle: OpaquePointer?, _ sql: String) {
        var error: UnsafeMutablePointer<CChar>?
        let status = sqlite3_exec(handle, sql, nil, nil, &error)
        XCTAssertEqual(status, SQLITE_OK, error.map { String(cString: $0) } ?? sql)
        sqlite3_free(error)
    }

    private func columnNames(at path: String) -> [String] {
        var names: [String] = []
        withDatabase(at: path) { handle in
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(handle, "PRAGMA table_info(recognition_history);", -1, &stmt, nil) == SQLITE_OK
            else { return }
            defer { sqlite3_finalize(stmt) }
            while sqlite3_step(stmt) == SQLITE_ROW {
                names.append(String(cString: sqlite3_column_text(stmt, 1)))
            }
        }
        return names
    }

    /// Creates a database exactly as a build without provenance would have.
    private func makePreviousSchemaDatabase(at path: String) {
        withDatabase(at: path) { handle in
            exec(handle, """
            CREATE TABLE recognition_history (
                id TEXT PRIMARY KEY, created_at TEXT NOT NULL, duration_seconds REAL,
                raw_text TEXT NOT NULL, processing_mode TEXT, processed_text TEXT,
                final_text TEXT NOT NULL, status TEXT NOT NULL, character_count INTEGER,
                asr_provider TEXT, asr_model TEXT, intelli_sense_trace TEXT,
                llm_provider TEXT, llm_model TEXT, asr_duration_seconds REAL,
                llm_duration_seconds REAL, user_edited_text TEXT, user_edit_status TEXT,
                user_edit_observed_at TEXT, user_edit_version INTEGER
            );
            """)
            exec(handle, previousBuildInsert(id: "old-row", raw: "旧记录", final: "旧记录"))
        }
    }

    /// The INSERT a build without provenance issues, with its explicit column list.
    private func previousBuildInsert(id: String, raw: String, final: String) -> String {
        """
        INSERT OR REPLACE INTO recognition_history
        (\(previousColumns.joined(separator: ", ")))
        VALUES ('\(id)', '2023-11-14T22:13:20Z', 1.0, '\(raw)', NULL, NULL, '\(final)', 'completed',
                \(final.count), 'test', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL);
        """
    }

    // MARK: - Round trip

    func testProvenanceRoundTripsIncludingAppScope() async {
        let store = HistoryStore(path: databasePath())
        let rules = [
            AppliedSnippetRule(trigger: "Doc", value: "Docker", bundleId: nil),
            AppliedSnippetRule(trigger: "PR", value: "Pull Request", bundleId: "com.example.editor"),
        ]
        await store.insert(record(id: "a", postSnippetText: "把 Docker 发我", appliedSnippets: rules))

        let fetched = await store.fetchAll().first { $0.id == "a" }
        XCTAssertEqual(fetched?.postSnippetText, "把 Docker 发我")
        XCTAssertEqual(fetched?.appliedSnippets, rules)
    }

    /// `[]` means no rule fired; `nil` means not recorded. They must not collapse.
    func testNoRulesFiredIsStoredDistinctlyFromNotRecorded() async {
        let store = HistoryStore(path: databasePath())
        await store.insert(record(id: "none-fired", raw: "文本", final: "文本", postSnippetText: "文本", appliedSnippets: []))
        await store.insert(record(id: "not-recorded", raw: "文本", final: "文本"))

        let rows = await store.fetchAll()
        XCTAssertEqual(rows.first { $0.id == "none-fired" }?.appliedSnippets, [])
        XCTAssertNil(rows.first { $0.id == "not-recorded" }?.appliedSnippets)
        XCTAssertNil(rows.first { $0.id == "not-recorded" }?.postSnippetText)
    }

    // MARK: - Compatibility with builds that predate provenance

    func testNewAndMigratedDatabasesKeepEveryExistingColumnIndex() async {
        let freshPath = databasePath()
        _ = HistoryStore(path: freshPath)

        let migratedPath = databasePath()
        makePreviousSchemaDatabase(at: migratedPath)
        _ = HistoryStore(path: migratedPath)

        let expected = previousColumns + ["post_snippet_text", "applied_snippets"]
        XCTAssertEqual(columnNames(at: freshPath), expected)
        XCTAssertEqual(columnNames(at: migratedPath), expected, "migration must append in the same order as a fresh schema")
    }

    func testRowsFromBeforeProvenanceReadAsUnknownAfterMigration() async {
        let path = databasePath()
        makePreviousSchemaDatabase(at: path)
        let store = HistoryStore(path: path)

        let old = await store.fetchAll().first { $0.id == "old-row" }
        XCTAssertEqual(old?.rawText, "旧记录")
        XCTAssertNil(old?.appliedSnippets)
        XCTAssertNil(old?.postSnippetText)

        let rule = AppliedSnippetRule(trigger: "Doc", value: "Docker", bundleId: nil)
        await store.insert(record(id: "new-row", postSnippetText: "把 Docker 发我", appliedSnippets: [rule]))
        let new = await store.fetchAll().first { $0.id == "new-row" }
        XCTAssertEqual(new?.appliedSnippets, [rule])
    }

    /// A build that predates provenance still writes with its own column list.
    /// Those rows must read back intact, with provenance simply unknown.
    func testRowsWrittenByAPreviousBuildReadBackIntactWithUnknownProvenance() async {
        let path = databasePath()
        let store = HistoryStore(path: path)
        withDatabase(at: path) { handle in
            exec(handle, previousBuildInsert(id: "from-old-build", raw: "旧版本写入", final: "旧版本写入"))
        }

        let row = await store.fetchAll().first { $0.id == "from-old-build" }
        XCTAssertEqual(row?.rawText, "旧版本写入")
        XCTAssertEqual(row?.finalText, "旧版本写入")
        XCTAssertEqual(row?.status, "completed")
        XCTAssertNil(row?.appliedSnippets)
    }

    /// What an older reader sees on a database this build has written: the first
    /// twenty columns decode by position exactly as before.
    func testAPositionalReaderOfTheOldColumnsStillReadsNewRowsCorrectly() async {
        let path = databasePath()
        let store = HistoryStore(path: path)
        await store.insert(record(
            id: "new-row", raw: "把 Doc 发我", final: "把 Docker 发我",
            postSnippetText: "把 Docker 发我",
            appliedSnippets: [AppliedSnippetRule(trigger: "Doc", value: "Docker", bundleId: nil)]
        ))

        withDatabase(at: path) { handle in
            var stmt: OpaquePointer?
            XCTAssertEqual(sqlite3_prepare_v2(handle, "SELECT * FROM recognition_history WHERE id = 'new-row';", -1, &stmt, nil), SQLITE_OK)
            defer { sqlite3_finalize(stmt) }
            XCTAssertEqual(sqlite3_step(stmt), SQLITE_ROW)
            XCTAssertEqual(String(cString: sqlite3_column_text(stmt, 0)), "new-row")
            XCTAssertEqual(String(cString: sqlite3_column_text(stmt, 3)), "把 Doc 发我")
            XCTAssertEqual(String(cString: sqlite3_column_text(stmt, 6)), "把 Docker 发我")
            XCTAssertEqual(String(cString: sqlite3_column_text(stmt, 7)), "completed")
        }
    }

    // MARK: - Encoding

    func testUnknownOrMalformedProvenanceIsTreatedAsNotRecorded() {
        XCTAssertNil(HistoryStore.decodeAppliedSnippets(nil))
        XCTAssertNil(HistoryStore.decodeAppliedSnippets("not json"))
        XCTAssertNil(HistoryStore.decodeAppliedSnippets(#"{"version":2,"rules":[]}"#), "a newer format must not be misread")
        XCTAssertNil(HistoryStore.encodeAppliedSnippets(nil))
        XCTAssertEqual(HistoryStore.decodeAppliedSnippets(HistoryStore.encodeAppliedSnippets([])), [])
    }
}
