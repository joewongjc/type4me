import AppKit
import ApplicationServices
import Carbon.HIToolbox

enum InjectionMethod: Sendable {
    case keyboard
    case clipboard
}

final class TextInjectionEngine: @unchecked Sendable {

    private struct FocusedElementSnapshot {
        let bundleIdentifier: String?
        let role: String?
        let value: String?
        let isEditable: Bool
        /// true when AX successfully found a focused UI element; false when
        /// no element was found (e.g. desktop, no focused window).
        let hasFocusedElement: Bool
    }

    private struct ClipboardSnapshot {
        struct Item {
            let types: [NSPasteboard.PasteboardType]
            let data: [NSPasteboard.PasteboardType: Data]
        }
        let items: [Item]
        let changeCount: Int

        static func capture() -> ClipboardSnapshot {
            let pb = NSPasteboard.general
            let changeCount = pb.changeCount
            var items: [Item] = []
            for pbItem in pb.pasteboardItems ?? [] {
                var dataMap: [NSPasteboard.PasteboardType: Data] = [:]
                let types = pbItem.types
                for type in types {
                    if let data = pbItem.data(forType: type) {
                        dataMap[type] = data
                    }
                }
                items.append(Item(types: types, data: dataMap))
            }
            return ClipboardSnapshot(items: items, changeCount: changeCount)
        }

        /// Restore clipboard to captured state.
        /// - Parameter expectedChangeCount: the changeCount observed right after
        ///   our `copyToClipboard` call. If the clipboard has been modified by
        ///   another app since then, restoration is skipped.
        func restore(expectedChangeCount: Int) {
            let pb = NSPasteboard.general
            guard !items.isEmpty else { return }
            // Don't restore if another app changed the clipboard after our write
            guard pb.changeCount == expectedChangeCount else { return }
            pb.clearContents()
            for item in items {
                let pbItem = NSPasteboardItem()
                for type in item.types {
                    if let data = item.data[type] {
                        pbItem.setData(data, forType: type)
                    }
                }
                pb.writeObjects([pbItem])
            }
        }
    }

    // MARK: - Public

    var method: InjectionMethod = .clipboard

    /// Inject text into the currently focused input field.
    func inject(_ text: String) -> InjectionOutcome {
        guard !text.isEmpty else { return .inserted }
        switch method {
        case .keyboard:
            injectViaKeyboard(text)
            return .inserted
        case .clipboard:
            return injectViaClipboard(text)
        }
    }

    /// Copy text to the system clipboard (used at session end).
    func copyToClipboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    // MARK: - Keyboard simulation

    private func injectViaKeyboard(_ text: String) {
        let utf16 = Array(text.utf16)
        let chunkSize = 16

        for offset in stride(from: 0, to: utf16.count, by: chunkSize) {
            let end = min(offset + chunkSize, utf16.count)
            var chunk = Array(utf16[offset..<end])
            let length = chunk.count

            guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
                  let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
            else { continue }

            keyDown.keyboardSetUnicodeString(stringLength: length, unicodeString: &chunk)
            keyUp.keyboardSetUnicodeString(stringLength: length, unicodeString: &chunk)

            keyDown.post(tap: .cghidEventTap)
            keyUp.post(tap: .cghidEventTap)

            if end < utf16.count {
                usleep(10_000)
            }
        }
    }

    // MARK: - Clipboard injection

    private func injectViaClipboard(_ text: String) -> InjectionOutcome {
        let savedClipboard = ClipboardSnapshot.capture()
        let beforePaste = captureFocusedElementSnapshot()

        copyToClipboard(text)
        // Capture changeCount AFTER our write, not before.
        // clearContents() + setString() may increment by 1 or 2 depending on macOS version.
        let postWriteChangeCount = NSPasteboard.general.changeCount
        usleep(50_000)
        simulatePaste()
        usleep(100_000)

        let afterPaste = captureFocusedElementSnapshot()
        let outcome = inferInjectionOutcome(before: beforePaste, after: afterPaste, pastedText: text)

        if outcome == .inserted {
            // Paste succeeded: restore the user's original clipboard
            usleep(50_000)  // Extra delay to ensure target app has read the clipboard
            savedClipboard.restore(expectedChangeCount: postWriteChangeCount)
        }
        // If .copiedToClipboard: leave recognized text in clipboard as fallback

        return outcome
    }

