import XCTest
@testable import Type4Me

final class TextInjectionOutcomeTests: XCTestCase {

    func testTerminalWithAXUnknownRoleIsInferredAsInserted() {
        // Reproduce real kooky terminal scenario from debug.log:
        // bundle=com.iamcorey.kooky role=AXUnknown editable=false hasFocus=true valueLength=-1
        let before = TextInjectionEngine.FocusedElementSnapshot(
            bundleIdentifier: "com.iamcorey.kooky",
            role: "AXUnknown",
            value: nil,
            isEditable: false,
            hasFocusedElement: true
        )
        let after = TextInjectionEngine.FocusedElementSnapshot(
            bundleIdentifier: "com.iamcorey.kooky",
            role: "AXUnknown",
            value: nil,
            isEditable: false,
            hasFocusedElement: true
        )

        let outcome = TextInjectionEngine.inferInjectionOutcome(
            before: before,
            after: after,
            pastedText: "echo hello"
        )

        XCTAssertEqual(outcome, .inserted)
    }

    func testTerminalWithNilRoleIsInferredAsInserted() {
        let before = TextInjectionEngine.FocusedElementSnapshot(
            bundleIdentifier: "com.mitchellh.ghostty",
            role: nil,
            value: nil,
            isEditable: false,
            hasFocusedElement: true
        )
        let after = TextInjectionEngine.FocusedElementSnapshot(
            bundleIdentifier: "com.mitchellh.ghostty",
            role: nil,
            value: nil,
            isEditable: false,
            hasFocusedElement: true
        )

        let outcome = TextInjectionEngine.inferInjectionOutcome(
            before: before,
            after: after,
            pastedText: "git status"
        )

        XCTAssertEqual(outcome, .inserted)
    }

    func testStandardEditableFieldIsInferredAsInserted() {
        let before = TextInjectionEngine.FocusedElementSnapshot(
            bundleIdentifier: "ru.keepcoder.Telegram",
            role: "AXTextArea",
            value: "existing",
            isEditable: true,
            hasFocusedElement: true
        )
        let after = TextInjectionEngine.FocusedElementSnapshot(
            bundleIdentifier: "ru.keepcoder.Telegram",
            role: "AXTextArea",
            value: "existing pasted",
            isEditable: true,
            hasFocusedElement: true
        )

        let outcome = TextInjectionEngine.inferInjectionOutcome(
            before: before,
            after: after,
            pastedText: " pasted"
        )

        XCTAssertEqual(outcome, .inserted)
    }

    func testValueChangedIsInferredAsInserted() {
        let before = TextInjectionEngine.FocusedElementSnapshot(
            bundleIdentifier: "com.apple.TextEdit",
            role: "AXTextArea",
            value: "before",
            isEditable: false,
            hasFocusedElement: true
        )
        let after = TextInjectionEngine.FocusedElementSnapshot(
            bundleIdentifier: "com.apple.TextEdit",
            role: "AXTextArea",
            value: "before after",
            isEditable: false,
            hasFocusedElement: true
        )

        let outcome = TextInjectionEngine.inferInjectionOutcome(
            before: before,
            after: after,
            pastedText: " after"
        )

        XCTAssertEqual(outcome, .inserted)
    }

    func testBlindAppWithoutFocusedElementIsInferredAsInserted() {
        // WeChat AX blind case: hasFocusedElement = false
        let before = TextInjectionEngine.FocusedElementSnapshot(
            bundleIdentifier: "com.tencent.xinWeChat",
            role: nil,
            value: nil,
            isEditable: false,
            hasFocusedElement: false
        )
        let after = TextInjectionEngine.FocusedElementSnapshot(
            bundleIdentifier: "com.tencent.xinWeChat",
            role: nil,
            value: nil,
            isEditable: false,
            hasFocusedElement: false
        )

        let outcome = TextInjectionEngine.inferInjectionOutcome(
            before: before,
            after: after,
            pastedText: "微信消息"
        )

        XCTAssertEqual(outcome, .inserted)
    }

    func testKnownNonEditableControlIsInferredAsCopiedToClipboard() {
        // When focused on a standard non-editable button or static label
        let before = TextInjectionEngine.FocusedElementSnapshot(
            bundleIdentifier: "com.apple.finder",
            role: "AXButton",
            value: nil,
            isEditable: false,
            hasFocusedElement: true
        )
        let after = TextInjectionEngine.FocusedElementSnapshot(
            bundleIdentifier: "com.apple.finder",
            role: "AXButton",
            value: nil,
            isEditable: false,
            hasFocusedElement: true
        )

        let outcome = TextInjectionEngine.inferInjectionOutcome(
            before: before,
            after: after,
            pastedText: "test"
        )

        XCTAssertEqual(outcome, .copiedToClipboard)
    }
    func testDesktopWithoutBundleIdentifierIsInferredAsCopiedToClipboard() {
        let before = TextInjectionEngine.FocusedElementSnapshot(
            bundleIdentifier: nil,
            role: nil,
            value: nil,
            isEditable: false,
            hasFocusedElement: false
        )
        let after = TextInjectionEngine.FocusedElementSnapshot(
            bundleIdentifier: nil,
            role: nil,
            value: nil,
            isEditable: false,
            hasFocusedElement: false
        )

        let outcome = TextInjectionEngine.inferInjectionOutcome(
            before: before,
            after: after,
            pastedText: "test"
        )

        XCTAssertEqual(outcome, .copiedToClipboard)
    }

    func testOpaqueNilSnapshotIsInferredAsInserted() {
        let outcome1 = TextInjectionEngine.inferInjectionOutcome(
            before: nil,
            after: nil,
            pastedText: "test"
        )
        XCTAssertEqual(outcome1, .inserted)

        let snapshot = TextInjectionEngine.FocusedElementSnapshot(
            bundleIdentifier: "com.iamcorey.kooky",
            role: "AXUnknown",
            hasFocusedElement: true
        )
        let outcome2 = TextInjectionEngine.inferInjectionOutcome(
            before: snapshot,
            after: nil,
            pastedText: "test"
        )
        XCTAssertEqual(outcome2, .inserted)
    }

    func testVariousKnownNonEditableRolesAreInferredAsCopiedToClipboard() {
        let nonEditableRoles = [
            "AXApplication",
            "AXWindow",
            "AXGroup",
            "AXScrollArea",
            "AXSheet",
            "AXButton",
            "AXStaticText",
            "AXImage",
            "AXProgressIndicator",
            "AXSlider",
            "AXCheckBox",
            "AXRadioButton",
            "AXTable",
            "AXOutline",
        ]
        for role in nonEditableRoles {
            let before = TextInjectionEngine.FocusedElementSnapshot(
                bundleIdentifier: "com.apple.finder",
                role: role,
                value: nil,
                isEditable: false,
                hasFocusedElement: true
            )
            let after = TextInjectionEngine.FocusedElementSnapshot(
                bundleIdentifier: "com.apple.finder",
                role: role,
                value: nil,
                isEditable: false,
                hasFocusedElement: true
            )

            let outcome = TextInjectionEngine.inferInjectionOutcome(
                before: before,
                after: after,
                pastedText: "test"
            )
            XCTAssertEqual(
                outcome,
                .copiedToClipboard,
                "Role \(role) should be classified as copiedToClipboard when non-editable"
            )
        }
    }

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
        XCTAssertEqual(
            TextInjectionEngine.finalizeOutcome(.pasteAttemptedClipboardRetained, retention: .restoreOriginal),
            .pasteAttemptedClipboardRetained
        )
    }
}
