import Darwin
import SQLite3
import XCTest
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
        store = nil
        try? FileManager.default.removeItem(atPath: testPath)
    }

    func testTemporaryStoresCloseDatabaseDescriptorOnDeinit() {
        let baseline = openDescriptorCount(for: testPath)

        for _ in 0..<20 {
            autoreleasepool {
                let temporaryStore = HistoryStore(path: testPath)
                withExtendedLifetime(temporaryStore) {}
            }
        }

        XCTAssertEqual(openDescriptorCount(for: testPath), baseline)
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

    func testLatestCopyableFinalTextUsesNewestCompletedNonEmptyRecord() async {
        await store.insert(HistoryRecord(
            id: "old-completed", createdAt: Date(timeIntervalSinceNow: -10), durationSeconds: 1,
            rawText: "old", processingMode: nil, processedText: nil,
            finalText: "old final", status: "completed", characterCount: 9, asrProvider: nil
        ))
        await store.insert(HistoryRecord(
            id: "new-cancelled", createdAt: Date(), durationSeconds: 1,
            rawText: "cancelled", processingMode: nil, processedText: nil,
            finalText: "must not copy", status: "cancelled", characterCount: 13, asrProvider: nil
        ))
        await store.insert(HistoryRecord(
            id: "new-empty", createdAt: Date(timeIntervalSinceNow: 1), durationSeconds: 1,
            rawText: "empty", processingMode: nil, processedText: nil,
            finalText: "   ", status: "completed", characterCount: 0, asrProvider: nil
        ))

        let latest = await store.latestCopyableFinalText()
        XCTAssertEqual(latest, "old final")
    }

    func testLatestCopyableFinalTextUsesLatestAppliedRevision() async {
        await store.insert(HistoryRecord(
            id: "revised", createdAt: Date(), durationSeconds: 1,
            rawText: "original", processingMode: nil, processedText: nil,
            finalText: "original final", status: "completed", characterCount: 14, asrProvider: nil
        ))
        let inserted = await store.insertRevision(RecognitionRevisionRecord(
            sourceRecordID: "revised",
            instructionText: "rewrite it",
            beforeText: "original final",
            afterText: "revised final",
            intent: .rewrite,
            scopeKind: .whole
        ))
        XCTAssertTrue(inserted)

        let latest = await store.latestCopyableFinalText()

        XCTAssertEqual(latest, "revised final")
    }

    func testLatestCopyableFinalTextFallsBackThroughUndoneRevisions() async {
        await store.insert(HistoryRecord(
            id: "revised", createdAt: Date(), durationSeconds: 1,
            rawText: "original", processingMode: nil, processedText: nil,
            finalText: "original final", status: "completed", characterCount: 14, asrProvider: nil
        ))
        let first = RecognitionRevisionRecord(
            id: "revision-1",
            sourceRecordID: "revised",
            instructionText: "first rewrite",
            beforeText: "original final",
            afterText: "first revised final",
            intent: .rewrite,
            scopeKind: .whole
        )
        let second = RecognitionRevisionRecord(
            id: "revision-2",
            sourceRecordID: "revised",
            instructionText: "second rewrite",
            beforeText: "first revised final",
            afterText: "second revised final",
            intent: .rewrite,
            scopeKind: .whole
        )
        let insertedFirst = await store.insertRevision(first)
        let insertedSecond = await store.insertRevision(second)
        XCTAssertTrue(insertedFirst)
        XCTAssertTrue(insertedSecond)

        let undidSecond = await store.markRevisionUndone(id: second.id)
        XCTAssertTrue(undidSecond)
        let afterSecondUndo = await store.latestCopyableFinalText()
        XCTAssertEqual(afterSecondUndo, "first revised final")

        let undidFirst = await store.markRevisionUndone(id: first.id)
        XCTAssertTrue(undidFirst)
        let afterFirstUndo = await store.latestCopyableFinalText()
        XCTAssertEqual(afterFirstUndo, "original final")
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

    func testBadFeedbackIsStoredSeparatelyFromHistoryRecord() async {
        let record = HistoryRecord(
            id: "feedback-record", createdAt: Date(), durationSeconds: 1,
            rawText: "feedback", processingMode: nil, processedText: nil,
            finalText: "feedback", status: "completed", characterCount: 8,
            asrProvider: "Deepgram", asrModel: "Deepgram · nova-3"
        )
        await store.insert(record)

        let marked = await store.setRecordQualityScore(recordID: record.id, score: -1)
        let markedScores = await store.fetchQualityScores()
        let fetched = await store.fetchAll()
        XCTAssertTrue(marked)
        XCTAssertEqual(markedScores[record.id], -1)
        XCTAssertEqual(fetched.first?.finalText, record.finalText)

        let unmarked = await store.setRecordQualityScore(recordID: record.id, score: 0)
        let neutralScores = await store.fetchQualityScores()
        XCTAssertTrue(unmarked)
        XCTAssertEqual(neutralScores[record.id], 0)

        let futureNegativeScore = await store.setRecordQualityScore(recordID: record.id, score: -3)
        let futureNegativeScores = await store.fetchQualityScores()
        XCTAssertTrue(futureNegativeScore)
        XCTAssertEqual(futureNegativeScores[record.id], -3)

        let futurePositiveScore = await store.setRecordQualityScore(recordID: record.id, score: 2)
        let futurePositiveScores = await store.fetchQualityScores()
        XCTAssertTrue(futurePositiveScore)
        XCTAssertEqual(futurePositiveScores[record.id], 2)
    }

    func testLegacyFeedbackTableMigratesToIntegerScore() async {
        let legacyPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("type4me-legacy-feedback-\(UUID().uuidString).db").path
        defer { try? FileManager.default.removeItem(atPath: legacyPath) }

        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(legacyPath, &db), SQLITE_OK)
        let createLegacyTable = """
        CREATE TABLE recognition_feedback (
            record_id TEXT PRIMARY KEY,
            marked_at TEXT NOT NULL
        );
        """
        XCTAssertEqual(sqlite3_exec(db, createLegacyTable, nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)

        let migratedStore = HistoryStore(path: legacyPath)
        let record = HistoryRecord(
            id: "legacy-feedback-record", createdAt: Date(), durationSeconds: 1,
            rawText: "legacy feedback", processingMode: nil, processedText: nil,
            finalText: "legacy feedback", status: "completed", characterCount: 15,
            asrProvider: "Deepgram", asrModel: "nova-3"
        )
        await migratedStore.insert(record)
        let marked = await migratedStore.setRecordQualityScore(recordID: record.id, score: -1)

        XCTAssertTrue(marked)
        let scores = await migratedStore.fetchQualityScores()
        XCTAssertEqual(scores[record.id], -1)
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
        let markedSoniox = await store.setRecordQualityScore(recordID: "soniox-now", score: -1)
        let markedDeepgram = await store.setRecordQualityScore(recordID: "deepgram-model", score: -1)
        XCTAssertTrue(markedSoniox)
        XCTAssertTrue(markedDeepgram)

        let rows = await store.getUsageBreakdown(now: now)
        let byModel = Dictionary(uniqueKeysWithValues: rows.map { ($0.modelName, $0) })

        XCTAssertEqual(byModel["Soniox · stt-rt-v5"]?.lastDayDuration ?? 0, 30, accuracy: 0.01)
        XCTAssertEqual(byModel["Soniox · stt-rt-v5"]?.last7DaysDuration ?? 0, 120, accuracy: 0.01)
        XCTAssertEqual(byModel["Soniox · stt-rt-v5"]?.last30DaysDuration ?? 0, 120, accuracy: 0.01)
        XCTAssertEqual(byModel["Soniox · stt-rt-v5"]?.allTimeDuration ?? 0, 120, accuracy: 0.01)
        XCTAssertEqual(byModel["Soniox · stt-rt-v5"]?.badCount, 1)
        XCTAssertEqual(byModel["Soniox · stt-rt-v5"]?.badPercentage ?? 0, 0.5, accuracy: 0.01)
        XCTAssertEqual(byModel["OpenAI"]?.lastDayDuration ?? 0, 0, accuracy: 0.01)
        XCTAssertEqual(byModel["OpenAI"]?.last7DaysDuration ?? 0, 0, accuracy: 0.01)
        XCTAssertEqual(byModel["OpenAI"]?.last30DaysDuration ?? 0, 120, accuracy: 0.01)
        XCTAssertEqual(byModel["OpenAI"]?.allTimeDuration ?? 0, 120, accuracy: 0.01)
        XCTAssertEqual(byModel["Old"]?.last30DaysDuration ?? 0, 0, accuracy: 0.01)
        XCTAssertEqual(byModel["Old"]?.allTimeDuration ?? 0, 300, accuracy: 0.01)
        XCTAssertEqual(byModel["ElevenLabs · scribe_v2_realtime"]?.recordCount, 2)
        XCTAssertEqual(byModel["ElevenLabs · scribe_v2_realtime"]?.last30DaysDuration ?? 0, 45, accuracy: 0.01)
        XCTAssertEqual(byModel["ElevenLabs · scribe_v2_realtime"]?.allTimeDuration ?? 0, 120, accuracy: 0.01)
        XCTAssertEqual(rows.filter { $0.modelName == "ElevenLabs" }.count, 0)
        XCTAssertEqual(byModel["Deepgram"]?.recordCount, 1)
        XCTAssertEqual(byModel["Deepgram"]?.last30DaysDuration ?? 0, 40, accuracy: 0.01)
        XCTAssertEqual(byModel["Deepgram"]?.allTimeDuration ?? 0, 40, accuracy: 0.01)
        XCTAssertEqual(byModel["Deepgram · nova-3"]?.recordCount, 1)
        XCTAssertEqual(byModel["Deepgram · nova-3"]?.last30DaysDuration ?? 0, 0, accuracy: 0.01)
        XCTAssertEqual(byModel["Deepgram · nova-3"]?.allTimeDuration ?? 0, 20, accuracy: 0.01)
        XCTAssertEqual(byModel["Deepgram · nova-3"]?.badCount, 1)
        XCTAssertEqual(byModel["Deepgram · nova-3"]?.badPercentage ?? 0, 1.0, accuracy: 0.01)
        XCTAssertEqual(rows.last?.modelName, L("未知", "Unknown"))
        XCTAssertEqual(rows.dropLast().map(\.allTimeDuration), rows.dropLast().map(\.allTimeDuration).sorted(by: >))
    }

    func testActivityDaysGroupsCompletedRecordsByLocalCalendarDay() async {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let today = calendar.startOfDay(for: Date())
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!

        await store.insert(HistoryRecord(
            id: "today-1", createdAt: today.addingTimeInterval(60), durationSeconds: 1,
            rawText: "a", processingMode: nil, processedText: nil,
            finalText: "a", status: "completed", characterCount: 1, asrProvider: nil
        ))
        await store.insert(HistoryRecord(
            id: "today-2", createdAt: today.addingTimeInterval(120), durationSeconds: 1,
            rawText: "b", processingMode: nil, processedText: nil,
            finalText: "b", status: "action_success", characterCount: 2, asrProvider: nil
        ))
        await store.insert(HistoryRecord(
            id: "yesterday", createdAt: yesterday.addingTimeInterval(60), durationSeconds: 3,
            rawText: "c", processingMode: nil, processedText: nil,
            finalText: "c", status: "stream_recovered", characterCount: 5, asrProvider: nil
        ))
        await store.insert(HistoryRecord(
            id: "cancelled", createdAt: today.addingTimeInterval(180), durationSeconds: 10,
            rawText: "d", processingMode: nil, processedText: nil,
            finalText: "d", status: "cancelled", characterCount: 10, asrProvider: nil
        ))
        await store.insert(HistoryRecord(
            id: "cancelled-processed", createdAt: today.addingTimeInterval(200), durationSeconds: 10,
            rawText: "e", processingMode: nil, processedText: nil,
            finalText: "e", status: "cancelled_processed", characterCount: 10, asrProvider: nil
        ))

        let rows = await store.getActivityDays()
        let byDay = Dictionary(uniqueKeysWithValues: rows.map { ($0.dayIdentifier, $0.recordCount) })
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"

        XCTAssertEqual(byDay[formatter.string(from: today)], 2)
        XCTAssertEqual(byDay[formatter.string(from: yesterday)], 1)
        let todayRow = rows.first { $0.dayIdentifier == formatter.string(from: today) }
        XCTAssertEqual(todayRow?.durationSeconds ?? 0, 2, accuracy: 0.01)
        XCTAssertEqual(todayRow?.characterCount, 3)
        XCTAssertEqual(rows.count, 2)
    }

    func testStatisticsFiltersByActiveStatusesAndDateRange() async {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let today = calendar.startOfDay(for: Date())
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!

        await store.insert(HistoryRecord(
            id: "stat-1", createdAt: today.addingTimeInterval(10), durationSeconds: 30,
            rawText: "hello", processingMode: nil, processedText: nil,
            finalText: "hello", status: "completed", characterCount: 5, asrProvider: nil
        ))
        await store.insert(HistoryRecord(
            id: "stat-2", createdAt: today.addingTimeInterval(20), durationSeconds: 30,
            rawText: "action", processingMode: nil, processedText: nil,
            finalText: "action", status: "action_success", characterCount: 6, asrProvider: nil
        ))
        await store.insert(HistoryRecord(
            id: "stat-3", createdAt: yesterday.addingTimeInterval(10), durationSeconds: 60,
            rawText: "yesterday", processingMode: nil, processedText: nil,
            finalText: "yesterday", status: "llm_error", characterCount: 9, asrProvider: nil
        ))
        await store.insert(HistoryRecord(
            id: "stat-cancelled", createdAt: today.addingTimeInterval(30), durationSeconds: 100,
            rawText: "cancel", processingMode: nil, processedText: nil,
            finalText: "cancel", status: "cancelled_unprocessed", characterCount: 6, asrProvider: nil
        ))

        let allStats = await store.getStatistics()
        XCTAssertEqual(allStats.recordCount, 3)
        XCTAssertEqual(allStats.totalDuration, 120, accuracy: 0.01)
        XCTAssertEqual(allStats.totalCharacters, 20)
        XCTAssertEqual(allStats.averageSpeed, 10, accuracy: 0.01)

        let iso = ISO8601DateFormatter()
        let todayStats = await store.getStatistics(from: iso.string(from: today))
        XCTAssertEqual(todayStats.recordCount, 2)
        XCTAssertEqual(todayStats.totalDuration, 60, accuracy: 0.01)
        XCTAssertEqual(todayStats.totalCharacters, 11)
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

    private func openDescriptorCount(for path: String) -> Int {
        let resolvedPath = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        let pid = getpid()
        let descriptorInfoSize = MemoryLayout<proc_fdinfo>.stride
        let requiredBytes = Int(proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0))
        guard requiredBytes > 0 else { return 0 }

        var descriptors = [proc_fdinfo](
            repeating: proc_fdinfo(),
            count: requiredBytes / descriptorInfoSize
        )
        let usedBytes = descriptors.withUnsafeMutableBytes {
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count))
        }
        guard usedBytes > 0 else { return 0 }

        let pathInfoSize = Int32(MemoryLayout<vnode_fdinfowithpath>.stride)
        return descriptors.prefix(Int(usedBytes) / descriptorInfoSize).reduce(into: 0) { count, descriptor in
            var pathInfo = vnode_fdinfowithpath()
            guard proc_pidfdinfo(
                pid,
                descriptor.proc_fd,
                PROC_PIDFDVNODEPATHINFO,
                &pathInfo,
                pathInfoSize
            ) == pathInfoSize else { return }

            let descriptorPath = withUnsafePointer(to: &pathInfo.pvip.vip_path) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) {
                    String(cString: $0)
                }
            }
            if descriptorPath == resolvedPath {
                count += 1
            }
        }
    }
}
