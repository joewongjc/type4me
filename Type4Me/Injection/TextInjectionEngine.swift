import AppKit
import ApplicationServices
import Carbon.HIToolbox

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
        /// Only safe, non-blocking text types are captured.
        /// Binary types (images, RTF, file promises) are skipped because
        /// reading them can trigger lazy data providers in other apps,
        /// blocking the calling thread indefinitely.
        private static let safeTypes: [NSPasteboard.PasteboardType] = [
            .string,
            .URL,
            .html,
            NSPasteboard.PasteboardType("public.utf8-plain-text"),
            NSPasteboard.PasteboardType("public.utf16-plain-text"),
            NSPasteboard.PasteboardType("public.url"),
        ]

        struct Item {
            let types: [NSPasteboard.PasteboardType]
            let data: [NSPasteboard.PasteboardType: Data]
        }
        let items: [Item]
        let changeCount: Int

        static func capture() -> ClipboardSnapshot {
            let pb = NSPasteboard.general
            let changeCount = pb.changeCount
            let safeSet = Set(safeTypes.map(\.rawValue))
            var items: [Item] = []
            for pbItem in pb.pasteboardItems ?? [] {
                let textTypes = pbItem.types.filter { safeSet.contains($0.rawValue) }
                guard !textTypes.isEmpty else { continue }
                var dataMap: [NSPasteboard.PasteboardType: Data] = [:]
                for type in textTypes {
                    if let data = pbItem.data(forType: type) {
                        dataMap[type] = data
                    }
                }
                items.append(Item(types: textTypes, data: dataMap))
            }
            return ClipboardSnapshot(items: items, changeCount: changeCount)
        }

        func restore(expectedChangeCount: Int) {
            let pb = NSPasteboard.general
            guard !items.isEmpty else { return }
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

    /// When true, saves and restores the clipboard around injection.
    /// Has a small race-condition risk: if the target app hasn't finished
    /// reading the clipboard before restore, the paste may contain stale data.
    var preserveClipboard = true

    /// Inject text into the currently focused input field.
    /// Returns the outcome as soon as the paste is dispatched.
    /// Call ``finishClipboardRestore()`` afterward to restore the original clipboard.
    func inject(_ text: String) -> InjectionOutcome {
        guard !text.isEmpty else { return .inserted }
        return injectViaClipboard(text)
    }

    /// Restore the clipboard that was saved before injection.
    /// Safe to call even if there's nothing to restore.
    func finishClipboardRestore() {
        guard let pending = pendingClipboardRestore else { return }
        pendingClipboardRestore = nil
        usleep(50_000)
        pending.snapshot.restore(expectedChangeCount: pending.changeCount)
    }

    /// Copy text to the system clipboard (used at session end).
    func copyToClipboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    // MARK: - Clipboard injection

    private struct PendingClipboardRestore {
        let snapshot: ClipboardSnapshot
        let changeCount: Int
    }

    private var pendingClipboardRestore: PendingClipboardRestore?

    private func injectViaClipboard(_ text: String) -> InjectionOutcome {
        let savedClipboard = preserveClipboard ? ClipboardSnapshot.capture() : nil

        // Snapshot focused element BEFORE paste for outcome detection
        let before = captureFocusedElementSnapshot()

        copyToClipboard(text)
        let postWriteChangeCount = NSPasteboard.general.changeCount
        usleep(50_000)
        simulatePaste()
        usleep(100_000)

        // Snapshot AFTER paste and compare to detect if text landed
        let after = captureFocusedElementSnapshot()
        let outcome = inferInjectionOutcome(before: before, after: after, pastedText: text)

        // Defer clipboard restore so .finalized can be emitted sooner
        if outcome == .inserted, let savedClipboard {
            pendingClipboardRestore = PendingClipboardRestore(
                snapshot: savedClipboard, changeCount: postWriteChangeCount
            )
        } else {
            pendingClipboardRestore = nil
        }

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

    /// Set kAXEnhancedUserInterface on the frontmost app's focused window.
    /// This makes Electron/Chromium apps expose their full AX tree.
    private func enableEnhancedAX(for app: NSRunningApplication) {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 0.3)
        var windowValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedWindowAttribute as CFString,
            &windowValue
        ) == .success, let windowValue else { return }
        let window = unsafeDowncast(windowValue, to: AXUIElement.self)
        AXUIElementSetAttributeValue(
            window,
            "AXEnhancedUserInterface" as CFString,
            true as CFTypeRef
        )
    }

    private func captureFocusedElementSnapshot() -> FocusedElementSnapshot? {
        let frontmostApp = NSWorkspace.shared.frontmostApplication
        let frontmostBundleID = frontmostApp?.bundleIdentifier

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
        AXUIElementSetMessagingTimeout(systemWide, 0.5)
        var focusedValue: CFTypeRef?
        var status = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        )

        // AX blind (common with Electron apps). Enable enhanced AX and retry.
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
                return snapshotFromElement(found, bundleIdentifier: frontmostBundleID)
            }
            return FocusedElementSnapshot(
                bundleIdentifier: frontmostBundleID,
                role: nil,
                value: nil,
                isEditable: false,
                hasFocusedElement: false
            )
        }

        let element = unsafeDowncast(focusedValue!, to: AXUIElement.self)
        return snapshotFromElement(element, bundleIdentifier: frontmostBundleID)
    }

    private func snapshotFromElement(_ element: AXUIElement, bundleIdentifier: String?) -> FocusedElementSnapshot {
        AXUIElementSetMessagingTimeout(element, 0.5)
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
            bundleIdentifier: bundleIdentifier,
            role: role,
            value: value,
            isEditable: isEditable,
            hasFocusedElement: true
        )
    }

    /// Traverse the app's focused window tree to find the first editable element.
    /// Used as fallback when system-wide kAXFocusedUIElementAttribute fails.
    private func findEditableElementInApp(_ app: NSRunningApplication) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 0.5)

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

    private func inferInjectionOutcome(
        before: FocusedElementSnapshot?,
        after: FocusedElementSnapshot?,
        pastedText: String
    ) -> InjectionOutcome {
        DebugFileLogger.log("injection detect: before=\(before.map { "bundle=\($0.bundleIdentifier ?? "nil") role=\($0.role ?? "nil") editable=\($0.isEditable) hasFocus=\($0.hasFocusedElement) value=\($0.value.map { String($0.prefix(30)) } ?? "nil")" } ?? "nil")")
        DebugFileLogger.log("injection detect: after=\(after.map { "bundle=\($0.bundleIdentifier ?? "nil") role=\($0.role ?? "nil") editable=\($0.isEditable) hasFocus=\($0.hasFocusedElement) value=\($0.value.map { String($0.prefix(30)) } ?? "nil")" } ?? "nil")")

        guard let before, let after else {
            return .inserted
        }

        // No frontmost app → nothing to paste into (e.g. desktop)
        if before.bundleIdentifier == nil && after.bundleIdentifier == nil {
            return .copiedToClipboard
        }

        // AX completely blind (common with WeChat, Feishu/Lark and other
        // Electron apps). Cmd+V still works in these apps, so assume success.
        if !before.hasFocusedElement || !after.hasFocusedElement {
            return .inserted
        }

        // Value changed → paste definitely worked (strongest signal)
        if let beforeValue = before.value, let afterValue = after.value, beforeValue != afterValue {
            return .inserted
        }

        // Either snapshot says editable → trust it
        if before.isEditable || after.isEditable {
            return .inserted
        }

        // Not editable and value didn't change → paste had nowhere to go
        return .copiedToClipboard
    }


}
