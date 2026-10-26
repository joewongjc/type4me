import XCTest
@testable import Type4Me

final class HomeDashboardDataTests: XCTestCase {

    private var store: HistoryStore!
    private var testPath: String!

    override func setUp() async throws {
        testPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("type4me-home-test-\(UUID().uuidString).db").path
        store = HistoryStore(path: testPath)
    }

    override func tearDown() async throws {
        store = nil
        try? FileManager.default.removeItem(atPath: testPath)
    }

    // MARK: - Diff

    func testDiffGroupsRemovalBeforeInsertion() throws {
        let segments = try XCTUnwrap(HomeTextDiff.segments(from: "改到下午三点吧", to: "改到下午 3 点"))

        XCTAssertEqual(segments.first, .init(kind: .same, text: "改到下午"))
        XCTAssertEqual(segments.map(\.kind), [.same, .removed, .inserted])
        XCTAssertEqual(segments.filter { $0.kind == .removed }.map(\.text).joined(), "三点吧")
        XCTAssertEqual(segments.filter { $0.kind == .inserted }.map(\.text).joined(), " 3 点")
    }

    func testDiffSkipsIdenticalAndOverlongText() {
        XCTAssertNil(HomeTextDiff.segments(from: "一样", to: "一样"))
        let long = String(repeating: "长", count: HomeTextDiff.maxComparedLength + 1)
        XCTAssertNil(HomeTextDiff.segments(from: long, to: "短"))
    }

    func testRewriteHasLowUnchangedRatio() throws {
        let original = "好的那我们午饭后对一下"
        let segments = try XCTUnwrap(HomeTextDiff.segments(from: original, to: "Let's sync after lunch."))
        XCTAssertLessThan(HomeTextDiff.unchangedRatio(segments, originalLength: original.count), 0.35)
    }

    // MARK: - Mode attribution

    func testResolvesModeByIdThenByLegacyName() {
        let polish = ProcessingMode.formalWriting
        let modes = [ProcessingMode.direct, polish]

        XCTAssertEqual(HomeModeUsage.resolve(modeId: polish.id.uuidString, modeName: "renamed", modes: modes), polish.id)
        XCTAssertEqual(HomeModeUsage.resolve(modeId: nil, modeName: nil, modes: modes), ProcessingMode.directId)
        XCTAssertEqual(HomeModeUsage.resolve(modeId: nil, modeName: "Voice Polish", modes: modes), polish.id)
        XCTAssertEqual(HomeModeUsage.resolve(modeId: nil, modeName: "语音润色", modes: modes), polish.id)
        XCTAssertNil(HomeModeUsage.resolve(modeId: UUID().uuidString, modeName: nil, modes: modes))
        XCTAssertNil(HomeModeUsage.resolve(modeId: nil, modeName: "Deleted mode", modes: modes))
    }

    func testCountsMergeLegacyAndNewRowsForTheSameMode() {
        let polish = ProcessingMode.formalWriting
        let counts = HomeModeUsage.counts(
            rows: [
                .init(modeId: polish.id.uuidString, modeName: polish.name, count: 2),
                .init(modeId: nil, modeName: "Voice Polish", count: 3),
                .init(modeId: nil, modeName: nil, count: 4),
            ],
            modes: [ProcessingMode.direct, polish]
        )

        XCTAssertEqual(counts[polish.id], 5)
        XCTAssertEqual(counts[ProcessingMode.directId], 4)
    }

    // MARK: - Collapsed modes row

    func testVisibleChipCountReservesRoomForOverflowLabel() {
        XCTAssertEqual(HomeDashboardView.visibleChipCount(widths: [100, 100], available: 208), 2)
        XCTAssertEqual(HomeDashboardView.visibleChipCount(widths: [100, 100, 100], available: 250), 2)
        XCTAssertEqual(HomeDashboardView.visibleChipCount(widths: [100, 100, 100], available: 240), 1)
        XCTAssertEqual(HomeDashboardView.visibleChipCount(widths: [100, 100, 100], available: 20), 0)
    }

    // MARK: - Store

    func testStoresTargetAppAndModeId() async {
        let modeId = UUID().uuidString
        await store.insert(record(modeId: modeId, bundleId: "com.tinyspeck.slackmacgap", appName: "Slack"))

        let fetched = await store.fetchAll().first
        XCTAssertEqual(fetched?.processingModeId, modeId)
        XCTAssertEqual(fetched?.targetBundleId, "com.tinyspeck.slackmacgap")
        XCTAssertEqual(fetched?.targetAppName, "Slack")
    }

    func testAppUsageSumsCharactersPerAppAndSkipsUnattributedRecords() async {
        await store.insert(record(bundleId: "com.a", appName: "A", characters: 10))
        await store.insert(record(bundleId: "com.a", appName: "A", characters: 5))
        await store.insert(record(bundleId: "com.b", appName: "B", characters: 30))
        await store.insert(record(characters: 99))
        await store.insert(record(bundleId: "com.c", appName: "C", characters: 50, status: "action_success"))

        let apps = await store.appUsage(from: Date().addingTimeInterval(-60), to: Date().addingTimeInterval(60), limit: 4)

        XCTAssertEqual(apps.map(\.key), ["com.b", "com.a"])
        XCTAssertEqual(apps.map(\.characterCount), [30, 15])
        XCTAssertEqual(apps.last?.appName, "A")
    }

