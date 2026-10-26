import AppKit
import ApplicationServices
import Foundation
import os
import Type4MeIntelliSenseCore

struct TargetApplicationContext: Equatable, Sendable {
    let processIdentifier: pid_t?
    let bundleIdentifier: String?
    let displayName: String?
}

extension IntelliSenseContextSnapshot {
    static func appOnly(_ target: TargetApplicationContext) -> Self {
        Self(
            bundleIdentifier: target.bundleIdentifier,
            appName: target.displayName,
            appCategory: AppContextClassifier.classify(
                bundleIdentifier: target.bundleIdentifier,
                appName: target.displayName
            ),
            controlCategory: .unknown,
            contextBeforeCursor: "",
            contextAfterCursor: "",
            availability: target.bundleIdentifier == nil ? .unavailable : .appOnly,
            wasTruncated: false
        )
    }
}

enum IntelliSenseSensitiveTextScanner {
    private static let expressions: [NSRegularExpression] = [
        #"(?i)\b(?:api[_-]?key|secret|access[_-]?token|refresh[_-]?token|client[_-]?secret)\b\s*[:=]"#,
        #"(?i)\bBearer\s+[A-Za-z0-9._~+/-]{12,}={0,2}"#,
        #"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b"#,
        #"-----BEGIN(?: [A-Z0-9]+)? (?:PRIVATE KEY|CERTIFICATE)-----"#,
        #"\b(?:AKIA|ASIA|AIza|ghp_|github_pat_|sk-|xox[baprs]-)[A-Za-z0-9_\-]{12,}\b"#,
        #"\b[a-fA-F0-9]{48,}\b"#,
        #"\b[A-Za-z0-9+/]{64,}={0,2}\b"#,
        #"(?i)\b(?:password|passwd|verification[_ -]?code|验证码)\b\s*[:=：]"#,
    ].compactMap { try? NSRegularExpression(pattern: $0) }

    static func containsSensitiveContent(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return expressions.contains { $0.firstMatch(in: text, range: range) != nil }
    }
}

enum IntelliSenseContextCapturer {
    private static let beforeLimit = 300
    private static let afterLimit = 100
    private static let maximumFallbackValueLength = 100_000

    static func capture(
        target: TargetApplicationContext,
        settings: IntelliSenseSettings,
        timeout: Duration = .milliseconds(300)
    ) async -> IntelliSenseContextSnapshot {
        var base = IntelliSenseContextSnapshot.appOnly(target)
        if settings.isBlacklisted(bundleIdentifier: target.bundleIdentifier) {
            base.availability = .blacklisted
            return base
        }
        guard settings.applicationAwarenessEnabled
                || settings.contextAwarenessEnabled
                || settings.expressionLearningEnabled
                || settings.correctionDetectionEnabled,
              let pid = target.processIdentifier,
              AXIsProcessTrusted()
        else { return base }

        return await withCheckedContinuation { continuation in
            let finished = OSAllocatedUnfairLock(initialState: false)
            Task.detached {
                let result = captureSynchronously(target: target, pid: pid, settings: settings)
                if finished.withLock({ let old = $0; $0 = true; return !old }) {
                    continuation.resume(returning: result)
                }
            }
            Task.detached {
                try? await Task.sleep(for: timeout)
                if finished.withLock({ let old = $0; $0 = true; return !old }) {
                    continuation.resume(returning: base)
                }
            }
        }
    }

