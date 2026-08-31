import XCTest
import CoreGraphics
@testable import Type4Me
@testable import Type4MeIntelliSenseCore

final class InjectionTargetPreferenceTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var previousLanguage: String?

    override func setUp() {
        super.setUp()
        suiteName = "InjectionTargetPreferenceTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        previousLanguage = UserDefaults.standard.string(forKey: "tf_language")
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        if let previousLanguage {
            UserDefaults.standard.set(previousLanguage, forKey: "tf_language")
        } else {
            UserDefaults.standard.removeObject(forKey: "tf_language")
        }
        previousLanguage = nil
        super.tearDown()
    }

    func testDefaultPreservesRecordingStartBehavior() {
        XCTAssertEqual(InjectionTargetPreference.current(userDefaults: defaults), .recordingStart)
    }

    func testStoredRecordingEndPreferenceIsLoaded() {
        defaults.set(
            InjectionTargetPreference.recordingEnd.rawValue,
            forKey: InjectionTargetPreference.storageKey
        )
        XCTAssertEqual(InjectionTargetPreference.current(userDefaults: defaults), .recordingEnd)
    }

    func testUnknownStoredValueFallsBackToDefault() {
        defaults.set("future-value", forKey: InjectionTargetPreference.storageKey)
        XCTAssertEqual(
            InjectionTargetPreference.current(userDefaults: defaults),
            InjectionTargetPreference.defaultValue
        )
    }

    func testDisplayCopyUpdatesForChineseAndEnglish() {
        UserDefaults.standard.set("zh", forKey: "tf_language")
        XCTAssertEqual(InjectionTargetPreference.recordingStart.displayName, "录音开始时的应用")
        XCTAssertEqual(InjectionTargetPreference.recordingEnd.displayName, "录音结束时的输入框")
        XCTAssertTrue(InjectionTargetPreference.recordingEnd.detail.contains("剪贴板"))
        XCTAssertTrue(InjectionTargetPreference.recordingEnd.detail.contains("不透明编辑器"))
        XCTAssertEqual(
            InjectionOutcome.pasteAttemptedClipboardRetained.completionMessage,
            "已尝试输入，文本已保留到剪贴板"
        )

        UserDefaults.standard.set("en", forKey: "tf_language")
        XCTAssertEqual(InjectionTargetPreference.recordingStart.displayName, "App at Recording Start")
        XCTAssertEqual(InjectionTargetPreference.recordingEnd.displayName, "Focused Field at Recording End")
        XCTAssertTrue(InjectionTargetPreference.recordingEnd.detail.contains("clipboard"))
        XCTAssertTrue(InjectionTargetPreference.recordingEnd.detail.contains("opaque editors"))
        XCTAssertEqual(
            InjectionOutcome.pasteAttemptedClipboardRetained.completionMessage,
            "Paste attempted; text kept in clipboard"
        )
    }

    func testIntelliSenseEnvironmentFollowsConfiguredTargetTime() throws {
        let start = TargetApplicationContext(
            processIdentifier: 100,
            bundleIdentifier: "com.openai.codex",
            displayName: "Codex"
        )
        let end = TargetApplicationContext(
            processIdentifier: 200,
            bundleIdentifier: "com.tencent.xinWeChat",
            displayName: "WeChat"
        )

        XCTAssertEqual(
            RecognitionSession.resolvedIntelliSenseTarget(
                preference: .recordingStart,
                recordingStartTarget: start,
                recordingEndTarget: end
            ),
            start
        )
        let resolvedEnd = RecognitionSession.resolvedIntelliSenseTarget(
            preference: .recordingEnd,
            recordingStartTarget: start,
            recordingEndTarget: end
        )
        XCTAssertEqual(resolvedEnd, end)
        XCTAssertNil(RecognitionSession.resolvedIntelliSenseTarget(
            preference: .recordingEnd,
            recordingStartTarget: start,
            recordingEndTarget: nil
        ))

        var settings = IntelliSenseSettings()
        settings.applicationAwarenessEnabled = true
        let snapshot = IntelliSenseContextSnapshot.appOnly(try XCTUnwrap(resolvedEnd))
        let result = IntelliSenseOutputValidator.process(
            input: "今晚发给文件传输助手。",
            candidate: "今晚发给文件传输助手。",
            context: snapshot
        )
        let trace = IntelliSenseHistoryTraceBuilder.build(
            input: "今晚发给文件传输助手。",
            finalText: result.finalText,
            promptInput: .init(context: snapshot, settings: settings, expressionProfile: nil),
            processingResult: result,
            processingFailed: false
        )
        XCTAssertEqual(trace.appName, "WeChat")
        XCTAssertEqual(trace.scene, .messaging)
    }
}

