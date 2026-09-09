import XCTest
@testable import Type4Me

final class TextInjectionOutcomeTests: XCTestCase {

    func testShouldRestoreClipboardMatchesPolicy() {
        XCTAssertTrue(TextInjectionEngine.shouldRestoreClipboard(retention: .restoreOriginal))
        XCTAssertFalse(TextInjectionEngine.shouldRestoreClipboard(retention: .retainResult))
    }

    func testResolveDeliveryTargetFallbackConditions() {
        // 1. Nil frontmost app
        XCTAssertEqual(
            TextInjectionEngine.resolveDeliveryTarget(frontmost: nil, selfBundleIdentifier: "com.type4me.app"),
            .fallbackToClipboard
        )

        // 2. Type4Me itself is frontmost (matches selfBundleIdentifier)
        let currentApp = NSRunningApplication.current
        XCTAssertEqual(
            TextInjectionEngine.resolveDeliveryTarget(
                frontmost: currentApp,
                selfBundleIdentifier: currentApp.bundleIdentifier
            ),
            .fallbackToClipboard
        )

        // 3. Different app that is alive resolves to .app
        XCTAssertEqual(
            TextInjectionEngine.resolveDeliveryTarget(
                frontmost: currentApp,
                selfBundleIdentifier: "com.other.unique.bundle.id"
            ),
            .app(currentApp)
        )
    }
}
