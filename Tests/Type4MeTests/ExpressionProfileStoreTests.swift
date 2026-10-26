import XCTest
@testable import Type4Me
@testable import Type4MeIntelliSenseCore

final class ExpressionProfileStoreTests: XCTestCase {
    func testExtractorStoresOnlyAbstractFeatures() throws {
        let observation = ExpressionObservation(
            sessionID: "session-secret",
            createdAt: Date(),
            appBundleIdentifier: "com.example.Editor",
            appCategory: .document,
            injectedText: "这是第一句话这是第二句话内容比较长",
            finalObservedText: "这是第一句话。\n这是第二句话，内容比较长。",
            correctionCandidateRange: nil
        )
        let sample = try XCTUnwrap(ExpressionFeatureExtractor.extract(observation))
        XCTAssertTrue(sample.wasEdited)
        XCTAssertEqual(
            Set(sample.values.keys),
            Set(ExpressionFeature.allCases).subtracting([.listUsage])
        )
    }

    func testListUsageOnlyLearnsFromListEligibleEvidence() throws {
        let prose = ExpressionObservation(
            sessionID: "prose",
            createdAt: Date(),
            appBundleIdentifier: nil,
            appCategory: .other,
            sourceText: "有三个问题需要说明",
            injectedText: "这是普通连续文本，没有使用任何列表结构。",
            finalObservedText: "这是普通连续文本，没有使用任何列表结构。",
            correctionCandidateRange: nil
        )
        XCTAssertNil(ExpressionFeatureExtractor.extract(prose)?.values[.listUsage])

        let acceptedList = ExpressionObservation(
            sessionID: "accepted-list",
            createdAt: Date(),
            appBundleIdentifier: nil,
            appCategory: .other,
            injectedText: "说明：\n1. 登录问题需要修复\n2. 支付问题需要回归",
            finalObservedText: "说明：\n1. 登录问题需要修复\n2. 支付问题需要回归",
            correctionCandidateRange: nil
        )
        XCTAssertNotNil(ExpressionFeatureExtractor.extract(acceptedList)?.values[.listUsage])

        let addedList = ExpressionObservation(
            sessionID: "added-list",
            createdAt: Date(),
            appBundleIdentifier: nil,
            appCategory: .other,
            injectedText: "说明：登录问题需要修复，支付问题需要回归。",
            finalObservedText: "说明：\n1. 登录问题需要修复\n2. 支付问题需要回归",
            correctionCandidateRange: nil
        )
        let positive = try XCTUnwrap(ExpressionFeatureExtractor.extract(addedList))
        XCTAssertEqual(positive.directions[.listUsage], 1)

        let removedList = ExpressionObservation(
            sessionID: "removed-list",
            createdAt: Date(),
            appBundleIdentifier: nil,
            appCategory: .other,
            injectedText: "说明：\n1. 登录问题需要修复\n2. 支付问题需要回归",
            finalObservedText: "说明：登录问题需要修复，支付问题需要回归。",
            correctionCandidateRange: nil
        )
        let negative = try XCTUnwrap(ExpressionFeatureExtractor.extract(removedList))
        XCTAssertEqual(negative.values[.listUsage], 0)
        XCTAssertEqual(negative.directions[.listUsage], -1)
    }

    func testOrdinarySamplesCannotMakeSingleListObservationStable() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ExpressionProfileStore(
            fileURL: directory.appendingPathComponent("profile.json"),
            thresholds: ExpressionLearningThresholds(
                learningSamples: 2,
                stableSamples: 3,
                stableDaySpan: 0,
                directionalConsistency: 0.6,
                editedWeight: 1,
                acceptedWeight: 0.25
            )
        )
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        for index in 0..<10 {
            try await store.record(ExpressionObservation(
                sessionID: "prose-\(index)",
                createdAt: start.addingTimeInterval(Double(index)),
                appBundleIdentifier: nil,
                appCategory: .other,
                injectedText: "这是普通连续文本，没有任何列表偏好证据。",
                finalObservedText: "这是普通连续文本，没有任何列表偏好证据。",
                correctionCandidateRange: nil
            ))
        }
        try await store.record(ExpressionObservation(
            sessionID: "one-list",
            createdAt: start.addingTimeInterval(20),
            appBundleIdentifier: nil,
            appCategory: .other,
            injectedText: "事项：\n1. 修复登录问题\n2. 回归支付问题",
            finalObservedText: "事项：\n1. 修复登录问题\n2. 回归支付问题",
            correctionCandidateRange: nil
        ))