final class EndInjectionTargetEvidenceTests: XCTestCase {
    private func rejectionReason(
        role: String? = "AXTextArea",
        subrole: String? = nil,
        isFocused: Bool = true,
        selectedRangeSettable: Bool = true,
        selectedTextSettable: Bool = true,
        valueSettable: Bool = true,
        elementPID: pid_t = 42,
        frontmostPID: pid_t = 42
    ) -> String? {
        TextInjectionEngine.confirmedFocusRejectionReason(
            role: role,
            subrole: subrole,
            isFocused: isFocused,
            selectedRangeSettable: selectedRangeSettable,
            selectedTextSettable: selectedTextSettable,
            valueSettable: valueSettable,
            elementPID: elementPID,
            frontmostPID: frontmostPID
        )
    }

    func testEditableTextAreaWithSettableRangeIsAccepted() {
        XCTAssertTrue(TextInjectionEngine.isStrictEditableCandidate(
            role: "AXTextArea",
            selectedRangeSettable: true,
            selectedTextSettable: false,
            valueSettable: true
        ))
    }

    func testTextFieldWithOnlySettableValueIsAccepted() {
        XCTAssertTrue(TextInjectionEngine.isStrictEditableCandidate(
            role: "AXTextField",
            selectedRangeSettable: false,
            selectedTextSettable: false,
            valueSettable: true
        ))
    }

    func testNonTextControlWithSettableValueIsRejected() {
        XCTAssertFalse(TextInjectionEngine.isStrictEditableCandidate(
            role: "AXSlider",
            selectedRangeSettable: false,
            selectedTextSettable: false,
            valueSettable: true
        ))
    }

    func testRoleWithoutWritableTextAttributesIsRejected() {
        XCTAssertFalse(TextInjectionEngine.isStrictEditableCandidate(
            role: "AXTextArea",
            selectedRangeSettable: false,
            selectedTextSettable: false,
            valueSettable: false
        ))
    }

    func testSecureAndPasswordRolesAreRejected() {
        XCTAssertTrue(TextInjectionEngine.isSecureRole(
            role: "AXTextField",
            subrole: "AXSecureTextField"
        ))
        XCTAssertTrue(TextInjectionEngine.isSecureRole(
            role: "AXPasswordField",
            subrole: nil
        ))
        XCTAssertFalse(TextInjectionEngine.isSecureRole(
            role: "AXTextArea",
            subrole: nil
        ))
    }

    func testExactFocusedEditableElementIsConfirmed() {
        XCTAssertNil(rejectionReason())
    }

    func testElementFromAnotherProcessIsRejected() {
        XCTAssertEqual(rejectionReason(elementPID: 41), "pidMismatch")
    }

    func testElementWithoutExplicitFocusIsRejected() {
        XCTAssertEqual(rejectionReason(isFocused: false), "notFocused")
    }

    func testFocusedNonEditableElementIsRejected() {
        XCTAssertEqual(
            rejectionReason(
                role: "AXGroup",
                selectedRangeSettable: false,
                selectedTextSettable: false,
                valueSettable: true
            ),
            "notEditable"
        )
    }

    func testFocusedSecureElementIsRejected() {
        XCTAssertEqual(rejectionReason(subrole: "AXSecureTextField"), "secure")
    }

    func testFocusedWindowOrSheetCannotMasqueradeAsAnEditableTarget() {
        for role in ["AXWindow", "AXSheet"] {
            XCTAssertEqual(
                rejectionReason(
                    role: role,
                    selectedRangeSettable: false,
                    selectedTextSettable: false,
                    valueSettable: false
                ),
                "notEditable"
            )
        }
    }

    func testOpaqueWindowIsOnlyEligibleAsBestEffortEvidence() {
        for role in ["AXWindow", "AXSheet"] {
            XCTAssertTrue(TextInjectionEngine.shouldUseBestEffortOpaqueDestination(
                role: role,
                subrole: nil,
                pasteCommandPresent: true,
                hasAccessibleEditableDescendant: false,
                focusedElementMatchesWindow: true,
                elementPIDMatchesFrontmost: true
            ))
        }
    }

