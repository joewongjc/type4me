import XCTest
@testable import Type4Me

final class ClipboardOutputPolicyTests: XCTestCase {

    private func makeDefaults() -> UserDefaults {
        let suite = "Type4MeTests.ClipboardOutputPolicy.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    func testDefaultPolicyOnlyKeepsProcessedCancelledResults() {
        let policy = ClipboardOutputPolicy.defaultValue

        XCTAssertEqual(policy, .cancelProcessed)
        XCTAssertFalse(policy.retainsNormalResult)
        XCTAssertTrue(policy.retainsCancelledResult)
        XCTAssertTrue(policy.processesCancelledResult)
    }

    func testPolicyBehaviorMatrix() {
        let expectations: [
            (policy: ClipboardOutputPolicy, normalRetention: Bool,
             cancelledRetention: Bool, processesCancellation: Bool,
             cancelledStatus: String)
        ] = [
            (.alwaysCopy, true, true, true, "cancelled_processed"),
            (.cancelProcessed, false, true, true, "cancelled_processed"),
            (.cancelRawTranscript, false, true, false, "cancelled_raw"),
            (.neverCopy, false, false, false, "cancelled_unprocessed"),
        ]

        for expectation in expectations {
            XCTAssertEqual(
                expectation.policy.retainsResult(forCancellation: false),
                expectation.normalRetention,
                "normal completion: \(expectation.policy)"
            )
            XCTAssertEqual(
                expectation.policy.retainsResult(forCancellation: true),
                expectation.cancelledRetention,
                "cancelled completion: \(expectation.policy)"
            )
            XCTAssertEqual(
                expectation.policy.processesCancelledResult,
                expectation.processesCancellation,
                "LLM cancellation rule: \(expectation.policy)"
            )
            XCTAssertEqual(
                expectation.policy.cancelledHistoryStatus,
                expectation.cancelledStatus,
                "history status: \(expectation.policy)"
            )
        }
    }

    func testRestoringClipboardDoesNotReportClipboardFallback() {
        XCTAssertEqual(
            TextInjectionEngine.finalizeOutcome(
                .copiedToClipboard,
                retention: .restoreOriginal
            ),
            .notInserted
        )
        XCTAssertEqual(
            TextInjectionEngine.finalizeOutcome(
                .copiedToClipboard,
                retention: .retainResult
            ),
            .copiedToClipboard
        )
    }

    func testBestEffortOpaquePasteNeverRestoresAwayItsFallback() {
        XCTAssertFalse(TextInjectionEngine.shouldRestoreClipboard(
            retention: .restoreOriginal,
            isBestEffortOpaque: true
        ))
        XCTAssertTrue(TextInjectionEngine.shouldRestoreClipboard(
            retention: .restoreOriginal,
            isBestEffortOpaque: false
        ))
        XCTAssertFalse(TextInjectionEngine.shouldRestoreClipboard(
            retention: .retainResult,
            isBestEffortOpaque: false
        ))
    }

    func testLegacyAlwaysCopyMigratesToAlwaysCopy() {
        let defaults = makeDefaults()
        defaults.set(false, forKey: "tf_preserveClipboard")

        ClipboardOutputPolicy.migrateIfNeeded(userDefaults: defaults)

        XCTAssertEqual(
            defaults.string(forKey: ClipboardOutputPolicy.storageKey),
            ClipboardOutputPolicy.alwaysCopy.rawValue
        )
    }

    func testLegacyDefaultMigratesToCancelledProcessed() {
        let defaults = makeDefaults()
        defaults.set(true, forKey: "tf_preserveClipboard")

        XCTAssertEqual(
            ClipboardOutputPolicy.current(userDefaults: defaults),
            .cancelProcessed
        )
    }

    func testMissingLegacyPreferenceMigratesToDefault() {
        let defaults = makeDefaults()

        XCTAssertEqual(
            ClipboardOutputPolicy.current(userDefaults: defaults),
            .cancelProcessed
        )
        XCTAssertEqual(
            defaults.string(forKey: ClipboardOutputPolicy.storageKey),
            ClipboardOutputPolicy.cancelProcessed.rawValue
        )
    }

    func testCancellationRetentionModeAndPolicyMapping() {
        XCTAssertEqual(ClipboardOutputPolicy.alwaysCopy.cancellationMode, .processed)
        XCTAssertEqual(ClipboardOutputPolicy.cancelProcessed.cancellationMode, .processed)
        XCTAssertEqual(ClipboardOutputPolicy.cancelRawTranscript.cancellationMode, .raw)
        XCTAssertEqual(ClipboardOutputPolicy.neverCopy.cancellationMode, .none)

        XCTAssertEqual(
            ClipboardOutputPolicy.policy(retainsNormal: true, cancellationMode: .processed),
            .alwaysCopy
        )
        XCTAssertEqual(
            ClipboardOutputPolicy.policy(retainsNormal: true, cancellationMode: .raw),
            .alwaysCopy
        )
        XCTAssertEqual(
            ClipboardOutputPolicy.policy(retainsNormal: false, cancellationMode: .processed),
            .cancelProcessed
        )
        XCTAssertEqual(
            ClipboardOutputPolicy.policy(retainsNormal: false, cancellationMode: .raw),
            .cancelRawTranscript
        )
        XCTAssertEqual(
            ClipboardOutputPolicy.policy(retainsNormal: false, cancellationMode: .none),
            .neverCopy
        )
    }
}