    private static func captureSynchronously(
        target: TargetApplicationContext,
        pid: pid_t,
        settings: IntelliSenseSettings
    ) -> IntelliSenseContextSnapshot {
        var snapshot = IntelliSenseContextSnapshot.appOnly(target)
        let application = AXUIElementCreateApplication(pid)
        guard let element = copyElementAttribute(application, kAXFocusedUIElementAttribute) else {
            return snapshot
        }

        let role = copyStringAttribute(element, kAXRoleAttribute) ?? ""
        let subrole = copyStringAttribute(element, kAXSubroleAttribute) ?? ""
        if subrole.localizedCaseInsensitiveContains("secure") {
            snapshot.availability = .sensitive
            return snapshot
        }

        snapshot.controlCategory = classifyControl(
            role: role,
            subrole: subrole,
            title: copyStringAttribute(element, kAXTitleAttribute),
            description: copyStringAttribute(element, kAXDescriptionAttribute),
            identifier: copyStringAttribute(element, kAXIdentifierAttribute),
            placeholder: copyStringAttribute(element, kAXPlaceholderValueAttribute),
            help: copyStringAttribute(element, kAXHelpAttribute),
            appCategory: snapshot.appCategory
        )
        snapshot.availability = .appAndControl

        guard settings.contextAwarenessEnabled,
              snapshot.appCategory != .terminal,
              snapshot.appCategory != .development,
              let selectedRange = copySelectedRange(element)
        else { return snapshot }

        let beforeStart = max(0, selectedRange.location - beforeLimit)
        let beforeRange = CFRange(
            location: beforeStart,
            length: selectedRange.location - beforeStart
        )
        let afterRange = CFRange(
            location: selectedRange.location + selectedRange.length,
            length: afterLimit
        )

        var before = copyStringForRange(element, range: beforeRange)
        var after = copyStringForRange(element, range: afterRange)
        if before == nil && after == nil,
           let value = copyStringAttribute(element, kAXValueAttribute),
           value.utf16.count <= maximumFallbackValueLength {
            let nsValue = value as NSString
            let cursor = min(max(0, selectedRange.location), nsValue.length)
            let start = max(0, cursor - beforeLimit)
            before = nsValue.substring(with: NSRange(location: start, length: cursor - start))
            let afterStart = min(nsValue.length, cursor + selectedRange.length)
            after = nsValue.substring(with: NSRange(
                location: afterStart,
                length: min(afterLimit, nsValue.length - afterStart)
            ))
            snapshot.wasTruncated = nsValue.length > beforeLimit + afterLimit
        }

        let beforeText = sanitize(before ?? "")
        let afterText = sanitize(after ?? "")
        let combined = beforeText + afterText
        guard !IntelliSenseSensitiveTextScanner.containsSensitiveContent(combined) else {
            snapshot.availability = .sensitive
            return snapshot
        }
        snapshot.contextBeforeCursor = beforeText
        snapshot.contextAfterCursor = afterText
        snapshot.availability = combined.isEmpty ? .appAndControl : .full
        return snapshot
    }

    static func classifyControl(
        role: String,
        subrole: String,
        title: String? = nil,
        description: String? = nil,
        identifier: String? = nil,
        placeholder: String? = nil,
        help: String? = nil,
        appCategory: ApplicationCategory
    ) -> InputControlCategory {
        let combined = [role, subrole, title, description, identifier, placeholder, help]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()
        if appCategory == .terminal { return .terminal }
        if appCategory == .development { return .code }
        if combined.contains("search") || combined.contains("搜索") { return .search }
        if combined.contains("title") { return .title }
        if combined.contains("textarea") || combined.contains("text area") { return .multiLine }
        if combined.contains("textfield") || combined.contains("text field") { return .singleLine }
        return .unknown
    }

    private static func copyElementAttribute(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private static func copyStringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private static func copySelectedRange(_ element: AXUIElement) -> CFRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &value
        ) == .success,
        let value,
        CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        let axValue = unsafeBitCast(value, to: AXValue.self)
        guard
        AXValueGetType(axValue) == .cfRange
        else { return nil }
        var range = CFRange()
        return AXValueGetValue(axValue, .cfRange, &range) ? range : nil
    }

    private static func copyStringForRange(_ element: AXUIElement, range: CFRange) -> String? {
        guard range.location >= 0, range.length > 0 else { return nil }
        var mutableRange = range
        guard let parameter = AXValueCreate(.cfRange, &mutableRange) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXStringForRangeParameterizedAttribute as CFString,
            parameter,
            &value
        ) == .success else { return nil }
        return value as? String
    }

    private static func sanitize(_ text: String) -> String {
        String(text.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) || $0 == "\n" || $0 == "\t"
        })
    }
}