        let list = await store.documentForTesting().global.features[ExpressionFeature.listUsage.rawValue]
        XCTAssertEqual(list?.acceptedEvidence, 1)
        XCTAssertEqual(list?.state, .insufficient)
    }

    func testV1MigrationResetsOnlyListUsage() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let profileURL = directory.appendingPathComponent("profile.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let resetAt = Date(timeIntervalSince1970: 1_700_000_000)
        var legacy = ExpressionProfileDocument()
        legacy.schemaVersion = 1
        legacy.expressionLearningResetAt = resetAt
        let list = FeatureAccumulator(weightedMean: 0, totalWeight: 8, acceptedEvidence: 32, state: .stable)
        let spacing = FeatureAccumulator(weightedMean: 1, totalWeight: 4, acceptedEvidence: 16, state: .stable)
        legacy.global.features[ExpressionFeature.listUsage.rawValue] = list
        legacy.global.features[ExpressionFeature.chineseEnglishSpacing.rawValue] = spacing
        legacy.categories[ApplicationCategory.browser.rawValue] = legacy.global
        legacy.applications["company.thebrowser.dia"] = legacy.global
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(legacy).write(to: profileURL)

        let store = ExpressionProfileStore(fileURL: profileURL)
        let migrated = await store.documentForTesting()
        XCTAssertEqual(migrated.schemaVersion, 2)
        XCTAssertEqual(migrated.expressionLearningResetAt, resetAt)
        XCTAssertNil(migrated.global.features[ExpressionFeature.listUsage.rawValue])
        XCTAssertNil(migrated.categories[ApplicationCategory.browser.rawValue]?.features[ExpressionFeature.listUsage.rawValue])
        XCTAssertNil(migrated.applications["company.thebrowser.dia"]?.features[ExpressionFeature.listUsage.rawValue])
        XCTAssertEqual(
            migrated.global.features[ExpressionFeature.chineseEnglishSpacing.rawValue],
            spacing
        )
    }

    func testStableAppProfileOverridesCategoryAndGlobal() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let profileURL = directory.appendingPathComponent("profile.json")
        let store = ExpressionProfileStore(
            fileURL: profileURL,
            thresholds: ExpressionLearningThresholds(
                learningSamples: 2,
                stableSamples: 3,
                stableDaySpan: 2,
                directionalConsistency: 0.6,
                editedWeight: 1,
                acceptedWeight: 0.25
            )
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let start = Date(timeIntervalSince1970: 1_700_000_000)
        for day in 0..<3 {
            try await store.record(ExpressionObservation(
                sessionID: "s\(day)",
                createdAt: Calendar.current.date(byAdding: .day, value: day, to: start)!,
                appBundleIdentifier: "COM.EXAMPLE.EDITOR",
                appCategory: .document,
                injectedText: "这是第一句话这是第二句话内容比较长",
                finalObservedText: "这是第一句话。\n这是第二句话，内容比较长。",
                correctionCandidateRange: nil
            ))
        }

        let document = await store.documentForTesting()
        XCTAssertEqual(document.applications["com.example.editor"]?.sampleCount, 3)
        let persisted = String(decoding: try Data(contentsOf: profileURL), as: UTF8.self)
        XCTAssertFalse(persisted.contains("这是第一句话"))
        let effective = await store.effectiveProfile(
            bundleIdentifier: "com.example.editor",
            category: .document
        )
        XCTAssertNotNil(effective)
        let categoryFallback = await store.effectiveProfile(
            bundleIdentifier: "com.example.other-editor",
            category: .document
        )
        XCTAssertNotNil(categoryFallback)
        let globalFallback = await store.effectiveProfile(
            bundleIdentifier: "com.example.chat",
            category: .messaging
        )
        XCTAssertNotNil(globalFallback)

        let reloadedStore = ExpressionProfileStore(
            fileURL: profileURL,
            thresholds: ExpressionLearningThresholds(
                learningSamples: 2,
                stableSamples: 3,
                stableDaySpan: 2,
                directionalConsistency: 0.6,
                editedWeight: 1,
                acceptedWeight: 0.25
            )
        )
        let reloaded = await reloadedStore.documentForTesting()
        XCTAssertEqual(reloaded.applications["com.example.editor"]?.sampleCount, 3)

        let resetAt = Date(timeIntervalSince1970: 1_800_000_000)
        try await store.clear(at: resetAt)
        XCTAssertTrue(FileManager.default.fileExists(atPath: profileURL.path))
        let clearedDocument = await store.documentForTesting()
        XCTAssertEqual(clearedDocument.expressionLearningResetAt, resetAt)
        XCTAssertEqual(clearedDocument.global.sampleCount, 0)
        let cleared = await store.effectiveProfile(
            bundleIdentifier: "com.example.editor",
            category: .document
        )
        XCTAssertNil(cleared)

        try await store.record(ExpressionObservation(
            sessionID: "old-after-reset",
            createdAt: resetAt.addingTimeInterval(-1),
            appBundleIdentifier: "com.example.editor",
            appCategory: .document,
            injectedText: "原文",
            finalObservedText: "修改后的文字。",
            correctionCandidateRange: nil
        ))
        let afterOldRecord = await store.documentForTesting()
        XCTAssertEqual(afterOldRecord.global.sampleCount, 0)
    }

    func testRejectsSensitiveOrFactChangingEdits() {
        let sensitive = ExpressionObservation(
            sessionID: "s",
            createdAt: Date(),
            appBundleIdentifier: nil,
            appCategory: .other,
            injectedText: "请保存 api_key = abcdefghijklmnop",
            finalObservedText: "请妥善保存 api_key = abcdefghijklmnop",
            correctionCandidateRange: nil
        )
        XCTAssertNil(ExpressionFeatureExtractor.extract(sensitive))
    }

    func testOfflineRebuildHonorsResetWatermarkAndSafeClassifications() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ExpressionProfileStore(fileURL: directory.appendingPathComponent("profile.json"))
        let resetAt = Date(timeIntervalSince1970: 1_800_000_000)
        try await store.clear(at: resetAt)
        let old = historyRecord(
            id: "old",
            date: resetAt.addingTimeInterval(-1),
            final: "这是第一句话这是第二句话内容比较长",
            edited: "这是第一句话。\n这是第二句话，内容比较长。"
        )
        let safe = historyRecord(
            id: "safe",
            date: resetAt.addingTimeInterval(1),
            final: "这是第一句话这是第二句话内容比较长",
            edited: "这是第一句话。\n这是第二句话，内容比较长。"
        )
        let factual = historyRecord(
            id: "fact",
            date: resetAt.addingTimeInterval(2),
            final: "版本 3",
            edited: "版本 4"
        )
        let legacy = historyRecord(
            id: "legacy-v1",
            date: resetAt.addingTimeInterval(3),
            final: "这是第一句话这是第二句话内容比较长",
            edited: "这是第一句话。\n这是第二句话，内容比较长。",
            version: 1
        )

        try await store.rebuild(from: [old, safe, factual, legacy])

        let document = await store.documentForTesting()
        XCTAssertEqual(document.expressionLearningResetAt, resetAt)
        XCTAssertEqual(document.global.sampleCount, 1)
    }

    private func historyRecord(
        id: String,
        date: Date,
        final: String,
        edited: String,
        version: Int = UserEditObservationFormat.currentVersion
    ) -> HistoryRecord {
        HistoryRecord(
            id: id,
            createdAt: date,
            durationSeconds: 1,
            rawText: final,
            processingMode: "智能感知",
            processedText: final,
            finalText: final,
            status: "completed",
            characterCount: final.count,
            asrProvider: nil,
            userEditedText: edited,
            userEditStatus: .edited,
            userEditObservedAt: date,
            userEditVersion: version
        )
    }
}
