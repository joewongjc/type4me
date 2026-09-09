import Cocoa
import Foundation

final class TextInjectionEngine: @unchecked Sendable {

    /// Per-process randomized marker tagged onto synthetic events (e.g. Cmd+V)
    /// so HotkeyManager recognizes them as internal and avoids re-triggering hotkeys.
    private static let syntheticInputEventMarker = Int64.random(in: 1...Int64.max)

    static func markAsSyntheticInput(_ event: CGEvent) {
        event.setIntegerValueField(
            .eventSourceUserData,
            value: syntheticInputEventMarker
        )
    }

    static func isSyntheticInput(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.eventSourceUserData) == syntheticInputEventMarker
    }

    enum ClipboardRetention: Sendable, Equatable {
        /// Keep the dictated result in the system clipboard after the paste attempt.
        case retainResult
        /// Restore the clipboard captured before the paste attempt, including
        /// when injection falls safe to a plain copy.
        case restoreOriginal
    }
    typealias ClipboardSnapshot = Type4Me.ClipboardSnapshot

    enum DeliveryTarget: Equatable {
        case app(NSRunningApplication)
        case fallbackToClipboard
    }

    static func resolveDeliveryTarget(
        frontmost: NSRunningApplication?,
        selfBundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) -> DeliveryTarget {
        guard let frontmost,
              frontmost.bundleIdentifier != selfBundleIdentifier,
              !frontmost.isTerminated
        else {
            return .fallbackToClipboard
        }
        return .app(frontmost)
    }


    struct FocusedElementSnapshot {
        var element: AXUIElement? = nil
        var processIdentifier: pid_t? = nil
        var bundleIdentifier: String? = nil
        var role: String? = nil
        var subrole: String? = nil
        var value: String? = nil
        var placeholder: String? = nil
        var accessibilityDescription: String? = nil
        var selectedRange: NSRange? = nil
        var isEditable: Bool = false
        var hasFocusedElement: Bool = false
    }

    private struct PendingClipboardRestore {
        let snapshot: ClipboardSnapshot
        let changeCount: Int
    }

    /// Whether this engine should retain the dictated result or restore the
    /// clipboard that existed before injection.
    var clipboardRetention: ClipboardRetention = .restoreOriginal
    private var pendingClipboardRestore: PendingClipboardRestore?

    /// Inject text into the currently focused input field.
    /// Returns the outcome as soon as the paste is dispatched.
    /// Call ``finishClipboardRestore()`` afterward to restore the original clipboard.
    func inject(_ text: String) -> InjectionOutcome {
        guard !text.isEmpty else { return .inserted }
        return injectViaClipboard(text, trackingMetadata: nil).outcome
    }

    /// Inject text while capturing enough Accessibility context to observe a
    /// later correction in the exact field Type4Me wrote into.
    func injectTracked(
        _ text: String,
        sourceText: String,
        sourceRecordID: String,
        modeID: UUID
    ) -> TrackedInjectionResult {
        guard !text.isEmpty else {
            return TrackedInjectionResult(outcome: .inserted, observationContext: nil)
        }
        return injectViaClipboard(
            text,
            trackingMetadata: (
                sourceText: sourceText,
                sourceRecordID: sourceRecordID,
                modeID: modeID
            )
        )
    }

    /// Restore the clipboard that was saved before injection.
    /// Safe to call even if there's nothing to restore.
    func finishClipboardRestore() {
        guard let pending = pendingClipboardRestore else { return }
        pendingClipboardRestore = nil
        // Electron apps (VS Code, Slack, Notion, Feishu) may need 200-500ms
        // to read the clipboard after Cmd+V.
        usleep(300_000)
        pending.snapshot.restore(expectedChangeCount: pending.changeCount)
    }

    /// Copy text to the system clipboard (used at session end).
    func copyToClipboard(_ text: String, transient: Bool = false) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        if transient {
            pb.setData(Data(), forType: PasteboardHistoryPolicy.transientType)
        }
    }

    private func injectViaClipboard(
        _ text: String,
        trackingMetadata: (sourceText: String, sourceRecordID: String, modeID: UUID)?
    ) -> TrackedInjectionResult {
        let shouldRestoreClipboard = Self.shouldRestoreClipboard(retention: clipboardRetention)
        let savedClipboard = shouldRestoreClipboard ? ClipboardSnapshot.capture() : nil

        let deliveryTarget = Self.resolveDeliveryTarget(
            frontmost: NSWorkspace.shared.frontmostApplication
        )
        guard case .app = deliveryTarget else {
            // Delivery fallback: no valid external target application. Always preserve the
            // dictated text in the system clipboard so the user's speech is never lost.
            copyToClipboard(text, transient: false)
            pendingClipboardRestore = nil
            DebugFileLogger.log("injection fallback: no valid external target app; copied to clipboard")
            return TrackedInjectionResult(outcome: .copiedToClipboard, observationContext: nil)
        }

        let before = trackingMetadata != nil ? captureFocusedElementSnapshot(isPrePaste: true) : nil


        copyToClipboard(text, transient: shouldRestoreClipboard)
        let postWriteChangeCount = NSPasteboard.general.changeCount
        usleep(50_000)

        guard simulatePaste() else {
            // Delivery fallback: paste event creation failed. Always preserve text in the clipboard.
            copyToClipboard(text, transient: false)
            pendingClipboardRestore = nil
            DebugFileLogger.log("injection fallback: paste event creation failed; copied to clipboard")
            return TrackedInjectionResult(outcome: .copiedToClipboard, observationContext: nil)
        }
        usleep(100_000)

        let after = trackingMetadata != nil ? captureFocusedElementSnapshot(isPrePaste: false) : nil
        let outcome: InjectionOutcome = .inserted

        if let savedClipboard {
            pendingClipboardRestore = PendingClipboardRestore(
                snapshot: savedClipboard, changeCount: postWriteChangeCount
            )
        } else {
            pendingClipboardRestore = nil
        }

        let context = trackingMetadata.flatMap { metadata in
            makeObservationContext(
                before: before,
                after: after,
                pastedText: text,
                sourceText: metadata.sourceText,
                sourceRecordID: metadata.sourceRecordID,
                modeID: metadata.modeID,
                outcome: outcome
            )
        }
        return TrackedInjectionResult(outcome: outcome, observationContext: context)
    }

    static func shouldRestoreClipboard(retention: ClipboardRetention) -> Bool {
        retention == .restoreOriginal
    }


    private func simulatePaste() -> Bool {
        let vKeyCode: CGKeyCode = 9 // 'v'

        guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: vKeyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: vKeyCode, keyDown: false)
        else { return false }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        Self.markAsSyntheticInput(keyDown)
        Self.markAsSyntheticInput(keyUp)

        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }

    private func enableEnhancedAX(for app: NSRunningApplication) {
        guard AXIsProcessTrusted(), !app.isTerminated else { return }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 0.05)
        _ = AXUIElementSetAttributeValue(
            appElement,
            "AXEnhancedUserInterface" as CFString,
            true as CFTypeRef
        )
    }

    private func captureFocusedElementSnapshot(isPrePaste: Bool = false) -> FocusedElementSnapshot? {
        let frontmostApp = NSWorkspace.shared.frontmostApplication
        let frontmostBundleID = frontmostApp?.bundleIdentifier

        guard AXIsProcessTrusted() else {
            return FocusedElementSnapshot(
                element: nil,
                processIdentifier: frontmostApp?.processIdentifier,
                bundleIdentifier: frontmostBundleID,
                role: nil,
                subrole: nil,
                value: nil,
                placeholder: nil,
                accessibilityDescription: nil,
                selectedRange: nil,
                isEditable: false,
                hasFocusedElement: false
            )
        }

        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, isPrePaste ? 0.05 : 0.25)
        var focusedValue: CFTypeRef?
        var status = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        )

        // Pre-paste snapshot is on the critical path: keep it strictly bounded and fast.
        // If system-wide query fails initially, allow a fast enhanced-AX retry without sleeping,
        // but never perform 30ms sleep or window tree traversal before Cmd+V is dispatched.
        if isPrePaste {
            if status == .success, let focusedValue {
                let element = unsafeDowncast(focusedValue, to: AXUIElement.self)
                return snapshotFromElement(element, bundleIdentifier: frontmostBundleID, timeout: 0.05)
            }
            if let frontmostApp {
                enableEnhancedAX(for: frontmostApp)
                status = AXUIElementCopyAttributeValue(
                    systemWide,
                    kAXFocusedUIElementAttribute as CFString,
                    &focusedValue
                )
                if status == .success, let focusedValue {
                    let element = unsafeDowncast(focusedValue, to: AXUIElement.self)
                    return snapshotFromElement(element, bundleIdentifier: frontmostBundleID, timeout: 0.05)
                }
            }
            return nil
        }

        // Post-paste snapshot is off the critical path: allow enhanced AX retry and tree traversal.
        if status != .success || focusedValue == nil, let frontmostApp {
            enableEnhancedAX(for: frontmostApp)
            usleep(30_000) // 30ms for Chromium to build AX tree
            status = AXUIElementCopyAttributeValue(
                systemWide,
                kAXFocusedUIElementAttribute as CFString,
                &focusedValue
            )
        }

        // System-wide query still failed — try traversing the app's window tree
        // to find an editable element. Common for WeChat, Feishu, etc.
        if status != .success || focusedValue == nil, let frontmostApp {
            if let found = findEditableElementInApp(frontmostApp) {
                return snapshotFromElement(found, bundleIdentifier: frontmostBundleID, timeout: 0.25)
            }
            return FocusedElementSnapshot(
                element: nil,
                processIdentifier: frontmostApp.processIdentifier,
                bundleIdentifier: frontmostBundleID,
                role: nil,
                subrole: nil,
                value: nil,
                placeholder: nil,
                accessibilityDescription: nil,
                selectedRange: nil,
                isEditable: false,
                hasFocusedElement: false
            )
        }

        let element = unsafeDowncast(focusedValue!, to: AXUIElement.self)
        return snapshotFromElement(element, bundleIdentifier: frontmostBundleID, timeout: 0.25)
    }

    private func snapshotFromElement(
        _ element: AXUIElement,
        bundleIdentifier: String?,
        timeout: Float = 0.05
    ) -> FocusedElementSnapshot {
        AXUIElementSetMessagingTimeout(element, timeout)
        let role = copyStringAttribute(kAXRoleAttribute as CFString, from: element)
        let subrole = copyStringAttribute(kAXSubroleAttribute as CFString, from: element)
        let value = copyStringAttribute(kAXValueAttribute as CFString, from: element)
        let placeholder = copyStringAttribute(kAXPlaceholderValueAttribute as CFString, from: element)
        let accessibilityDescription = copyStringAttribute(kAXDescriptionAttribute as CFString, from: element)
        let selectedRange = copyRangeAttribute(kAXSelectedTextRangeAttribute as CFString, from: element)
        var processIdentifier: pid_t = 0
        let pidStatus = AXUIElementGetPid(element, &processIdentifier)
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
            element: element,
            processIdentifier: pidStatus == .success ? processIdentifier : nil,
            bundleIdentifier: bundleIdentifier,
            role: role,
            subrole: subrole,
            value: value,
            placeholder: placeholder,
            accessibilityDescription: accessibilityDescription,
            selectedRange: selectedRange,
            isEditable: isEditable,
            hasFocusedElement: true
        )
    }

    /// Traverse the app's focused window tree to find the first editable element.
    /// Used as fallback when system-wide kAXFocusedUIElementAttribute fails.
    private func findEditableElementInApp(_ app: NSRunningApplication) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 0.05)

        var windowValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedWindowAttribute as CFString,
            &windowValue
        ) == .success, let windowValue else { return nil }

        let window = unsafeDowncast(windowValue, to: AXUIElement.self)
        return findEditableChild(in: window, maxDepth: 8)
    }

    private func findEditableChild(in element: AXUIElement, depth: Int = 0, maxDepth: Int) -> AXUIElement? {
        if depth > maxDepth { return nil }

        let role = copyStringAttribute(kAXRoleAttribute as CFString, from: element)
        let editableRoles: Set<String> = [
            kAXTextFieldRole as String,
            kAXTextAreaRole as String,
            kAXComboBoxRole as String,
            "AXSearchField",
        ]
        if editableRoles.contains(role ?? "") {
            return element
        }
        if isAttributeSettable(kAXSelectedTextRangeAttribute as CFString, on: element)
            || isAttributeSettable(kAXValueAttribute as CFString, on: element) {
            return element
        }

        var childrenValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXChildrenAttribute as CFString, &childrenValue
        ) == .success, let children = childrenValue as? [AXUIElement] else {
            return nil
        }
        for child in children {
            if let found = findEditableChild(in: child, depth: depth + 1, maxDepth: maxDepth) {
                return found
            }
        }
        return nil
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

    private func copyRangeAttribute(_ attribute: CFString, from element: AXUIElement) -> NSRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        let axValue = unsafeDowncast(value, to: AXValue.self)
        guard AXValueGetType(axValue) == .cfRange else { return nil }
        var range = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &range), range.location >= 0, range.length >= 0 else {
            return nil
        }
        return NSRange(location: range.location, length: range.length)
    }

    private func makeObservationContext(
        before: FocusedElementSnapshot?,
        after: FocusedElementSnapshot?,
        pastedText: String,
        sourceText: String,
        sourceRecordID: String,
        modeID: UUID,
        outcome: InjectionOutcome
    ) -> CorrectionObservationContext? {
        guard outcome == .inserted,
              let before,
              let after,
              before.hasFocusedElement,
              after.hasFocusedElement,
              before.isEditable,
              after.isEditable,
              let beforeElement = before.element,
              let afterElement = after.element,
              CFEqual(beforeElement, afterElement),
              let processIdentifier = after.processIdentifier,
              let bundleIdentifier = after.bundleIdentifier,
              let beforeValue = before.value,
              let afterValue = after.value,
              !isSecureTextRole(role: after.role, subrole: after.subrole),
              let insertedRange = inferInsertedRange(
                  beforeValue: beforeValue,
                  afterValue: afterValue,
                  selectedRange: before.selectedRange,
                  pastedText: pastedText
              )
        else { return nil }

        return CorrectionObservationContext(
            element: afterElement,
            processIdentifier: processIdentifier,
            bundleIdentifier: bundleIdentifier,
            baselineValue: afterValue,
            injectedRange: insertedRange,
            beforeSelectedRange: before.selectedRange,
            afterSelectedRange: after.selectedRange,
            placeholderCandidates: [
                before.placeholder,
                after.placeholder,
                before.accessibilityDescription,
                after.accessibilityDescription,
            ].compactMap { $0 },
            sourceText: sourceText,
            injectedText: pastedText,
            sourceRecordID: sourceRecordID,
            modeID: modeID
        )
    }

    private func isSecureTextRole(role: String?, subrole: String?) -> Bool {
        [role, subrole]
            .compactMap { $0?.lowercased() }
            .contains { $0.contains("secure") || $0.contains("password") }
    }

    private func inferInsertedRange(
        beforeValue: String,
        afterValue: String,
        selectedRange: NSRange?,
        pastedText: String
    ) -> NSRange? {
        let beforeNSString = beforeValue as NSString
        let afterNSString = afterValue as NSString
        let pastedLength = (pastedText as NSString).length

        if let selectedRange,
           NSMaxRange(selectedRange) <= beforeNSString.length {
            let expected = beforeNSString.replacingCharacters(in: selectedRange, with: pastedText)
            if expected == afterValue {
                return NSRange(location: selectedRange.location, length: pastedLength)
            }
        }

        var prefixLength = 0
        let sharedLength = min(beforeNSString.length, afterNSString.length)
        while prefixLength < sharedLength,
              beforeNSString.character(at: prefixLength) == afterNSString.character(at: prefixLength) {
            prefixLength += 1
        }

        var suffixLength = 0
        while suffixLength < beforeNSString.length - prefixLength,
              suffixLength < afterNSString.length - prefixLength,
              beforeNSString.character(at: beforeNSString.length - suffixLength - 1)
                == afterNSString.character(at: afterNSString.length - suffixLength - 1) {
            suffixLength += 1
        }

        let changedAfterLength = afterNSString.length - prefixLength - suffixLength
        guard changedAfterLength == pastedLength else { return nil }
        let changedAfter = afterNSString.substring(
            with: NSRange(location: prefixLength, length: changedAfterLength)
        )
        guard changedAfter == pastedText else { return nil }
        return NSRange(location: prefixLength, length: pastedLength)
    }
}