    func testBackfillCopiesTraceAppNameAndGroupsWithNewRecords() async {
        await store.insert(record(characters: 10, trace: #"{"appName":"Lark","version":1}"#))
        await store.insert(record(characters: 20, trace: #"{"appName":"Unknown App","version":1}"#))
        await store.insert(record(characters: 99, trace: #"{"appName":"Type4Me","version":1}"#))
        await store.insert(record(bundleId: "com.electron.lark", appName: "Lark", characters: 5))

        await store.backfillTargetAppsFromTraces { $0 == "Lark" ? "com.electron.lark" : nil }

        let apps = await store.appUsage(from: Date().addingTimeInterval(-60), to: Date().addingTimeInterval(60), limit: 4)
        XCTAssertEqual(apps.map(\.key), ["Unknown App", "com.electron.lark"])
        XCTAssertEqual(apps.map(\.characterCount), [20, 15])
        XCTAssertNil(apps.first?.bundleId)
        XCTAssertEqual(apps.last?.appName, "Lark")
    }

    func testDayLabelOmitsTodayAndNamesYesterday() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 23, hour: 13))!

        XCTAssertNil(HomeTodayFeed.dayLabel(for: now.addingTimeInterval(-3_600), now: now, calendar: calendar))
        XCTAssertEqual(
            HomeTodayFeed.dayLabel(for: now.addingTimeInterval(-86_400), now: now, calendar: calendar),
            L("昨天", "Yesterday")
        )
        XCTAssertEqual(HomeTodayFeed.dayLabel(for: now.addingTimeInterval(-3 * 86_400), now: now, calendar: calendar), "10/20")
    }

    func testDictationRecordsExcludeMacActionResults() async {
        await store.insert(record(final: "听写"))
        await store.insert(record(final: "已打开", status: "action_success"))

        let range = (Date().addingTimeInterval(-60), Date().addingTimeInterval(60))
        let records = await store.dictationRecords(from: range.0, to: range.1, limit: 10)
        let count = await store.dictationRecordCount(from: range.0, to: range.1)

        XCTAssertEqual(records.map(\.finalText), ["听写"])
        XCTAssertEqual(count, 1)
    }

    private func record(
        raw: String = "原话",
        postSnippet: String? = nil,
        final: String = "结果",
        llm: String? = nil,
        modeId: String? = nil,
        bundleId: String? = nil,
        appName: String? = nil,
        characters: Int? = nil,
        status: String = "completed",
        trace: String? = nil
    ) -> HistoryRecord {
        HistoryRecord(
            id: UUID().uuidString,
            createdAt: Date(),
            durationSeconds: 1,
            rawText: raw,
            processingMode: nil,
            processedText: nil,
            finalText: final,
            status: status,
            characterCount: characters ?? final.count,
            asrProvider: nil,
            llmProvider: llm,
            intelliSenseTraceJSON: trace,
            postSnippetText: postSnippet,
            processingModeId: modeId,
            targetBundleId: bundleId,
            targetAppName: appName
        )
    }

    // MARK: - Ranked Card Value Width

    func testRankedCardValueColumnWidthScalesWithNumberLength() {
        // Small numbers (<= 3 chars, e.g. 999)
        XCTAssertEqual(HomeRankedCard.valueColumnWidth(for: ["5", "42", "999"]), 34)

        // 4 chars (e.g. 1,200 without comma or 4-digit unformatted)
        XCTAssertEqual(HomeRankedCard.valueColumnWidth(for: ["1200"]), 40)

        // 5 chars (e.g. 9,999)
        XCTAssertEqual(HomeRankedCard.valueColumnWidth(for: ["9,999"]), 46)

        // 6 chars (user case: 29,247 / 25,080 / 14,008 / 12,215)
        // Previously hardcoded to 40, which caused 29,247 (42.7pt) to wrap into 2 lines.
        let userRowValues = ["29,247", "25,080", "14,008", "12,215"]
        XCTAssertEqual(HomeRankedCard.valueColumnWidth(for: userRowValues), 52)

        // 7 chars (e.g. 100,000)
        XCTAssertEqual(HomeRankedCard.valueColumnWidth(for: ["100,000"]), 60)

        // 8-9+ chars (e.g. 1,250,000)
        XCTAssertEqual(HomeRankedCard.valueColumnWidth(for: ["1,250,000"]), 68)
    }

    func testRankedCardValueColumnWidthUniformAcrossRows() {
        // Card width must be based on the maximum value among the top rows
        // so all rows share the same column width and the progress bars align.
        let mixedValues = ["29,247", "500", "42"]
        XCTAssertEqual(HomeRankedCard.valueColumnWidth(for: mixedValues), 52)
    }
}