    private func simulatePaste() {
        let vKeyCode: CGKeyCode = 9 // 'v'

        guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: vKeyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: vKeyCode, keyDown: false)
        else { return }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }

    private func captureFocusedElementSnapshot() -> FocusedElementSnapshot? {
        let frontmostBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier

        guard AXIsProcessTrusted() else {
            return FocusedElementSnapshot(
                bundleIdentifier: frontmostBundleID,
                role: nil,
                value: nil,
                isEditable: false,
                hasFocusedElement: false
            )
        }

        let systemWide = AXUIElementCreateSystemWide()
        var focusedValue: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        )
        guard status == .success, let focusedValue else {
            return FocusedElementSnapshot(
                bundleIdentifier: frontmostBundleID,
                role: nil,
                value: nil,
                isEditable: false,
                hasFocusedElement: false
            )
        }

        let element = unsafeDowncast(focusedValue, to: AXUIElement.self)
        let role = copyStringAttribute(kAXRoleAttribute as CFString, from: element)
        let value = copyStringAttribute(kAXValueAttribute as CFString, from: element)
        let isEditable =
            isAttributeSettable(kAXSelectedTextRangeAttribute as CFString, on: element)
            || isAttributeSettable(kAXValueAttribute as CFString, on: element)
            || [
            kAXTextFieldRole as String,
            kAXTextAreaRole as String,
            kAXComboBoxRole as String,
            "AXSearchField",
        ].contains(role)

        return FocusedElementSnapshot(
            bundleIdentifier: frontmostBundleID,
            role: role,
            value: value,
            isEditable: isEditable,
            hasFocusedElement: true
        )
    }

    private func isAttributeSettable(_ attribute: CFString, on element: AXUIElement) -> Bool {
        var settable = DarwinBoolean(false)
        let status = AXUIElementIsAttributeSettable(element, attribute, &settable)
        return status == .success && settable.boolValue
    }

    private func copyStringAttribute(_ attribute: CFString, from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private func inferInjectionOutcome(
        before: FocusedElementSnapshot?,
        after: FocusedElementSnapshot?,
        pastedText: String
    ) -> InjectionOutcome {
        guard let before, let after else {
            return .inserted
        }

        // No frontmost app → nothing to paste into
        if before.bundleIdentifier == nil && after.bundleIdentifier == nil {
            return .copiedToClipboard
        }

        // No focused UI element found (desktop, no focused window, etc.)
        // Distinct from Electron where an element IS found but has nil role.
        if !before.hasFocusedElement && !after.hasFocusedElement {
            return .copiedToClipboard
        }

        // Value changed → paste definitely worked (strongest signal)
        if let beforeValue = before.value, let afterValue = after.value, beforeValue != afterValue {
            return .inserted
        }

        // Either snapshot says editable → trust it
        if before.isEditable || after.isEditable {
            return .inserted
        }

        // Known non-editable roles with no value change → paste failed
        let nonEditableRoles: Set<String> = [
            kAXStaticTextRole as String,
            kAXImageRole as String,
            kAXGroupRole as String,
            kAXWindowRole as String,
            kAXButtonRole as String,
            kAXCheckBoxRole as String,
            kAXToolbarRole as String,
            kAXMenuBarRole as String,
            kAXMenuItemRole as String,
            kAXScrollBarRole as String,
            kAXSliderRole as String,
            kAXProgressIndicatorRole as String,
            kAXIncrementorRole as String,
            kAXBusyIndicatorRole as String,
            kAXRadioButtonRole as String,
            kAXPopUpButtonRole as String,
            kAXColorWellRole as String,
            kAXRelevanceIndicatorRole as String,
            kAXLevelIndicatorRole as String,
            kAXCellRole as String,
            kAXLayoutAreaRole as String,
            kAXRowRole as String,
            kAXColumnRole as String,
            kAXOutlineRole as String,
            kAXTableRole as String,
            kAXBrowserRole as String,
            kAXSplitGroupRole as String,
        ]
        if let role = after.role, nonEditableRoles.contains(role),
           before.value == after.value {
            return .copiedToClipboard
        }

        // Default: assume success (covers Electron/Gecko/CEF with nil/unknown roles)
        return .inserted
    }


}
