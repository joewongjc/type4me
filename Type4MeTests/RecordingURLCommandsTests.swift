import XCTest
@testable import Type4Me

final class RecordingURLCommandParserTests: XCTestCase {
    private let schemes: Set<String> = ["type4me", "type4me-dev", "type4me-ctrixin"]

    func testValidCommands() throws {
        XCTAssertEqual(try parse("type4me://start"), .start)
        XCTAssertEqual(try parse("type4me://stop"), .stop)
        XCTAssertEqual(try parse("type4me://toggle"), .toggle)
    }

    func testDevAndPersonalSchemes() throws {
        XCTAssertEqual(try parse("type4me-dev://start"), .start)
        XCTAssertEqual(try parse("type4me-ctrixin://toggle"), .toggle)
        XCTAssertEqual(try parse("type4me-dev://stop"), .stop)
    }

    func testCaseInsensitivity() throws {
        XCTAssertEqual(try parse("TYPE4ME://START"), .start)
        XCTAssertEqual(try parse("Type4Me-Dev://ToGgLe"), .toggle)
        XCTAssertEqual(try parse("type4me://STOP"), .stop)
    }

    func testTrailingSlashIsAllowed() throws {
        XCTAssertEqual(try parse("type4me://start/"), .start)
        XCTAssertEqual(try parse("type4me://stop/"), .stop)
        XCTAssertEqual(try parse("type4me://toggle/"), .toggle)
    }

    func testRejectsUnregisteredScheme() {
        assertFailure("other://start", equals: .unsupportedScheme)
        assertFailure("http://start", equals: .unsupportedScheme)
        assertFailure("unknown://toggle", equals: .unsupportedScheme)
    }

    func testRejectsUnknownCommandHost() {
        assertFailure("type4me://unknown", equals: .unknownCommand)
        assertFailure("type4me://pause", equals: .unknownCommand)
        assertFailure("type4me://status", equals: .unknownCommand)
        assertFailure("type4me://restart", equals: .unknownCommand)
    }

    func testRejectsNonEmptyInvalidPath() {
        assertFailure("type4me://start/foo", equals: .invalidPath)
        assertFailure("type4me://stop/123", equals: .invalidPath)
        assertFailure("type4me://toggle/mode", equals: .invalidPath)
    }

    func testRejectsQueryParameters() {
        assertFailure("type4me://start?mode=code", equals: .unsupportedParameter)
        assertFailure("type4me://stop?silent=true", equals: .unsupportedParameter)
        assertFailure("type4me://toggle?foo=bar", equals: .unsupportedParameter)
        assertFailure("type4me-dev://start?anything=1", equals: .unsupportedParameter)
    }

    func testRejectsOversizedURL() {
        let padding = String(repeating: "a", count: RecordingURLCommandParser.maximumURLBytes)
        assertFailure("type4me://start?\(padding)", equals: .urlTooLong)
    }

    private func parse(_ raw: String) throws -> RecordingURLCommand {
        let url = try XCTUnwrap(URL(string: raw))
        return try RecordingURLCommandParser.parse(url, allowedSchemes: schemes).get()
    }

    private func assertFailure(
        _ raw: String,
        equals expected: RecordingURLCommandError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let url = URL(string: raw) else {
            XCTFail("Could not construct test URL", file: file, line: line)
            return
        }
        switch RecordingURLCommandParser.parse(url, allowedSchemes: schemes) {
        case .success(let command):
            XCTFail("Expected parsing to fail but got \(command)", file: file, line: line)
        case .failure(let error):
            XCTAssertEqual(error, expected, file: file, line: line)
        }
    }
}

final class RecordingURLDecisionTests: XCTestCase {
    func testStartDecisionMatrix() {
        let allPhases: [(FloatingBarPhase, RecordingURLDecision)] = [
            (.hidden, .start),
            (.preparing, .ignore),
            (.recording, .ignore),
            (.processing, .ignore),
            (.recovering, .ignore),
            (.done, .start),
            (.error, .start),
        ]

        for (phase, expected) in allPhases {
            let actual = RecordingURLDecision.decide(for: .start, phase: phase)
            XCTAssertEqual(
                actual,
                expected,
                "start on phase \(phase) expected \(expected) but got \(actual)"
            )
        }
    }

