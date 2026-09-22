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

    func testUnauthorizedAppNeverInvokesSnapshotReader() {
        var didRead = false

        let snapshot = TextInjectionEngine.authorizedSnapshot(
            bundleIdentifier: "com.apple.Terminal",
            authorize: { _ in false }
        ) {
            didRead = true
            return TextInjectionEngine.FocusedElementSnapshot(hasFocusedElement: true)
        }

        XCTAssertNil(snapshot)
        XCTAssertFalse(didRead)
    }

    func testResolveElementBundleIdentifierWithSuccessResolvesApp() {
        let resolved = TextInjectionEngine.resolveElementBundleIdentifier(
            pidStatus: .success,
            pid: 1234,
            fallback: "fallback.app",
            appLookup: { pid in
                pid == 1234 ? "actual.element.app" : nil
            }
        )
        XCTAssertEqual(resolved, "actual.element.app")
    }

    func testResolveElementBundleIdentifierWithFailedPidStatusFallsBack() {
        let resolved = TextInjectionEngine.resolveElementBundleIdentifier(
            pidStatus: .cannotComplete,
            pid: 1234,
            fallback: "fallback.app",
            appLookup: { _ in "actual.element.app" }
        )
        XCTAssertEqual(resolved, "fallback.app")
    }

    func testResolveElementBundleIdentifierWithNilAppLookupFallsBack() {
        let resolved = TextInjectionEngine.resolveElementBundleIdentifier(
            pidStatus: .success,
            pid: 1234,
            fallback: "fallback.app",
            appLookup: { _ in nil }
        )
        XCTAssertEqual(resolved, "fallback.app")
    }

    func testElementLevelAuthorizationRejectsElementOwnedByExcludedApp() {
        // App A is authorized, but element's PID resolves to excluded App B
        let authorize: (String?) -> Bool = { bundleID in
            bundleID != "com.apple.Terminal"
        }
        let initialApp = "com.apple.Notes"
        XCTAssertTrue(authorize(initialApp))

        let elementActualApp = TextInjectionEngine.resolveElementBundleIdentifier(
            pidStatus: .success,
            pid: 9999,
            fallback: initialApp,
            appLookup: { _ in "com.apple.Terminal" }
        )
        XCTAssertEqual(elementActualApp, "com.apple.Terminal")

        var didRead = false
        let snapshot = TextInjectionEngine.authorizedSnapshot(
            bundleIdentifier: elementActualApp,
            authorize: authorize
        ) {
            didRead = true
            return TextInjectionEngine.FocusedElementSnapshot(
                bundleIdentifier: elementActualApp,
                value: "terminal password",
                hasFocusedElement: true
            )
        }

        XCTAssertNil(snapshot)
        XCTAssertFalse(didRead)
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
