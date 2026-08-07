import XCTest
import SQLite3
@testable import Type4Me

final class HistoryStoreTests: XCTestCase {

    private var store: HistoryStore!
    private var testPath: String!

    override func setUp() async throws {
        testPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("type4me-test-\(UUID().uuidString).db").path
        store = HistoryStore(path: testPath)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(atPath: testPath)
    }

    func testInsertAndFetchAll() async {
        let record = HistoryRecord(
            id: UUID().uuidString, createdAt: Date(), durationSeconds: 3.5,
            rawText: "测试文本", processingMode: nil, processedText: nil,
            finalText: "测试文本", status: "completed", characterCount: 4, asrProvider: nil
        )
        await store.insert(record)
        let all = await store.fetchAll()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.rawText, "测试文本")
        XCTAssertEqual(all.first?.durationSeconds ?? 0, 3.5, accuracy: 0.01)
        XCTAssertEqual(all.first?.characterCount, 4)
    }

    func testInsertWithProcessedText() async {
        let record = HistoryRecord(
            id: UUID().uuidString, createdAt: Date(), durationSeconds: 2.0,
            rawText: "原始文本", processingMode: "润色",
            processedText: "润色后的文本", finalText: "润色后的文本", status: "completed",
            characterCount: 6, asrProvider: nil
        )
        await store.insert(record)
        let all = await store.fetchAll()
        XCTAssertEqual(all.first?.processingMode, "润色")
        XCTAssertEqual(all.first?.processedText, "润色后的文本")
        XCTAssertEqual(all.first?.characterCount, 6)
    }

    func testIntelliSenseTracePersistsAndLegacyRowsRemainCompatible() async {
        let legacyPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("type4me-legacy-history-\(UUID().uuidString).db").path
        defer { try? FileManager.default.removeItem(atPath: legacyPath) }
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(legacyPath, &db), SQLITE_OK)
        let createLegacyTable = """
        CREATE TABLE recognition_history (
            id TEXT PRIMARY KEY, created_at TEXT NOT NULL, duration_seconds REAL,
            raw_text TEXT NOT NULL, processing_mode TEXT, processed_text TEXT,
            final_text TEXT NOT NULL, status TEXT NOT NULL, character_count INTEGER,
            asr_provider TEXT, asr_model TEXT
        );
        """
        XCTAssertEqual(sqlite3_exec(db, createLegacyTable, nil, nil, nil), SQLITE_OK)
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let insertLegacy = """
        INSERT INTO recognition_history VALUES
        ('legacy', '\(timestamp)', 1, '旧记录', '智能感知', '旧记录', '旧记录', 'completed', 3, 'Volcano', NULL);
        """
        XCTAssertEqual(sqlite3_exec(db, insertLegacy, nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)

        let migratedStore = HistoryStore(path: legacyPath)
        let legacy = await migratedStore.fetchAll()
        XCTAssertEqual(legacy.first?.id, "legacy")
        XCTAssertNil(legacy.first?.intelliSenseTraceJSON)
        XCTAssertNil(legacy.first?.llmProvider)
        XCTAssertNil(legacy.first?.llmModel)
        XCTAssertNil(legacy.first?.asrDurationSeconds)
        XCTAssertNil(legacy.first?.llmDurationSeconds)

        let traceJSON = #"{"version":1,"scene":"search"}"#
        await migratedStore.insert(HistoryRecord(
            id: "new", createdAt: Date(), durationSeconds: 1,
            rawText: "帮我查天气", processingMode: "智能感知", processedText: "天气",
            finalText: "天气", status: "completed", characterCount: 2,
            asrProvider: "Volcano", llmProvider: "deepseek", llmModel: "deepseek-v4-flash",
            asrDurationSeconds: 0.62, llmDurationSeconds: 0.81,
            intelliSenseTraceJSON: traceJSON
        ))
        let fetched = await migratedStore.fetchAll()
        let newRecord = fetched.first(where: { $0.id == "new" })
        XCTAssertEqual(newRecord?.intelliSenseTraceJSON, traceJSON)
        XCTAssertEqual(newRecord?.llmProvider, "deepseek")
        XCTAssertEqual(newRecord?.llmModel, "deepseek-v4-flash")
        XCTAssertEqual(newRecord?.asrDurationSeconds ?? 0, 0.62, accuracy: 0.001)
        XCTAssertEqual(newRecord?.llmDurationSeconds ?? 0, 0.81, accuracy: 0.001)
    }

    func testDelete() async {
        let id = UUID().uuidString
        let record = HistoryRecord(
            id: id, createdAt: Date(), durationSeconds: 1.0,
            rawText: "to delete", processingMode: nil, processedText: nil,
            finalText: "to delete", status: "completed", characterCount: 9, asrProvider: nil
        )
        await store.insert(record)
        await store.delete(id: id)
        let all = await store.fetchAll()
        XCTAssertTrue(all.isEmpty)
    }

    func testFetchAllOrderedByDate() async {
        let old = HistoryRecord(
            id: "1", createdAt: Date(timeIntervalSinceNow: -100), durationSeconds: 1,
            rawText: "old", processingMode: nil, processedText: nil,
            finalText: "old", status: "completed", characterCount: 3, asrProvider: nil
        )
        let recent = HistoryRecord(
            id: "2", createdAt: Date(), durationSeconds: 1,
            rawText: "recent", processingMode: nil, processedText: nil,
            finalText: "recent", status: "completed", characterCount: 6, asrProvider: nil
        )
        await store.insert(old)
        await store.insert(recent)
        let all = await store.fetchAll()
        XCTAssertEqual(all.first?.rawText, "recent")
        XCTAssertEqual(all.last?.rawText, "old")
    }

    func testDeleteAll() async {
        for i in 0..<3 {
            await store.insert(HistoryRecord(
                id: "\(i)", createdAt: Date(), durationSeconds: 1,
                rawText: "text\(i)", processingMode: nil, processedText: nil,
                finalText: "text\(i)", status: "completed", characterCount: 5 + i, asrProvider: nil
            ))
        }
        await store.deleteAll()
        let all = await store.fetchAll()
        XCTAssertTrue(all.isEmpty)
    }

    func testDeleteBatchEmptyDoesNothing() async {
        let id = "only-one"
        await store.insert(HistoryRecord(
            id: id, createdAt: Date(), durationSeconds: 1,
            rawText: "x", processingMode: nil, processedText: nil,
            finalText: "x", status: "completed", characterCount: 1, asrProvider: nil
        ))
        await store.delete(ids: [])
        let all = await store.fetchAll()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.id, id)
    }

    func testDeleteBatch() async {
        for i in 0..<5 {
            await store.insert(HistoryRecord(
                id: "batch-\(i)", createdAt: Date(), durationSeconds: 1,
                rawText: "t\(i)", processingMode: nil, processedText: nil,
                finalText: "t\(i)", status: "completed", characterCount: 2, asrProvider: nil
            ))
        }
        await store.delete(ids: ["batch-0", "batch-2", "batch-4"])
        let all = await store.fetchAll()
        XCTAssertEqual(all.count, 2)
        let ids = Set(all.map(\.id))
        XCTAssertEqual(ids, Set(["batch-1", "batch-3"]))
    }

    func testDeleteBatchPostsSingleNotification() async {
        await store.insert(HistoryRecord(
            id: "a", createdAt: Date(), durationSeconds: 1,
            rawText: "a", processingMode: nil, processedText: nil,
            finalText: "a", status: "completed", characterCount: 1, asrProvider: nil
        ))
        await store.insert(HistoryRecord(
            id: "b", createdAt: Date(), durationSeconds: 1,
            rawText: "b", processingMode: nil, processedText: nil,
            finalText: "b", status: "completed", characterCount: 1, asrProvider: nil
        ))

        let batchNote = expectation(forNotification: .historyStoreDidChange, object: nil)
        await store.delete(ids: ["a", "b"])
        await fulfillment(of: [batchNote], timeout: 1.0)

        let remaining = await store.fetchAll()
        XCTAssertTrue(remaining.isEmpty)
    }

    func testInsertPostsHistoryDidChangeNotification() async {
        let notification = expectation(forNotification: .historyStoreDidChange, object: nil)
        let record = HistoryRecord(
            id: UUID().uuidString, createdAt: Date(), durationSeconds: 1.2,
            rawText: "notify", processingMode: "智能模式", processedText: "notify",
            finalText: "notify", status: "completed", characterCount: 6, asrProvider: nil
        )

        await store.insert(record)

        await fulfillment(of: [notification], timeout: 1.0)
    }

    func testUserEditObservationPersistsAndUsesDataFormatVersion() async {
        let recordID = "user-edit"
        await store.insert(HistoryRecord(
            id: recordID, createdAt: Date(), durationSeconds: 1,
            rawText: "ghosty", processingMode: "智能感知", processedText: "ghosty",
            finalText: "ghosty", status: "completed", characterCount: 6, asrProvider: nil
        ))
        let observedAt = Date(timeIntervalSince1970: 1_800_000_000)

        let updated = await store.updateUserEditObservation(
            recordID: recordID,
            text: "Ghostty",
            status: .edited,
            observedAt: observedAt
        )

        XCTAssertTrue(updated)
        let fetched = await store.fetchAll().first
        XCTAssertEqual(fetched?.userEditedText, "Ghostty")
        XCTAssertEqual(fetched?.userEditStatus, .edited)
        XCTAssertEqual(fetched?.userEditObservedAt, observedAt)
        XCTAssertEqual(fetched?.userEditVersion, UserEditObservationFormat.currentVersion)
    }

    func testOlderOrLowerInformationObservationCannotOverwriteReliableEdit() async {
        let recordID = "ordered-user-edit"
        await store.insert(HistoryRecord(
            id: recordID, createdAt: Date(), durationSeconds: 1,
            rawText: "ghosty", processingMode: "智能感知", processedText: "ghosty",
            finalText: "ghosty", status: "completed", characterCount: 6, asrProvider: nil
        ))
        let observedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let initialUpdate = await store.updateUserEditObservation(
            recordID: recordID,
            text: "Ghostty",
            status: .edited,
            observedAt: observedAt
        )
        let equalTimeLowerQualityUpdate = await store.updateUserEditObservation(
            recordID: recordID,
            text: nil,
            status: .ambiguous,
            observedAt: observedAt
        )
        let olderUpdate = await store.updateUserEditObservation(
            recordID: recordID,
            text: nil,
            status: .unavailable,
            observedAt: observedAt.addingTimeInterval(-1)
        )

        XCTAssertTrue(initialUpdate)
        XCTAssertTrue(equalTimeLowerQualityUpdate)
        XCTAssertTrue(olderUpdate)

        let fetched = await store.fetchAll().first
        XCTAssertEqual(fetched?.userEditedText, "Ghostty")
        XCTAssertEqual(fetched?.userEditStatus, .edited)
    }

    func testUserEditObservationDoesNotCreateOrphanHistoryRow() async {
        let updated = await store.updateUserEditObservation(
            recordID: "missing",
            text: "Ghostty",
            status: .edited,
            observedAt: Date()
        )

        XCTAssertFalse(updated)
        let fetched = await store.fetchAll()
        XCTAssertTrue(fetched.isEmpty)
    }

    func testUsageBreakdownGroupsByProviderAndPeriods() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let records: [HistoryRecord] = [
            HistoryRecord(
                id: "soniox-now", createdAt: now.addingTimeInterval(-60), durationSeconds: 30,
                rawText: "a", processingMode: nil, processedText: nil,
                finalText: "a", status: "completed", characterCount: 1, asrProvider: "Soniox",
                asrModel: "Soniox · stt-rt-v5"
            ),
            HistoryRecord(
                id: "soniox-week", createdAt: now.addingTimeInterval(-3 * 24 * 60 * 60), durationSeconds: 90,
                rawText: "b", processingMode: nil, processedText: nil,
                finalText: "b", status: "completed", characterCount: 1, asrProvider: "Soniox",
                asrModel: "Soniox · stt-rt-v5"
            ),
            HistoryRecord(
                id: "openai-month", createdAt: now.addingTimeInterval(-10 * 24 * 60 * 60), durationSeconds: 120,
                rawText: "c", processingMode: nil, processedText: nil,
                finalText: "c", status: "completed", characterCount: 1, asrProvider: "OpenAI"
            ),
            HistoryRecord(
                id: "old", createdAt: now.addingTimeInterval(-40 * 24 * 60 * 60), durationSeconds: 300,
                rawText: "d", processingMode: nil, processedText: nil,
                finalText: "d", status: "completed", characterCount: 1, asrProvider: "Old"
            ),
            HistoryRecord(
                id: "elevenlabs-scribe", createdAt: now.addingTimeInterval(-2 * 24 * 60 * 60), durationSeconds: 45,
                rawText: "e", processingMode: nil, processedText: nil,
                finalText: "e", status: "completed", characterCount: 1, asrProvider: "ElevenLabs",
                asrModel: "ElevenLabs · scribe_v2_realtime"
            ),
            HistoryRecord(
                id: "elevenlabs-default", createdAt: now.addingTimeInterval(-40 * 24 * 60 * 60), durationSeconds: 75,
                rawText: "f", processingMode: nil, processedText: nil,
                finalText: "f", status: "completed", characterCount: 1, asrProvider: "ElevenLabs",
                asrModel: "ElevenLabs"
            ),
            HistoryRecord(
                id: "deepgram-provider", createdAt: now.addingTimeInterval(-2 * 24 * 60 * 60), durationSeconds: 40,
                rawText: "dg", processingMode: nil, processedText: nil,
                finalText: "dg", status: "completed", characterCount: 1, asrProvider: "Deepgram",
                asrModel: nil
            ),
            HistoryRecord(
                id: "deepgram-model", createdAt: now.addingTimeInterval(-40 * 24 * 60 * 60), durationSeconds: 20,
                rawText: "dg2", processingMode: nil, processedText: nil,
                finalText: "dg2", status: "completed", characterCount: 1, asrProvider: nil,
                asrModel: "Deepgram · nova-3"
            ),
            HistoryRecord(
                id: "unknown", createdAt: now.addingTimeInterval(-60), durationSeconds: 60,
                rawText: "g", processingMode: nil, processedText: nil,
                finalText: "g", status: "completed", characterCount: 1, asrProvider: nil
            )
        ]

        for record in records {
            await store.insert(record)
        }

        let rows = await store.getUsageBreakdown(now: now)
        let byModel = Dictionary(uniqueKeysWithValues: rows.map { ($0.modelName, $0) })

        XCTAssertEqual(byModel["Soniox · stt-rt-v5"]?.lastDayDuration ?? 0, 30, accuracy: 0.01)
        XCTAssertEqual(byModel["Soniox · stt-rt-v5"]?.last7DaysDuration ?? 0, 120, accuracy: 0.01)
        XCTAssertEqual(byModel["Soniox · stt-rt-v5"]?.last30DaysDuration ?? 0, 120, accuracy: 0.01)
        XCTAssertEqual(byModel["Soniox · stt-rt-v5"]?.allTimeDuration ?? 0, 120, accuracy: 0.01)
        XCTAssertEqual(byModel["OpenAI"]?.lastDayDuration ?? 0, 0, accuracy: 0.01)
        XCTAssertEqual(byModel["OpenAI"]?.last7DaysDuration ?? 0, 0, accuracy: 0.01)
        XCTAssertEqual(byModel["OpenAI"]?.last30DaysDuration ?? 0, 120, accuracy: 0.01)
        XCTAssertEqual(byModel["OpenAI"]?.allTimeDuration ?? 0, 120, accuracy: 0.01)
        XCTAssertEqual(byModel["Old"]?.last30DaysDuration ?? 0, 0, accuracy: 0.01)
        XCTAssertEqual(byModel["Old"]?.allTimeDuration ?? 0, 300, accuracy: 0.01)
        XCTAssertEqual(rows.filter { $0.modelName == "ElevenLabs" }.count, 1)
        XCTAssertEqual(byModel["ElevenLabs"]?.recordCount, 2)
        XCTAssertEqual(byModel["ElevenLabs"]?.last30DaysDuration ?? 0, 45, accuracy: 0.01)
        XCTAssertEqual(byModel["ElevenLabs"]?.allTimeDuration ?? 0, 120, accuracy: 0.01)
        XCTAssertEqual(rows.filter { $0.modelName == "Deepgram" }.count, 1)
        XCTAssertEqual(rows.filter { $0.modelName == "Deepgram · nova-3" }.count, 0)
        XCTAssertEqual(byModel["Deepgram"]?.recordCount, 2)
        XCTAssertEqual(byModel["Deepgram"]?.last30DaysDuration ?? 0, 40, accuracy: 0.01)
        XCTAssertEqual(byModel["Deepgram"]?.allTimeDuration ?? 0, 60, accuracy: 0.01)
        XCTAssertEqual(rows.last?.modelName, L("未知", "Unknown"))
        XCTAssertEqual(rows.dropLast().map(\.allTimeDuration), rows.dropLast().map(\.allTimeDuration).sorted(by: >))
    }

    func testShrinkMemoryDoesNotThrowOrCorrupt() async {
        let record = HistoryRecord(
            id: UUID().uuidString, createdAt: Date(), durationSeconds: 1.0,
            rawText: "shrink test", processingMode: nil, processedText: nil,
            finalText: "shrink test", status: "completed", characterCount: 11, asrProvider: nil
        )
        await store.insert(record)
        await store.shrinkMemory()
        let fetched = await store.fetchAll()
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched.first?.rawText, "shrink test")
    }
}
