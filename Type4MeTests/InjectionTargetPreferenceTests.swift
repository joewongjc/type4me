import XCTest
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

        UserDefaults.standard.set("en", forKey: "tf_language")
        XCTAssertEqual(InjectionTargetPreference.recordingStart.displayName, "App at Recording Start")
        XCTAssertEqual(InjectionTargetPreference.recordingEnd.displayName, "Focused Field at Recording End")
        XCTAssertTrue(InjectionTargetPreference.recordingEnd.detail.contains("clipboard"))
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

final class ConfirmedInjectionTargetEvidenceTests: XCTestCase {
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

    func testFocusedWindowIdentityDoesNotDependOnUnreliableAXFocusedAttribute() {
        XCTAssertTrue(TextInjectionEngine.shouldUseOpaquePasteDestination(
            role: "AXWindow",
            subrole: nil,
            pasteCommandAvailable: true,
            hasAccessibleEditableDescendant: false,
            focusedElementMatchesWindow: true,
            elementPIDMatchesFrontmost: true
        ))
        XCTAssertTrue(TextInjectionEngine.shouldUseOpaquePasteDestination(
            role: "AXSheet",
            subrole: nil,
            pasteCommandAvailable: true,
            hasAccessibleEditableDescendant: false,
            focusedElementMatchesWindow: true,
            elementPIDMatchesFrontmost: true
        ))
    }

    func testOpaqueDestinationRequiresAStandardPasteCommand() {
        XCTAssertFalse(TextInjectionEngine.shouldUseOpaquePasteDestination(
            role: "AXWindow",
            subrole: nil,
            pasteCommandAvailable: false,
            hasAccessibleEditableDescendant: false,
            focusedElementMatchesWindow: true,
            elementPIDMatchesFrontmost: true
        ))
    }

    func testOpaqueDestinationDoesNotGuessInsideAnAccessibleWindow() {
        XCTAssertFalse(TextInjectionEngine.shouldUseOpaquePasteDestination(
            role: "AXWindow",
            subrole: nil,
            pasteCommandAvailable: true,
            hasAccessibleEditableDescendant: true,
            focusedElementMatchesWindow: true,
            elementPIDMatchesFrontmost: true
        ))
    }

    func testOpaqueDestinationRejectsAnIncompleteEditorScan() {
        XCTAssertFalse(TextInjectionEngine.shouldUseOpaquePasteDestination(
            role: "AXWindow",
            subrole: nil,
            pasteCommandAvailable: true,
            hasAccessibleEditableDescendant: false,
            editableDescendantScanComplete: false,
            focusedElementMatchesWindow: true,
            elementPIDMatchesFrontmost: true
        ))
    }

    func testWebAreaCannotMasqueradeAsAnOpaqueTextDestination() {
        XCTAssertFalse(TextInjectionEngine.shouldUseOpaquePasteDestination(
            role: "AXWebArea",
            subrole: nil,
            pasteCommandAvailable: true,
            hasAccessibleEditableDescendant: false,
            focusedElementMatchesWindow: false,
            elementPIDMatchesFrontmost: true
        ))
    }

    func testOpaqueSecureOrCrossProcessDestinationIsRejected() {
        XCTAssertFalse(TextInjectionEngine.shouldUseOpaquePasteDestination(
            role: "AXWindow",
            subrole: "AXSecureTextField",
            pasteCommandAvailable: true,
            hasAccessibleEditableDescendant: false,
            focusedElementMatchesWindow: true,
            elementPIDMatchesFrontmost: true
        ))
        XCTAssertFalse(TextInjectionEngine.shouldUseOpaquePasteDestination(
            role: "AXWindow",
            subrole: nil,
            pasteCommandAvailable: true,
            hasAccessibleEditableDescendant: false,
            focusedElementMatchesWindow: true,
            elementPIDMatchesFrontmost: false
        ))
    }

    func testOpaqueDestinationContinuityTracksPointerChangesNotKeyDowns() {
        let invalidatingTypes = TextInjectionEngine.opaqueTargetInvalidatingInputEventTypes

        XCTAssertTrue(invalidatingTypes.contains(.leftMouseDown))
        XCTAssertTrue(invalidatingTypes.contains(.rightMouseDown))
        XCTAssertTrue(invalidatingTypes.contains(.otherMouseDown))
        XCTAssertFalse(invalidatingTypes.contains(.keyDown))
    }
}
