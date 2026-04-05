import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Monitors DoubaoIme (豆包输入法) ASR sessions by watching for its
/// status indicator window (layer 3, ~186x32) appearing/disappearing.
/// On ASR start: snapshots cursor position in the focused text field.
/// On ASR end: calculates the inserted text range and notifies delegate.
@MainActor
final class DoubaoASRObserver {

    // MARK: - Delegate

    protocol Delegate: AnyObject, Sendable {
        func doubaoASRDidStart(element: AXUIElement, cursorPosition: Int)
        func doubaoASRDidEnd(
            element: AXUIElement,
            startCursorPosition: Int,
            endCursorPosition: Int,
            asrText: String
        )
    }

    weak var delegate: (any Delegate)?

    // MARK: - State

    private var pollTimer: Timer?
    private var isObserving = false

    /// Tracks the on-screen ASR indicator window ID.
    private var activeASRWindowID: Int?
    private var pollCount = 0

    /// Snapshot captured when ASR starts.
    private var asrStartCursorPos: Int?
    private var asrTargetElement: AXUIElement?

    // MARK: - Constants

    /// DoubaoIme ASR indicator window characteristics (verified empirically):
    /// - Owner name: "豆包输入法"
    /// - Layer: 3 (candidate windows use layer 2147483628)
    /// - Size: ~186x32 initially, shrinks to ~124x32 during finalization
    private static let ownerName = "豆包输入法"
    private static let asrLayer = 3
    private static let maxASRWindowHeight = 50  // ASR indicator is ~32px tall
    /// Delay after panel disappears before reading final cursor position,
    /// to ensure the last insertText has been committed.
    private static let postASRDelay: UInt32 = 200_000  // 200ms in microseconds

    // MARK: - Lifecycle

    func startObserving() {
        guard !isObserving else { return }
        isObserving = true
        DebugFileLogger.log("[DoubaoASR] Observer started, polling every 100ms")
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    func stopObserving() {
        pollTimer?.invalidate()
        pollTimer = nil
        isObserving = false
        activeASRWindowID = nil
        asrStartCursorPos = nil
        asrTargetElement = nil
        NSLog("[DoubaoASR] Observer stopped")
    }

    // MARK: - Polling

    private func poll() {
        pollCount += 1
        let asrWindows = findDoubaoASRWindows()
        let onScreenIDs = Set(asrWindows.filter(\.isOnScreen).map(\.id))

        // Log every 10s to confirm polling is alive
        if pollCount % 100 == 0 {
            DebugFileLogger.log("[DoubaoASR] poll #\(pollCount), asrWindows=\(asrWindows.count), onScreen=\(onScreenIDs)")
        }

        if activeASRWindowID == nil {
            // No active ASR session — check if one started
            if let newID = onScreenIDs.first {
                activeASRWindowID = newID
                onASRStart()
            }
        } else {
            // Active ASR session — check if it ended
            if onScreenIDs.isEmpty {
                onASREnd()
                activeASRWindowID = nil
            }
        }
    }

    // MARK: - ASR Events

    /// Allow DoubaoIntegrationController to inject pre-captured state
    /// (recorded when mode was armed, before DoubaoIme steals focus).
    var overrideStartElement: AXUIElement?
    var overrideStartCursorPos: Int?

    private func onASRStart() {
        let state = readFocusedTextFieldState()
        // Use override (pre-armed) values if available, fall back to live read
        let element = overrideStartElement ?? state.element
        let cursorPos = overrideStartCursorPos ?? state.cursorPosition
        overrideStartElement = nil
        overrideStartCursorPos = nil

        asrTargetElement = element
        asrStartCursorPos = cursorPos

        DebugFileLogger.log("[DoubaoASR] ASR started, cursor=\(cursorPos.map(String.init) ?? "nil")")

        if let element, let cursorPos {
            delegate?.doubaoASRDidStart(element: element, cursorPosition: cursorPos)
        }
    }

    private func onASREnd() {
        // Brief delay to ensure the last insertText has been committed
        usleep(Self.postASRDelay)

        let endState = readFocusedTextFieldState()
        let endElement = endState.element
        let endPos = endState.cursorPosition

        let element = asrTargetElement ?? endElement
        let startPos = asrStartCursorPos

        if let element, let startPos, let endPos, endPos > startPos {
            // Happy path: precise cursor range available
            let length = endPos - startPos
            let asrText = readTextRange(element: element, location: startPos, length: length) ?? ""
            DebugFileLogger.log("[DoubaoASR] ASR ended, range=[\(startPos), \(endPos)), text=\(asrText.count) chars: \(asrText.prefix(50))")

            delegate?.doubaoASRDidEnd(
                element: element,
                startCursorPosition: startPos,
                endCursorPosition: endPos,
                asrText: asrText
            )
        } else if startPos == nil {
            // Fallback: no startPos (WeChat, Electron apps).
            // Signal to PostProcessor to use Cmd+A fallback.
            let el = element ?? AXUIElementCreateSystemWide()
            DebugFileLogger.log("[DoubaoASR] ASR ended (no cursor), using select-all fallback")

            delegate?.doubaoASRDidEnd(
                element: el,
                startCursorPosition: -1,  // signal: cursor unknown, use select-all
                endCursorPosition: -1,
                asrText: ""
            )
        } else {
            DebugFileLogger.log("[DoubaoASR] ASR ended, can't determine text (start=\(startPos.map(String.init) ?? "nil"), end=\(endPos.map(String.init) ?? "nil"))")
        }

        resetASRState()
    }

    private func resetASRState() {
        asrStartCursorPos = nil
        asrTargetElement = nil
    }

    // MARK: - Window Detection

    private struct WindowInfo {
        let id: Int
        let isOnScreen: Bool
    }

    private func findDoubaoASRWindows() -> [WindowInfo] {
        guard let windowList = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        var result: [WindowInfo] = []
        for w in windowList {
            let owner = w[kCGWindowOwnerName as String] as? String ?? ""
            guard owner == Self.ownerName else { continue }

            let layer = w[kCGWindowLayer as String] as? Int ?? -1
            guard layer == Self.asrLayer else { continue }

            let bounds = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
            let height = Int(bounds["Height"] as? Double ?? 0)
            guard height > 0, height <= Self.maxASRWindowHeight else { continue }

            let id = w[kCGWindowNumber as String] as? Int ?? 0
            let onScreen = w[kCGWindowIsOnscreen as String] as? Bool ?? false

            result.append(WindowInfo(id: id, isOnScreen: onScreen))
        }
        return result
    }

    // MARK: - Accessibility Helpers

    struct TextFieldState {
        let element: AXUIElement?
        let cursorPosition: Int?
    }

    /// Read cursor position from the currently focused text field.
    func readFocusedTextFieldState() -> TextFieldState {
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, 0.3)

        // Get focused app
        var focusedApp: AnyObject?
        guard AXUIElementCopyAttributeValue(
            systemWide, kAXFocusedApplicationAttribute as CFString, &focusedApp
        ) == .success else { return TextFieldState(element: nil, cursorPosition: nil) }

        let app = focusedApp as! AXUIElement
        AXUIElementSetMessagingTimeout(app, 0.3)

        // Get focused UI element
        var focusedElement: AnyObject?
        guard AXUIElementCopyAttributeValue(
            app, kAXFocusedUIElementAttribute as CFString, &focusedElement
        ) == .success else { return TextFieldState(element: nil, cursorPosition: nil) }

        let element = focusedElement as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.3)