    func testStopDecisionMatrix() {
        let allPhases: [(FloatingBarPhase, RecordingURLDecision)] = [
            (.hidden, .ignore),
            (.preparing, .finish),
            (.recording, .finish),
            (.processing, .ignore),
            (.recovering, .ignore),
            (.done, .ignore),
            (.error, .ignore),
        ]

        for (phase, expected) in allPhases {
            let actual = RecordingURLDecision.decide(for: .stop, phase: phase)
            XCTAssertEqual(
                actual,
                expected,
                "stop on phase \(phase) expected \(expected) but got \(actual)"
            )
        }
    }

    func testToggleDecisionMatrix() {
        let allPhases: [(FloatingBarPhase, RecordingURLDecision)] = [
            (.hidden, .start),
            (.preparing, .finish),
            (.recording, .finish),
            (.processing, .ignore),
            (.recovering, .ignore),
            (.done, .start),
            (.error, .start),
        ]

        for (phase, expected) in allPhases {
            let actual = RecordingURLDecision.decide(for: .toggle, phase: phase)
            XCTAssertEqual(
                actual,
                expected,
                "toggle on phase \(phase) expected \(expected) but got \(actual)"
            )
        }
    }
}

final class InjectionTargetPlanTests: XCTestCase {
    // No captured target means Type4Me was frontmost at record start (e.g. a URL
    // Scheme command activated it, then yielded focus). The app focused at paste
    // time is the intended target, so paste into the current frontmost app.
    func testNilTargetInjectsIntoCurrentFrontmost() {
        XCTAssertEqual(
            RecognitionSession.planInjectionTarget(hasCapturedTarget: false, isTerminated: false),
            .injectIntoCurrentFrontmost
        )
    }

    // `isTerminated` is only meaningful when a target was captured; nil target
    // still resolves to the headless current-frontmost path regardless.
    func testNilTargetIgnoresTerminatedFlag() {
        XCTAssertEqual(
            RecognitionSession.planInjectionTarget(hasCapturedTarget: false, isTerminated: true),
            .injectIntoCurrentFrontmost
        )
    }

    // A live captured target must be activated and PID-confirmed frontmost before
    // pasting, so uncertainty falls back to the clipboard at runtime.
    func testLiveTargetRequiresActivationConfirmation() {
        XCTAssertEqual(
            RecognitionSession.planInjectionTarget(hasCapturedTarget: true, isTerminated: false),
            .activateAndConfirm
        )
    }

    // The captured target terminated during transcription/processing. Whatever is
    // frontmost now is a different app, so never paste — fail safe to the clipboard.
    func testTerminatedTargetFailsSafeToClipboard() {
        XCTAssertEqual(
            RecognitionSession.planInjectionTarget(hasCapturedTarget: true, isTerminated: true),
            .failSafeClipboard
        )
    }

    func testConfirmedRecordingEndTargetCanInject() {
        XCTAssertEqual(
            RecognitionSession.planInjectionTarget(
                preference: .recordingEnd,
                hasCapturedTarget: true,
                isTerminated: false,
                hasConfirmedEndTarget: true
            ),
            .injectIntoConfirmedEndTarget
        )
    }

    func testMissingRecordingEndTargetFailsSafeWithoutFallingBackToStartTarget() {
        XCTAssertEqual(
            RecognitionSession.planInjectionTarget(
                preference: .recordingEnd,
                hasCapturedTarget: true,
                isTerminated: false,
                hasConfirmedEndTarget: false
            ),
            .failSafeClipboard
        )
    }

    func testRecordingStartPreferenceIgnoresAnEndTargetSnapshot() {
        XCTAssertEqual(
            RecognitionSession.planInjectionTarget(
                preference: .recordingStart,
                hasCapturedTarget: true,
                isTerminated: false,
                hasConfirmedEndTarget: true
            ),
            .activateAndConfirm
        )
    }
}

final class RecordingStartSourceAndGateTests: XCTestCase {
    func testRecordingStartSourceValues() {
        XCTAssertEqual(RecordingStartSource.hotkey.rawValue, "hotkey")
        XCTAssertEqual(RecordingStartSource.menuBar.rawValue, "menuBar")
        XCTAssertEqual(RecordingStartSource.reviseHotkey.rawValue, "reviseHotkey")
        XCTAssertEqual(RecordingStartSource.reviseMenuBar.rawValue, "reviseMenuBar")
        XCTAssertEqual(RecordingStartSource.urlScheme.rawValue, "urlScheme")
    }

