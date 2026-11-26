import AppKit
import ApplicationServices

enum LastResultPasteOutcome {
    case inserted, noResult, unavailable, unconfirmed
}

/// The shortcut writes only to the external field focused when it was pressed.
struct LastResultPasteTarget: @unchecked Sendable {
    private let pid: pid_t
    private let field: AXUIElement

    @MainActor
    static func capture() -> Self? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              pid != ProcessInfo.processInfo.processIdentifier,
              let field = focusedField(in: pid)
        else { return nil }
        return Self(pid: pid, field: field)
    }

    func insert(_ text: String) -> LastResultPasteOutcome {
        let client = SystemReviseAccessibilityClient.shared
        guard Self.matchesFocusedField(field, in: pid),
              client.isAttributeSettable(kAXSelectedTextAttribute as CFString, on: field)
        else { return .unavailable }

        var subrole: CFTypeRef?
        let subroleStatus = AXUIElementCopyAttributeValue(field, kAXSubroleAttribute as CFString, &subrole)
        guard [.success, .attributeUnsupported, .noValue].contains(subroleStatus),
              subrole as? String != kAXSecureTextFieldSubrole
        else { return .unavailable }

        guard let value = try? client.value(of: field),
              let range = try? client.selectedRange(of: field)
        else { return .unavailable }
        let original = value as NSString
        guard range.location <= original.length, range.length <= original.length - range.location,
              Self.matchesFocusedField(field, in: pid)
        else { return .unavailable }

        let expected = original.replacingCharacters(in: range, with: text)
        do {
            try client.setSelectedText(text, on: field)
        } catch {
            return .unconfirmed
        }
        guard (try? client.value(of: field)) == expected else { return .unconfirmed }
        if value == expected {
            let caret = NSRange(location: range.location + (text as NSString).length, length: 0)
            guard (try? client.selectedRange(of: field)) == caret else { return .unconfirmed }
        }
        return .inserted
    }

    private static func matchesFocusedField(_ field: AXUIElement, in pid: pid_t) -> Bool {
        guard let current = focusedField(in: pid) else { return false }
        return CFEqual(current, field) && NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
    }

    private static func focusedField(in pid: pid_t) -> AXUIElement? {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.05)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        let field = unsafeDowncast(value, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(field, 0.05)
        return field
    }
}