        // Read cursor position (selected text range location)
        var rangeValue: AnyObject?
        guard AXUIElementCopyAttributeValue(
            element, kAXSelectedTextRangeAttribute as CFString, &rangeValue
        ) == .success else { return TextFieldState(element: element, cursorPosition: nil) }

        var range = CFRange(location: 0, length: 0)
        guard AXValueGetValue(rangeValue as! AXValue, .cfRange, &range) else {
            return TextFieldState(element: element, cursorPosition: nil)
        }

        // Cursor position = start of selection (for insertion point, length is 0)
        return TextFieldState(element: element, cursorPosition: range.location)
    }

    /// Read a specific text range from an AX element.
    private func readTextRange(element: AXUIElement, location: Int, length: Int) -> String? {
        guard length > 0 else { return nil }

        // Try parameterized attribute first (most accurate)
        var cfRange = CFRange(location: location, length: length)
        guard let rangeValue = AXValueCreate(.cfRange, &cfRange) else { return nil }

        var textValue: AnyObject?
        let status = AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXStringForRangeParameterizedAttribute as CFString,
            rangeValue,
            &textValue
        )

        if status == .success, let text = textValue as? String {
            return text
        }

        // Fallback: read entire value and substring
        var fullValue: AnyObject?
        guard AXUIElementCopyAttributeValue(
            element, kAXValueAttribute as CFString, &fullValue
        ) == .success, let fullText = fullValue as? String else { return nil }

        let start = fullText.index(fullText.startIndex, offsetBy: location, limitedBy: fullText.endIndex)
        let end = fullText.index(fullText.startIndex, offsetBy: location + length, limitedBy: fullText.endIndex)
        guard let start, let end else { return nil }
        return String(fullText[start..<end])
    }
}
