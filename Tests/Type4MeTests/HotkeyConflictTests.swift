import Cocoa
import XCTest
@testable import Type4Me

final class HotkeyConflictTests: XCTestCase {

    func testModifierOnlyHotkeyDetectsPrefixConflict() {
        XCTAssertTrue(
            ModeBinding.hasModifierPrefixConflict(
                keyCode: 59,
                modifiers: 0,
                otherKeyCode: 58,
                otherModifiers: CGEventFlags.maskControl.rawValue
            )
        )
    }

    func testModifierOnlyHotkeyDetectsRegularKeyPrefixConflict() {
        XCTAssertTrue(
            ModeBinding.hasModifierPrefixConflict(
                keyCode: 59,
                modifiers: 0,
                otherKeyCode: 49,
                otherModifiers: CGEventFlags.maskControl.rawValue
            )
        )
    }

    func testFnModifierOnlyHotkeyDetectsRegularKeyPrefixConflict() {
        XCTAssertTrue(
            ModeBinding.hasModifierPrefixConflict(
                keyCode: 63,
                modifiers: 0,
                otherKeyCode: 49,
                otherModifiers: CGEventFlags.maskSecondaryFn.rawValue
            )
        )
    }

    func testFnModifierOnlyHotkeyDetectsModifierComboPrefixConflict() {
        XCTAssertTrue(
            ModeBinding.hasModifierPrefixConflict(
                keyCode: 63,
                modifiers: 0,
                otherKeyCode: 56,
                otherModifiers: CGEventFlags.maskSecondaryFn.rawValue
            )
        )
    }

    func testLongerModifierBindingIsNotPrefixOfShorterRegularCombo() {
        XCTAssertFalse(
            ModeBinding.modifierBindingIsPrefix(
                modifierKeyCode: 58,
                modifierModifiers: CGEventFlags.maskControl.rawValue,
                otherKeyCode: 49,
                otherModifiers: CGEventFlags.maskControl.rawValue
            )
        )
    }

    func testMouseAndMediaKeysAreNotPrefixConflicts() {
        XCTAssertFalse(
            ModeBinding.hasModifierPrefixConflict(
                keyCode: 59,
                modifiers: 0,
                otherKeyCode: ModeBinding.mouseKeyCode(for: 2),
                otherModifiers: CGEventFlags.maskControl.rawValue
            )
        )
        XCTAssertFalse(
            ModeBinding.hasModifierPrefixConflict(
                keyCode: 59,
                modifiers: 0,
                otherKeyCode: ModeBinding.mediaKeyCode(for: 16),
                otherModifiers: CGEventFlags.maskControl.rawValue
            )
        )
    }

    func testRegularKeyWithoutModifiersIsNotPrefixConflict() {
        XCTAssertFalse(
            ModeBinding.hasModifierPrefixConflict(
                keyCode: 59,
                modifiers: 0,
                otherKeyCode: 49,
                otherModifiers: 0
            )
        )
    }

    func testDifferentSingleModifiersAreNotPrefixConflicts() {
        XCTAssertFalse(
            ModeBinding.hasModifierPrefixConflict(
                keyCode: 59,
                modifiers: 0,
                otherKeyCode: 55,
                otherModifiers: 0
            )
        )
    }

    func testExactDuplicateModifierCombosAreNotPrefixConflicts() {
        XCTAssertFalse(
            ModeBinding.hasModifierPrefixConflict(
                keyCode: 59,
                modifiers: CGEventFlags.maskAlternate.rawValue,
                otherKeyCode: 58,
                otherModifiers: CGEventFlags.maskControl.rawValue
            )
        )
    }

    func testFnModifierIsPreservedForRegularKeyCombos() {
        let flags = ModeBinding.normalizedModifierFlags(
            CGEventFlags(rawValue: UInt64(NSEvent.ModifierFlags.function.rawValue))
        )

        XCTAssertTrue(flags.contains(CGEventFlags.maskSecondaryFn))
    }

    func testSyntheticFnModifierIsIgnoredForFunctionKeys() {
        let flags = ModeBinding.normalizedModifierFlags(
            CGEventFlags.maskSecondaryFn,
            forKeyCode: 111
        )

        XCTAssertFalse(flags.contains(CGEventFlags.maskSecondaryFn))
        XCTAssertTrue(flags.isEmpty)
    }