    func testBestEffortOpaqueDestinationRequiresPasteCommandPresence() {
        XCTAssertFalse(TextInjectionEngine.shouldUseBestEffortOpaqueDestination(
            role: "AXWindow",
            subrole: nil,
            pasteCommandPresent: false,
            hasAccessibleEditableDescendant: false,
            focusedElementMatchesWindow: true,
            elementPIDMatchesFrontmost: true
        ))
    }

    func testBestEffortOpaqueDestinationDoesNotReplaceExactEvidence() {
        XCTAssertFalse(TextInjectionEngine.shouldUseBestEffortOpaqueDestination(
            role: "AXWindow",
            subrole: nil,
            pasteCommandPresent: true,
            hasAccessibleEditableDescendant: true,
            focusedElementMatchesWindow: true,
            elementPIDMatchesFrontmost: true
        ))
        XCTAssertFalse(TextInjectionEngine.shouldUseBestEffortOpaqueDestination(
            role: "AXWindow",
            subrole: nil,
            pasteCommandPresent: true,
            hasAccessibleEditableDescendant: false,
            editableDescendantScanComplete: false,
            focusedElementMatchesWindow: true,
            elementPIDMatchesFrontmost: true
        ))
    }

    func testBestEffortOpaqueDestinationRejectsUnsafeIdentity() {
        XCTAssertFalse(TextInjectionEngine.shouldUseBestEffortOpaqueDestination(
            role: "AXWebArea",
            subrole: nil,
            pasteCommandPresent: true,
            hasAccessibleEditableDescendant: false,
            focusedElementMatchesWindow: false,
            elementPIDMatchesFrontmost: true
        ))
        XCTAssertFalse(TextInjectionEngine.shouldUseBestEffortOpaqueDestination(
            role: "AXWindow",
            subrole: "AXSecureTextField",
            pasteCommandPresent: true,
            hasAccessibleEditableDescendant: false,
            focusedElementMatchesWindow: true,
            elementPIDMatchesFrontmost: true
        ))
        XCTAssertFalse(TextInjectionEngine.shouldUseBestEffortOpaqueDestination(
            role: "AXWindow",
            subrole: nil,
            pasteCommandPresent: true,
            hasAccessibleEditableDescendant: false,
            focusedElementMatchesWindow: true,
            elementPIDMatchesFrontmost: false
        ))
    }
}

final class OpaqueInputContinuityTests: XCTestCase {
    private func keyboardEvent(
        keyCode: CGKeyCode,
        keyDown: Bool,
        flags: CGEventFlags = []
    ) throws -> CGEvent {
        let event = try XCTUnwrap(CGEvent(
            keyboardEventSource: nil,
            virtualKey: keyCode,
            keyDown: keyDown
        ))
        event.flags = flags
        return event
    }

    private func fnSystemActionEcho(
        keyDown: Bool,
        timestamp: UInt64
    ) throws -> CGEvent {
        let event = try keyboardEvent(
            keyCode: 179,
            keyDown: keyDown,
            flags: .maskNonCoalesced
        )
        event.timestamp = timestamp
        event.setIntegerValueField(.eventSourceUnixProcessID, value: 0)
        event.setIntegerValueField(.eventSourceUserData, value: 0)
        event.setIntegerValueField(
            .eventSourceStateID,
            value: Int64(CGEventSourceStateID.hidSystemState.rawValue)
        )
        return event
    }

    func testPotentialFocusChangingEventsIncludeEveryKeyboardAndPointerEdge() {
        for eventType in [
            CGEventType.keyDown,
            .keyUp,
            .flagsChanged,
            .leftMouseDown,
            .leftMouseUp,
            .rightMouseDown,
            .rightMouseUp,
            .otherMouseDown,
            .otherMouseUp,
            .leftMouseDragged,
            .rightMouseDragged,
            .otherMouseDragged,
            .scrollWheel,
        ] {
            XCTAssertTrue(TextInjectionEngine.canChangeOpaqueInputFocus(eventType))
        }
        XCTAssertTrue(TextInjectionEngine.canChangeOpaqueInputFocus(
            CGEventType(rawValue: 14)!
        ))
        XCTAssertFalse(TextInjectionEngine.canChangeOpaqueInputFocus(.mouseMoved))
    }

