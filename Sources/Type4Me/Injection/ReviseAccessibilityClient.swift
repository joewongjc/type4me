import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation

struct ReviseFocusedControlSnapshot: @unchecked Sendable {
    let element: AXUIElement?
    let processIdentifier: pid_t?
    let bundleIdentifier: String?
    let role: String?
    let subrole: String?
    let value: String?
    let placeholder: String?
    let selectedRange: NSRange?
    let placeholderCandidates: [String]
    let isEditable: Bool
    let isSecure: Bool
    let supportsSingleLineOnly: Bool
}

enum ReviseAccessibilityError: String, Error, Sendable {
    case notTrusted
    case noFocusedElement
    case attributeFailed
    case actionFailed
    case invalidRange
}

protocol ReviseAccessibilityClient: Sendable {
    func focusedControl() throws -> ReviseFocusedControlSnapshot
    func value(of element: AXUIElement) throws -> String
    func selectedRange(of element: AXUIElement) throws -> NSRange?
    func isAttributeSettable(_ attribute: CFString, on element: AXUIElement) -> Bool
    func setSelectedRange(_ range: NSRange, on element: AXUIElement) throws
    func setSelectedText(_ text: String, on element: AXUIElement) throws
    func pressDelete() throws
    func paste() throws
}

final class SystemReviseAccessibilityClient: ReviseAccessibilityClient, @unchecked Sendable {
    static let shared = SystemReviseAccessibilityClient()

    func focusedControl() throws -> ReviseFocusedControlSnapshot {
        let frontmostApp = NSWorkspace.shared.frontmostApplication
        let frontmostBundleID = frontmostApp?.bundleIdentifier
        let frontmostPID = frontmostApp?.processIdentifier

        guard AXIsProcessTrusted() else {
            return ReviseFocusedControlSnapshot(
                element: nil,
                processIdentifier: frontmostPID,
                bundleIdentifier: frontmostBundleID,
                role: nil,
                subrole: nil,
                value: nil,
                placeholder: nil,
                selectedRange: nil,
                placeholderCandidates: [],
                isEditable: false,
                isSecure: false,
                supportsSingleLineOnly: false
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

        if status != .success || focusedValue == nil, let frontmostApp {
            enableEnhancedAX(for: frontmostApp)
            usleep(30_000)
            status = AXUIElementCopyAttributeValue(
                systemWide,
                kAXFocusedUIElementAttribute as CFString,
                &focusedValue
            )
        }

        guard status == .success, let focusedValue else {
            return ReviseFocusedControlSnapshot(
                element: nil,
                processIdentifier: frontmostPID,
                bundleIdentifier: frontmostBundleID,
                role: nil,
                subrole: nil,
                value: nil,
                placeholder: nil,
                selectedRange: nil,
                placeholderCandidates: [],
                isEditable: false,
                isSecure: false,
                supportsSingleLineOnly: false
            )
        }

        let element = unsafeDowncast(focusedValue, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(element, 0.5)

        let role = copyStringAttribute(kAXRoleAttribute as CFString, from: element)
        let subrole = copyStringAttribute(kAXSubroleAttribute as CFString, from: element)
        let value = copyStringAttribute(kAXValueAttribute as CFString, from: element)
        let placeholder = copyStringAttribute(kAXPlaceholderValueAttribute as CFString, from: element)
        let desc = copyStringAttribute(kAXDescriptionAttribute as CFString, from: element)
        let selectedRange = copyRangeAttribute(kAXSelectedTextRangeAttribute as CFString, from: element)

        var processIdentifier: pid_t = 0
        let pidStatus = AXUIElementGetPid(element, &processIdentifier)

        let isSecure = [role, subrole].compactMap { $0?.lowercased() }
            .contains { $0.contains("secure") || $0.contains("password") }

        let isEditable = !isSecure && (
            isAttributeSettable(kAXSelectedTextRangeAttribute as CFString, on: element)
            || isAttributeSettable(kAXValueAttribute as CFString, on: element)
            || [
                kAXTextFieldRole as String,
                kAXTextAreaRole as String,
                kAXComboBoxRole as String,
                "AXSearchField",
            ].contains(role)
        )

        let supportsSingleLineOnly = (role == (kAXTextFieldRole as String) || role == "AXSearchField")
            && role != (kAXTextAreaRole as String)

        return ReviseFocusedControlSnapshot(
            element: element,
            processIdentifier: pidStatus == .success ? processIdentifier : frontmostPID,
            bundleIdentifier: frontmostBundleID,
            role: role,
            subrole: subrole,
            value: value,
            placeholder: placeholder,
            selectedRange: selectedRange,
            placeholderCandidates: [placeholder, desc].compactMap { $0 },
            isEditable: isEditable,
            isSecure: isSecure,
            supportsSingleLineOnly: supportsSingleLineOnly
        )
    }

    func value(of element: AXUIElement) throws -> String {
        guard let val = copyStringAttribute(kAXValueAttribute as CFString, from: element) else {
            throw ReviseAccessibilityError.attributeFailed
        }
        return val
    }

    func selectedRange(of element: AXUIElement) throws -> NSRange? {
        copyRangeAttribute(kAXSelectedTextRangeAttribute as CFString, from: element)
    }

    func isAttributeSettable(_ attribute: CFString, on element: AXUIElement) -> Bool {
        var settable = DarwinBoolean(false)
        let status = AXUIElementIsAttributeSettable(element, attribute, &settable)
        return status == .success && settable.boolValue
    }

    func setSelectedRange(_ range: NSRange, on element: AXUIElement) throws {
        var cfRange = CFRange(location: range.location, length: range.length)
        guard let axValue = AXValueCreate(.cfRange, &cfRange) else {
            throw ReviseAccessibilityError.invalidRange
        }
        let status = AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            axValue
        )
        guard status == .success else {
            throw ReviseAccessibilityError.attributeFailed
        }
    }

    func setSelectedText(_ text: String, on element: AXUIElement) throws {
        let status = AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            text as CFTypeRef
        )
        guard status == .success else {
            throw ReviseAccessibilityError.attributeFailed
        }
    }

    func pressDelete() throws {
        let deleteKeyCode: CGKeyCode = 51 // Delete
        guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: deleteKeyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: deleteKeyCode, keyDown: false)
        else {
            throw ReviseAccessibilityError.actionFailed
        }
        TextInjectionEngine.markAsSyntheticInput(keyDown)
        TextInjectionEngine.markAsSyntheticInput(keyUp)
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }

    func paste() throws {
        let vKeyCode: CGKeyCode = 9 // 'v'
        guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: vKeyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: vKeyCode, keyDown: false)
        else {
            throw ReviseAccessibilityError.actionFailed
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        TextInjectionEngine.markAsSyntheticInput(keyDown)
        TextInjectionEngine.markAsSyntheticInput(keyUp)
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }

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
}