    func testStoredFnModifierIsIgnoredForFunctionKeyBindings() {
        let flags = ModeBinding.normalizedModifierFlags(
            CGEventFlags(rawValue: UInt64(NSEvent.ModifierFlags.function.rawValue)),
            forKeyCode: 111
        )

        XCTAssertTrue(flags.isEmpty)
    }

    func testRecorderStripsSyntheticFnFromF12Capture() {
        let flags = HotkeyRecorderView.sanitizedModifierFlags(
            [.function],
            forKeyCode: 111
        )

        XCTAssertFalse(flags.contains(.function))
        XCTAssertTrue(flags.isEmpty)
    }

    func testRecorderPreservesFnForRegularKeyCapture() {
        let flags = HotkeyRecorderView.sanitizedModifierFlags(
            [.function],
            forKeyCode: 49
        )

        XCTAssertTrue(flags.contains(.function))
    }

    func testFunctionKeyBindingsIgnoreSyntheticFnForDuplicateChecks() {
        XCTAssertTrue(
            ModeBinding.hotkeysAreEquivalent(
                keyCode: 111,
                modifiers: 0,
                otherKeyCode: 111,
                otherModifiers: CGEventFlags.maskSecondaryFn.rawValue
            )
        )

        XCTAssertTrue(
            ModeBinding.hotkeysAreEquivalent(
                keyCode: 111,
                modifiers: CGEventFlags.maskControl.rawValue,
                otherKeyCode: 111,
                otherModifiers: CGEventFlags.maskControl.union(.maskSecondaryFn).rawValue
            )
        )
    }

    func testRegularKeyBindingsStillDistinguishFnCombos() {
        XCTAssertFalse(
            ModeBinding.hotkeysAreEquivalent(
                keyCode: 49,
                modifiers: 0,
                otherKeyCode: 49,
                otherModifiers: CGEventFlags.maskSecondaryFn.rawValue
            )
        )
    }

    func testMouseAndMediaKeyDuplicateChecksIgnoreStoredModifierNoise() {
        XCTAssertTrue(
            ModeBinding.hotkeysAreEquivalent(
                keyCode: ModeBinding.mouseKeyCode(for: 2),
                modifiers: 0,
                otherKeyCode: ModeBinding.mouseKeyCode(for: 2),
                otherModifiers: CGEventFlags.maskControl.rawValue
            )
        )

        XCTAssertTrue(
            ModeBinding.hotkeysAreEquivalent(
                keyCode: ModeBinding.mediaKeyCode(for: 16),
                modifiers: 0,
                otherKeyCode: ModeBinding.mediaKeyCode(for: 16),
                otherModifiers: CGEventFlags.maskSecondaryFn.rawValue
            )
        )
    }

    // MARK: - Multi-binding conflict semantics

    /// Detecting a duplicate hotkey within the same mode's binding list, excluding the
    /// binding currently being edited.
    func testSameModeDuplicateBindingIsDetected() {
        let editing = HotkeyBinding(keyCode: 20, modifiers: 524288, style: .toggle)
        let sibling = HotkeyBinding(keyCode: 20, modifiers: 524288, style: .hold)
        let bindings = [editing, sibling]

        // A newly recorded 20+Ctrl duplicates `sibling` (excluding `editing`).
        let isDuplicate = bindings.contains { b in
            b.id != editing.id
                && ModeBinding.hotkeysAreEquivalent(
                    keyCode: 20, modifiers: 524288,
                    otherKeyCode: b.keyCode, otherModifiers: b.modifiers
                )
        }
        XCTAssertTrue(isDuplicate)
    }

    func testSameModeDistinctBindingsAreNotDuplicates() {
        let a = HotkeyBinding(keyCode: 20, modifiers: 524288, style: .toggle)
        let b = HotkeyBinding(keyCode: 21, modifiers: 524288, style: .toggle)
        let bindings = [a, b]

        let isDuplicate = bindings.contains { candidate in
            candidate.id != a.id
                && ModeBinding.hotkeysAreEquivalent(
                    keyCode: 20, modifiers: 524288,
                    otherKeyCode: candidate.keyCode, otherModifiers: candidate.modifiers
                )
        }
        XCTAssertFalse(isDuplicate)
    }