    func testExactStopGestureReleaseTailDoesNotInvalidateToken() throws {
        let monitor = TextInjectionEngine.InputActivityMonitor()
        monitor.startForTesting()

        let leftCommandFlags = CGEventFlags(rawValue:
            CGEventFlags.maskCommand.rawValue | ModeBinding.deviceLeftCommandMask
        )

        let stopKeyDown = try keyboardEvent(
            keyCode: 43,
            keyDown: true,
            flags: leftCommandFlags
        )
        monitor.beginEvent(type: .keyDown, event: stopKeyDown, isSynthetic: false)
        XCTAssertTrue(monitor.authorizeCurrentEventForStopCapture())
        let token = try XCTUnwrap(monitor.captureToken())
        monitor.allowCurrentStopGestureTail(since: token)
        monitor.endEvent()
        XCTAssertTrue(monitor.isUnchanged(since: token))

        let stopKeyUp = try keyboardEvent(
            keyCode: 43,
            keyDown: false,
            flags: leftCommandFlags
        )
        monitor.beginEvent(type: .keyUp, event: stopKeyUp, isSynthetic: false)
        monitor.endEvent()

        let commandReleased = try keyboardEvent(keyCode: 55, keyDown: false)
        monitor.beginEvent(
            type: .flagsChanged,
            event: commandReleased,
            isSynthetic: false
        )
        monitor.endEvent()
        XCTAssertTrue(monitor.isUnchanged(since: token))

        let tab = try keyboardEvent(keyCode: 48, keyDown: true)
        monitor.beginEvent(type: .keyDown, event: tab, isSynthetic: false)
        monitor.endEvent()
        XCTAssertFalse(monitor.isUnchanged(since: token))
    }

    func testFnReleaseReconciliationEchoDoesNotInvalidateToken() throws {
        let monitor = TextInjectionEngine.InputActivityMonitor()
        monitor.startForTesting()

        let fnReleased = try keyboardEvent(keyCode: 63, keyDown: false)
        monitor.beginEvent(type: .flagsChanged, event: fnReleased, isSynthetic: false)
        XCTAssertTrue(monitor.authorizeCurrentEventForStopCapture())
        let token = try XCTUnwrap(monitor.captureToken())
        monitor.allowCurrentStopGestureTail(since: token)
        monitor.endEvent()

        let reconciliationEcho = try keyboardEvent(keyCode: 255, keyDown: false)
        monitor.beginEvent(
            type: .flagsChanged,
            event: reconciliationEcho,
            isSynthetic: false
        )
        monitor.endEvent()
        XCTAssertTrue(monitor.isUnchanged(since: token))

        let tab = try keyboardEvent(keyCode: 48, keyDown: true)
        monitor.beginEvent(type: .keyDown, event: tab, isSynthetic: false)
        monitor.endEvent()
        XCTAssertFalse(monitor.isUnchanged(since: token))
    }

    func testFnReleaseTailIgnoresNonModifierEventFlags() throws {
        let monitor = TextInjectionEngine.InputActivityMonitor()
        monitor.startForTesting()

        let fnReleased = try keyboardEvent(
            keyCode: 63,
            keyDown: false,
            flags: .maskNonCoalesced
        )
        monitor.beginEvent(type: .flagsChanged, event: fnReleased, isSynthetic: false)
        XCTAssertTrue(monitor.authorizeCurrentEventForStopCapture())
        let token = try XCTUnwrap(monitor.captureToken())
        XCTAssertTrue(monitor.allowCurrentStopGestureTail(since: token))
        monitor.endEvent()

        for keyCode: CGKeyCode in [63, 255] {
            let echo = try keyboardEvent(
                keyCode: keyCode,
                keyDown: false,
                flags: .maskNonCoalesced
            )
            monitor.beginEvent(type: .flagsChanged, event: echo, isSynthetic: false)
            monitor.endEvent()
        }
        XCTAssertTrue(monitor.isUnchanged(since: token))

        let tab = try keyboardEvent(
            keyCode: 48,
            keyDown: true,
            flags: .maskNonCoalesced
        )
        monitor.beginEvent(type: .keyDown, event: tab, isSynthetic: false)
        monitor.endEvent()
        XCTAssertFalse(monitor.isUnchanged(since: token))
    }