    func testOnlyOrdinaryManualSourcesAllowConfiguredInjectionTarget() {
        XCTAssertTrue(RecordingStartSource.hotkey.allowsConfiguredInjectionTarget)
        XCTAssertTrue(RecordingStartSource.menuBar.allowsConfiguredInjectionTarget)
        XCTAssertFalse(RecordingStartSource.urlScheme.allowsConfiguredInjectionTarget)
        XCTAssertFalse(RecordingStartSource.reviseHotkey.allowsConfiguredInjectionTarget)
        XCTAssertFalse(RecordingStartSource.reviseMenuBar.allowsConfiguredInjectionTarget)
    }

    func testRecordingStartGateInvalidation() {
        var gate = RecordingStartGate()
        let token1 = gate.begin()
        XCTAssertTrue(gate.allowsStart(token: token1))

        gate.invalidate()
        XCTAssertFalse(gate.allowsStart(token: token1))

        let token2 = gate.begin()
        XCTAssertTrue(gate.allowsStart(token: token2))
        XCTAssertFalse(gate.allowsStart(token: token1))
    }

    func testSelectionAskFollowUpStartGateInvalidation() {
        var gate = SelectionAskFollowUpStartGate()
        let token1 = gate.begin()
        XCTAssertTrue(
            gate.allowsStart(
                token: token1,
                isFollowUpActive: true,
                phase: .recording
            )
        )
        XCTAssertTrue(
            gate.allowsStart(
                token: token1,
                isFollowUpActive: true,
                phase: .preparing
            )
        )
        XCTAssertFalse(
            gate.allowsStart(
                token: token1,
                isFollowUpActive: false,
                phase: .recording
            )
        )
        XCTAssertFalse(
            gate.allowsStart(
                token: token1,
                isFollowUpActive: true,
                phase: .hidden
            )
        )

        gate.invalidate()
        XCTAssertFalse(
            gate.allowsStart(
                token: token1,
                isFollowUpActive: true,
                phase: .recording
            )
        )
    }

    @MainActor
    func testAppDelegateURLRoutingIntegration() {
        let appDelegate = AppDelegate()
        XCTAssertEqual(appDelegate.appState.barPhase, .hidden)

        // 1. URL start in hidden phase initiates recording
        let startURL = URL(string: "type4me://start")!
        appDelegate.application(NSApplication.shared, open: [startURL])
        XCTAssertEqual(appDelegate.appState.barPhase, .preparing)

        // 2. Redundant URL start during preparing is safely ignored
        appDelegate.application(NSApplication.shared, open: [startURL])
        XCTAssertEqual(appDelegate.appState.barPhase, .preparing)

        // 3. URL stop during preparing immediately tears down pending start
        let stopURL = URL(string: "type4me://stop")!
        appDelegate.application(NSApplication.shared, open: [stopURL])
        XCTAssertEqual(appDelegate.appState.barPhase, .hidden)

        // 4. URL toggle in hidden starts recording
        let toggleURL = URL(string: "type4me://toggle")!
        appDelegate.application(NSApplication.shared, open: [toggleURL])
        XCTAssertEqual(appDelegate.appState.barPhase, .preparing)

        // 5. URL toggle during preparing stops recording
        appDelegate.application(NSApplication.shared, open: [toggleURL])
        XCTAssertEqual(appDelegate.appState.barPhase, .hidden)
    }

    @MainActor
    func testAppDelegateURLRoutingWithSelectionAskMode() {
        let appDelegate = AppDelegate()
        if let askMode = appDelegate.appState.availableModes.first(where: { $0.id == ProcessingMode.selectionAskId }) {
            appDelegate.appState.currentMode = askMode
            let startURL = URL(string: "type4me://start")!
            appDelegate.application(NSApplication.shared, open: [startURL])
            XCTAssertEqual(appDelegate.appState.barPhase, .preparing)
            let stopURL = URL(string: "type4me://stop")!
            appDelegate.application(NSApplication.shared, open: [stopURL])
            XCTAssertEqual(appDelegate.appState.barPhase, .hidden)
        }
    }
}
