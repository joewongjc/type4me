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
            appLookup: { pid in
                pid == 1234 ? "actual.element.app" : nil
            }
        )
        XCTAssertEqual(resolved, "actual.element.app")
    }

    func testResolveElementBundleIdentifierWithFailedPidStatusReturnsNil() {
        let resolved = TextInjectionEngine.resolveElementBundleIdentifier(
            pidStatus: .cannotComplete,
            pid: 1234,
            appLookup: { _ in "actual.element.app" }
        )
        XCTAssertNil(resolved)
    }

    func testResolveElementBundleIdentifierWithNilAppLookupReturnsNil() {
        let resolved = TextInjectionEngine.resolveElementBundleIdentifier(
            pidStatus: .success,
            pid: 1234,
            appLookup: { _ in nil }
        )
        XCTAssertNil(resolved)
    }

    func testAuthorizedSnapshotFailsClosedOnNilOrEmptyBundleIdentifier() {
        var didReadNil = false
        let nilSnapshot = TextInjectionEngine.authorizedSnapshot(
            bundleIdentifier: nil,
            authorize: { _ in true }
        ) {
            didReadNil = true
            return TextInjectionEngine.FocusedElementSnapshot(hasFocusedElement: true)
        }
        XCTAssertNil(nilSnapshot)
        XCTAssertFalse(didReadNil)

        var didReadEmpty = false
        let emptySnapshot = TextInjectionEngine.authorizedSnapshot(
            bundleIdentifier: "",
            authorize: { _ in true }
        ) {
            didReadEmpty = true
            return TextInjectionEngine.FocusedElementSnapshot(hasFocusedElement: true)
        }
        XCTAssertNil(emptySnapshot)
        XCTAssertFalse(didReadEmpty)
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

    func testElementLevelResolutionFailureFailsClosedWithoutReadingSnapshot() {
        // Even if authorize would allow anything, an unresolvable element PID fails closed
        let elementActualApp = TextInjectionEngine.resolveElementBundleIdentifier(
            pidStatus: .cannotComplete,
            pid: 9999,
            appLookup: { _ in "com.apple.Notes" }
        )
        XCTAssertNil(elementActualApp)

        var didRead = false
        let snapshot = TextInjectionEngine.authorizedSnapshot(
            bundleIdentifier: elementActualApp,
            authorize: { _ in true }
        ) {
            didRead = true
            return TextInjectionEngine.FocusedElementSnapshot(
                bundleIdentifier: elementActualApp,
                value: "unverified element text",
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