    func testFnReleaseTailAcceptsMatchingSystemActionEchoPair() throws {
        let monitor = TextInjectionEngine.InputActivityMonitor()
        monitor.startForTesting()

        let fnReleased = try keyboardEvent(
            keyCode: 63,
            keyDown: false,
            flags: .maskNonCoalesced
        )
        monitor.beginEvent(type: .flagsChanged, event: fnReleased, isSynthetic: false)
        XCTAssertTrue(monitor.authorizeCurrentEventForStopCapture())
        let token = try XCTUnwrap(monitor.captureToken())
        XCTAssertTrue(monitor.allowCurrentStopGestureTail(since: token))
        monitor.endEvent()

        let timestamp: UInt64 = 13_168_035_931_709
        let keyDown = try fnSystemActionEcho(keyDown: true, timestamp: timestamp)
        monitor.beginEvent(type: .keyDown, event: keyDown, isSynthetic: false)
        monitor.endEvent()
        XCTAssertEqual(
            monitor.validationFailureReason(since: token),
            "stopTailIncomplete"
        )
        let keyUp = try fnSystemActionEcho(keyDown: false, timestamp: timestamp)
        monitor.beginEvent(type: .keyUp, event: keyUp, isSynthetic: false)
        monitor.endEvent()

        XCTAssertTrue(monitor.isUnchanged(since: token))
    }

    func testFnReleaseTailRejectsSystemActionEchoWithMismatchedTimestamp() throws {
        let monitor = TextInjectionEngine.InputActivityMonitor()
        monitor.startForTesting()

        let fnReleased = try keyboardEvent(keyCode: 63, keyDown: false)
        monitor.beginEvent(type: .flagsChanged, event: fnReleased, isSynthetic: false)
        XCTAssertTrue(monitor.authorizeCurrentEventForStopCapture())
        let token = try XCTUnwrap(monitor.captureToken())
        XCTAssertTrue(monitor.allowCurrentStopGestureTail(since: token))
        monitor.endEvent()

        let keyDown = try fnSystemActionEcho(keyDown: true, timestamp: 100)
        monitor.beginEvent(type: .keyDown, event: keyDown, isSynthetic: false)
        monitor.endEvent()
        let keyUp = try fnSystemActionEcho(keyDown: false, timestamp: 101)
        monitor.beginEvent(type: .keyUp, event: keyUp, isSynthetic: false)
        monitor.endEvent()

        XCTAssertFalse(monitor.isUnchanged(since: token))
    }

    func testFnReleaseTailAllowsOnlyTwoMatchingReconciliationEvents() throws {
        let monitor = TextInjectionEngine.InputActivityMonitor()
        monitor.startForTesting()

        let fnReleased = try keyboardEvent(keyCode: 63, keyDown: false)
        monitor.beginEvent(type: .flagsChanged, event: fnReleased, isSynthetic: false)
        XCTAssertTrue(monitor.authorizeCurrentEventForStopCapture())
        let token = try XCTUnwrap(monitor.captureToken())
        monitor.allowCurrentStopGestureTail(since: token)
        monitor.endEvent()

        let matchingKeyUp = try keyboardEvent(keyCode: 63, keyDown: false)
        monitor.beginEvent(type: .keyUp, event: matchingKeyUp, isSynthetic: false)
        monitor.endEvent()
        let reconciliationEcho = try keyboardEvent(keyCode: 255, keyDown: false)
        monitor.beginEvent(
            type: .flagsChanged,
            event: reconciliationEcho,
            isSynthetic: false
        )
        monitor.endEvent()
        XCTAssertTrue(monitor.isUnchanged(since: token))

        let thirdEcho = try keyboardEvent(keyCode: 63, keyDown: false)
        monitor.beginEvent(type: .flagsChanged, event: thirdEcho, isSynthetic: false)
        monitor.endEvent()
        XCTAssertFalse(monitor.isUnchanged(since: token))
    }

    func testFnReleaseTailAllowsTwoConsecutiveFlagsChangedEchoes() throws {
        let monitor = TextInjectionEngine.InputActivityMonitor()
        monitor.startForTesting()

        let fnReleased = try keyboardEvent(keyCode: 63, keyDown: false)
        monitor.beginEvent(type: .flagsChanged, event: fnReleased, isSynthetic: false)
        XCTAssertTrue(monitor.authorizeCurrentEventForStopCapture())
        let token = try XCTUnwrap(monitor.captureToken())
        XCTAssertTrue(monitor.allowCurrentStopGestureTail(since: token))
        monitor.endEvent()

        for keyCode: CGKeyCode in [63, 255] {
            let echo = try keyboardEvent(keyCode: keyCode, keyDown: false)
            monitor.beginEvent(type: .flagsChanged, event: echo, isSynthetic: false)
            monitor.endEvent()
        }
        XCTAssertTrue(monitor.isUnchanged(since: token))
    }