    /// Cross-mode transfer removes only the single conflicting binding, leaving siblings intact.
    func testCrossModeTransferRemovesOnlyConflictingBinding() {
        var other = ProcessingMode(
            id: UUID(), name: "Other", prompt: "{text}", isBuiltin: false,
            hotkeyBindings: [
                HotkeyBinding(keyCode: 20, modifiers: 524288, style: .toggle),
                HotkeyBinding(keyCode: 21, modifiers: 524288, style: .toggle),
            ]
        )

        other.hotkeyBindings.removeAll { b in
            ModeBinding.hotkeysAreEquivalent(
                keyCode: 20, modifiers: 524288,
                otherKeyCode: b.keyCode, otherModifiers: b.modifiers
            )
        }

        XCTAssertEqual(other.hotkeyBindings.count, 1)
        XCTAssertEqual(other.hotkeyBindings.first?.keyCode, 21)
    }

    func testLeftAndRightCommandAreNotEquivalentHotkeys() {
        XCTAssertFalse(
            ModeBinding.hotkeysAreEquivalent(
                keyCode: 55,
                modifiers: 0,
                otherKeyCode: 54,
                otherModifiers: 0
            )
        )
    }

    func testLeftAndRightOptionAreNotEquivalentHotkeys() {
        XCTAssertFalse(
            ModeBinding.hotkeysAreEquivalent(
                keyCode: 58,
                modifiers: 0,
                otherKeyCode: 61,
                otherModifiers: 0
            )
        )
    }

    func testLeftAndRightShiftAreNotEquivalentHotkeys() {
        XCTAssertFalse(
            ModeBinding.hotkeysAreEquivalent(
                keyCode: 56,
                modifiers: 0,
                otherKeyCode: 60,
                otherModifiers: 0
            )
        )
    }

    func testLeftAndRightControlAreNotEquivalentHotkeys() {
        XCTAssertFalse(
            ModeBinding.hotkeysAreEquivalent(
                keyCode: 59,
                modifiers: 0,
                otherKeyCode: 62,
                otherModifiers: 0
            )
        )
    }

    func testModifierKeyCodesExtractionFromDeviceMasks() {
        let leftCmdRaw = ModeBinding.deviceLeftCommandMask | CGEventFlags.maskCommand.rawValue
        let rightCmdRaw = ModeBinding.deviceRightCommandMask | CGEventFlags.maskCommand.rawValue
        let bothCmdRaw = ModeBinding.deviceLeftCommandMask | ModeBinding.deviceRightCommandMask | CGEventFlags.maskCommand.rawValue

        XCTAssertEqual(
            ModeBinding.modifierKeyCodes(forRawFlags: leftCmdRaw, standardFlags: [.maskCommand]),
            [55]
        )
        XCTAssertEqual(
            ModeBinding.modifierKeyCodes(forRawFlags: rightCmdRaw, standardFlags: [.maskCommand]),
            [54]
        )
        XCTAssertEqual(
            ModeBinding.modifierKeyCodes(forRawFlags: bothCmdRaw, standardFlags: [.maskCommand]),
            [55, 54]
        )

        let comboRaw = ModeBinding.deviceLeftShiftMask | CGEventFlags.maskShift.rawValue | CGEventFlags.maskSecondaryFn.rawValue
        XCTAssertEqual(
            ModeBinding.modifierKeyCodes(forRawFlags: comboRaw, standardFlags: [.maskShift, .maskSecondaryFn]),
            [56, 63]
        )
    }

    func testIsModifierPressedDistinguishesLeftAndRightSides() {
        let leftCmdFlags = CGEventFlags(rawValue: ModeBinding.deviceLeftCommandMask | CGEventFlags.maskCommand.rawValue)
        let rightCmdFlags = CGEventFlags(rawValue: ModeBinding.deviceRightCommandMask | CGEventFlags.maskCommand.rawValue)

        XCTAssertTrue(ModeBinding.isModifierPressed(keyCode: 55, flags: leftCmdFlags))
        XCTAssertFalse(ModeBinding.isModifierPressed(keyCode: 54, flags: leftCmdFlags))

        XCTAssertTrue(ModeBinding.isModifierPressed(keyCode: 54, flags: rightCmdFlags))
        XCTAssertFalse(ModeBinding.isModifierPressed(keyCode: 55, flags: rightCmdFlags))
    }
}
