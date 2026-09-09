import XCTest
@testable import Type4Me

final class TextInjectionOutcomeTests: XCTestCase {

    func testFinalizeOutcomeBehaviorMatrix() {
        XCTAssertEqual(
            TextInjectionEngine.finalizeOutcome(.inserted, retention: .restoreOriginal),
            .inserted
        )
        XCTAssertEqual(
            TextInjectionEngine.finalizeOutcome(.inserted, retention: .retainResult),
            .inserted
        )
        XCTAssertEqual(
            TextInjectionEngine.finalizeOutcome(.copiedToClipboard, retention: .restoreOriginal),
            .notInserted
        )
        XCTAssertEqual(
            TextInjectionEngine.finalizeOutcome(.copiedToClipboard, retention: .retainResult),
            .copiedToClipboard
        )
    }

    func testShouldRestoreClipboardMatchesPolicy() {
        XCTAssertTrue(TextInjectionEngine.shouldRestoreClipboard(retention: .restoreOriginal))
        XCTAssertFalse(TextInjectionEngine.shouldRestoreClipboard(retention: .retainResult))
    }
}