    func testFnReleaseTailCannotBridgeUnrelatedInputBetweenEchoes() throws {
        let keyDown = try keyboardEvent(keyCode: 48, keyDown: true)
        let mouseDown = try XCTUnwrap(CGEvent(
            mouseEventSource: nil,
            mouseType: .leftMouseDown,
            mouseCursorPosition: .zero,
            mouseButton: .left
        ))
        let scroll = try XCTUnwrap(CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 1,
            wheel1: 1,
            wheel2: 0,
            wheel3: 0
        ))
        let systemDefined = try XCTUnwrap(CGEvent(source: nil))
        let inputs: [(CGEventType, CGEvent)] = [
            (.keyDown, keyDown),
            (.leftMouseDown, mouseDown),
            (.scrollWheel, scroll),
            (try XCTUnwrap(CGEventType(rawValue: 14)), systemDefined),
        ]

        for (type, input) in inputs {
            let monitor = TextInjectionEngine.InputActivityMonitor()
            monitor.startForTesting()
            let fnReleased = try keyboardEvent(keyCode: 63, keyDown: false)
            monitor.beginEvent(type: .flagsChanged, event: fnReleased, isSynthetic: false)
            XCTAssertTrue(monitor.authorizeCurrentEventForStopCapture())
            let token = try XCTUnwrap(monitor.captureToken())
            XCTAssertTrue(monitor.allowCurrentStopGestureTail(since: token))
            monitor.endEvent()

            let firstEcho = try keyboardEvent(keyCode: 63, keyDown: false)
            monitor.beginEvent(type: .flagsChanged, event: firstEcho, isSynthetic: false)
            monitor.endEvent()
            XCTAssertTrue(monitor.isUnchanged(since: token))

            monitor.beginEvent(type: type, event: input, isSynthetic: false)
            monitor.endEvent()
            XCTAssertFalse(
                monitor.isUnchanged(since: token),
                "event type \(type.rawValue) must terminate the stop tail"
            )
        }
    }

    func testFnReleaseTailRejectsUnrelatedModifierAndNewFnPress() throws {
        func capturedMonitor() throws -> (
            TextInjectionEngine.InputActivityMonitor,
            TextInjectionEngine.InputActivityMonitor.Token
        ) {
            let monitor = TextInjectionEngine.InputActivityMonitor()
            monitor.startForTesting()
            let fnReleased = try keyboardEvent(keyCode: 63, keyDown: false)
            monitor.beginEvent(type: .flagsChanged, event: fnReleased, isSynthetic: false)
            XCTAssertTrue(monitor.authorizeCurrentEventForStopCapture())
            let token = try XCTUnwrap(monitor.captureToken())
            monitor.allowCurrentStopGestureTail(since: token)
            monitor.endEvent()
            return (monitor, token)
        }

        let (unrelatedMonitor, unrelatedToken) = try capturedMonitor()
        let capsLockRelease = try keyboardEvent(keyCode: 57, keyDown: false)
        unrelatedMonitor.beginEvent(
            type: .flagsChanged,
            event: capsLockRelease,
            isSynthetic: false
        )
        unrelatedMonitor.endEvent()
        XCTAssertFalse(unrelatedMonitor.isUnchanged(since: unrelatedToken))

        let (newPressMonitor, newPressToken) = try capturedMonitor()
        let newFnPress = try keyboardEvent(
            keyCode: 63,
            keyDown: true,
            flags: .maskSecondaryFn
        )
        newPressMonitor.beginEvent(
            type: .flagsChanged,
            event: newFnPress,
            isSynthetic: false
        )
        newPressMonitor.endEvent()
        XCTAssertFalse(newPressMonitor.isUnchanged(since: newPressToken))
    }

    func testUnrelatedReleaseCannotMasqueradeAsStopGestureTail() throws {
        let monitor = TextInjectionEngine.InputActivityMonitor()
        monitor.startForTesting()

        let stopKeyDown = try keyboardEvent(keyCode: 43, keyDown: true)
        monitor.beginEvent(type: .keyDown, event: stopKeyDown, isSynthetic: false)
        XCTAssertTrue(monitor.authorizeCurrentEventForStopCapture())
        let token = try XCTUnwrap(monitor.captureToken())
        monitor.allowCurrentStopGestureTail(since: token)
        monitor.endEvent()

        let unrelatedKeyUp = try keyboardEvent(keyCode: 48, keyDown: false)
        monitor.beginEvent(type: .keyUp, event: unrelatedKeyUp, isSynthetic: false)
        monitor.endEvent()
        XCTAssertFalse(monitor.isUnchanged(since: token))
    }

    func testUnrelatedCurrentEventCannotArmAReleaseTail() throws {
        let monitor = TextInjectionEngine.InputActivityMonitor()
        monitor.startForTesting()

        let unrelatedKeyDown = try keyboardEvent(keyCode: 43, keyDown: true)
        monitor.beginEvent(type: .keyDown, event: unrelatedKeyDown, isSynthetic: false)
        let token = try XCTUnwrap(monitor.captureToken())
        monitor.allowCurrentStopGestureTail(since: token)
        monitor.endEvent()

        let matchingKeyUp = try keyboardEvent(keyCode: 43, keyDown: false)
        monitor.beginEvent(type: .keyUp, event: matchingKeyUp, isSynthetic: false)
        monitor.endEvent()
        XCTAssertFalse(monitor.isUnchanged(since: token))
    }

    func testNewRightCommandCannotHideInsideLeftCommandReleaseTail() throws {
        let monitor = TextInjectionEngine.InputActivityMonitor()
        monitor.startForTesting()
        let leftCommandFlags = CGEventFlags(rawValue:
            CGEventFlags.maskCommand.rawValue | ModeBinding.deviceLeftCommandMask
        )
        let stopKeyDown = try keyboardEvent(
            keyCode: 43,
            keyDown: true,
            flags: leftCommandFlags
        )
        monitor.beginEvent(type: .keyDown, event: stopKeyDown, isSynthetic: false)
        XCTAssertTrue(monitor.authorizeCurrentEventForStopCapture())
        let token = try XCTUnwrap(monitor.captureToken())
        monitor.allowCurrentStopGestureTail(since: token)
        monitor.endEvent()

        let bothCommandFlags = CGEventFlags(rawValue:
            CGEventFlags.maskCommand.rawValue
                | ModeBinding.deviceLeftCommandMask
                | ModeBinding.deviceRightCommandMask
        )
        let rightCommandDown = try keyboardEvent(
            keyCode: 54,
            keyDown: true,
            flags: bothCommandFlags
        )
        monitor.beginEvent(
            type: .flagsChanged,
            event: rightCommandDown,
            isSynthetic: false
        )
        monitor.endEvent()
        XCTAssertFalse(monitor.isUnchanged(since: token))
    }

    func testMarkedSyntheticShortcutDoesNotInvalidateToken() throws {
        let monitor = TextInjectionEngine.InputActivityMonitor()
        monitor.startForTesting()
        let token = try XCTUnwrap(monitor.captureToken())

        let syntheticPaste = try keyboardEvent(
            keyCode: 9,
            keyDown: true,
            flags: .maskCommand
        )
        TextInjectionEngine.markAsSyntheticInput(syntheticPaste)
        XCTAssertTrue(TextInjectionEngine.isSyntheticInput(syntheticPaste))
        monitor.beginEvent(
            type: .keyDown,
            event: syntheticPaste,
            isSynthetic: TextInjectionEngine.isSyntheticInput(syntheticPaste)
        )
        monitor.endEvent()

        XCTAssertTrue(monitor.isUnchanged(since: token))
    }

    func testTapRestartInvalidatesEveryExistingToken() throws {
        let monitor = TextInjectionEngine.InputActivityMonitor()
        XCTAssertNil(monitor.captureToken())
        monitor.startForTesting()
        let oldToken = try XCTUnwrap(monitor.captureToken())

        monitor.stop()
        XCTAssertFalse(monitor.isUnchanged(since: oldToken))
        XCTAssertNil(monitor.captureToken())

        monitor.startForTesting()
        XCTAssertFalse(monitor.isUnchanged(since: oldToken))
        XCTAssertNotNil(monitor.captureToken())
    }
}
