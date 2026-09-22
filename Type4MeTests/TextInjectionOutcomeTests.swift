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
        let currentApp = StubRunningApplication(bundleIdentifier: "com.type4me.app", isTerminated: false)
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

        // 4. A terminated app cannot receive the result.
        let terminatedApp = StubRunningApplication(bundleIdentifier: "com.editor.app", isTerminated: true)
        XCTAssertEqual(
            TextInjectionEngine.resolveDeliveryTarget(
                frontmost: terminatedApp,
                selfBundleIdentifier: "com.type4me.app"
            ),
            .fallbackToClipboard
        )
    }

    func testSecureRoleDoesNotReadTrackedValue() {
        var didReadValue = false

        let value = TextInjectionEngine.trackedValue(
            role: "AXTextField",
            subrole: "AXSecureTextField"
        ) {
            didReadValue = true
            return "secret"
        }

        XCTAssertNil(value)
        XCTAssertFalse(didReadValue)
    }
}

private final class StubRunningApplication: NSRunningApplication {
    private let testBundleIdentifier: String
    private let testIsTerminated: Bool

    init(bundleIdentifier: String, isTerminated: Bool) {
        testBundleIdentifier = bundleIdentifier
        testIsTerminated = isTerminated
        super.init()
    }

    override var bundleIdentifier: String? { testBundleIdentifier }
    override var isTerminated: Bool { testIsTerminated }
}
