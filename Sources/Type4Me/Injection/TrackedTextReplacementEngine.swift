import AppKit
import ApplicationServices
import Foundation

struct TrackedTextReplacementRequest: @unchecked Sendable {
    let element: AXUIElement
    let processIdentifier: pid_t
    let bundleIdentifier: String
    let expectedFullValue: String
    let expectedRange: NSRange
    let expectedText: String
    let replacementText: String
    let placeholderCandidates: [String]

    init(
        element: AXUIElement,
        processIdentifier: pid_t,
        bundleIdentifier: String,
        expectedFullValue: String,
        expectedRange: NSRange,
        expectedText: String,
        replacementText: String,
        placeholderCandidates: [String] = []
    ) {
        self.element = element
        self.processIdentifier = processIdentifier
        self.bundleIdentifier = bundleIdentifier
        self.expectedFullValue = expectedFullValue
        self.expectedRange = expectedRange
        self.expectedText = expectedText
        self.replacementText = replacementText
        self.placeholderCandidates = placeholderCandidates
    }
}

struct TrackedTextReplacementSuccess: @unchecked Sendable {
    let afterFullValue: String
    let replacementRange: NSRange
    let afterSelectedRange: NSRange?
    let trackingContext: TrackedInjectionContext?

    init(
        afterFullValue: String,
        replacementRange: NSRange,
        afterSelectedRange: NSRange?,
        trackingContext: TrackedInjectionContext?
    ) {
        self.afterFullValue = afterFullValue
        self.replacementRange = replacementRange
        self.afterSelectedRange = afterSelectedRange
        self.trackingContext = trackingContext
    }
}

enum TrackedTextReplacementFailure: String, Error, Sendable {
    case appMismatch
    case controlMismatch
    case secureOrReadOnly
    case valueChangedBeforeWrite
    case rangeInvalid
    case textMismatch
    case singleLineViolation
    case noChange
    case controlReset
    case verificationMismatch
    case partialFailure
}

final class TrackedTextReplacementEngine: Sendable {
    let accessibilityClient: ReviseAccessibilityClient

    init(accessibilityClient: ReviseAccessibilityClient = SystemReviseAccessibilityClient.shared) {
        self.accessibilityClient = accessibilityClient
    }

    func replace(_ request: TrackedTextReplacementRequest) async -> Result<TrackedTextReplacementSuccess, TrackedTextReplacementFailure> {
        // 1. Pre-flight checks
        guard let snapshot = try? accessibilityClient.focusedControl() else {
            return .failure(.controlMismatch)
        }

        guard let snapshotPID = snapshot.processIdentifier, snapshotPID == request.processIdentifier,
              let snapshotBundle = snapshot.bundleIdentifier, snapshotBundle.caseInsensitiveCompare(request.bundleIdentifier) == .orderedSame else {
            return .failure(.appMismatch)
        }

        guard let focusedElement = snapshot.element, CFEqual(focusedElement, request.element) else {
            return .failure(.controlMismatch)
        }

        guard snapshot.isEditable, !snapshot.isSecure else {
            return .failure(.secureOrReadOnly)
        }

        guard let currentRawValue = try? accessibilityClient.value(of: request.element) else {
            return .failure(.controlMismatch)
        }

        guard currentRawValue == request.expectedFullValue else {
            return .failure(.valueChangedBeforeWrite)
        }

        let fullNSString = currentRawValue as NSString
        guard request.expectedRange.location >= 0,
              NSMaxRange(request.expectedRange) <= fullNSString.length else {
            return .failure(.rangeInvalid)
        }

        let extracted = fullNSString.substring(with: request.expectedRange)
        guard extracted == request.expectedText || VisibleTextProjection.project(extracted).text == VisibleTextProjection.project(request.expectedText).text else {
            return .failure(.textMismatch)
        }

        if snapshot.supportsSingleLineOnly && (request.replacementText.contains("\n") || request.replacementText.contains("\r")) {
            return .failure(.singleLineViolation)
        }

        // 2. Perform replacement
        let expectedAfterValue = fullNSString.replacingCharacters(in: request.expectedRange, with: request.replacementText)
        let originalSelectedRange = snapshot.selectedRange ?? (try? accessibilityClient.selectedRange(of: request.element))

        func restoreOriginalSelection() {
            guard let originalSelectedRange else { return }
            _ = try? accessibilityClient.setSelectedRange(originalSelectedRange, on: request.element)
        }

        func observedValue(expected: String) -> (matched: Bool, actual: String) {
            var actual = ""
            for attempt in 1...3 {
                usleep(attempt == 1 ? 50_000 : 100_000)
                if let value = try? accessibilityClient.value(of: request.element) {
                    actual = value
                    if value == expected { return (true, value) }
                }
            }
            return (false, actual)
        }

        let selectedTextSettable = accessibilityClient.isAttributeSettable(kAXSelectedTextAttribute as CFString, on: request.element)
        var requiresFallback = !selectedTextSettable

        if selectedTextSettable {
            do {
                try accessibilityClient.setSelectedRange(request.expectedRange, on: request.element)
                try accessibilityClient.setSelectedText(request.replacementText, on: request.element)
            } catch {
                let currentValue = (try? accessibilityClient.value(of: request.element)) ?? ""
                guard currentValue == request.expectedFullValue else {
                    restoreOriginalSelection()
                    return .failure(.partialFailure)
                }
                requiresFallback = true
            }

            if !requiresFallback {
                let directObservation = observedValue(expected: expectedAfterValue)
                if directObservation.matched {
                    requiresFallback = false
                } else if directObservation.actual == request.expectedFullValue {
                    // Some Electron controls report AXSelectedText as settable and
                    // return success while silently ignoring the write.
                    DebugFileLogger.log("revise_replace: selectedText no-op, using input fallback bundle=\(request.bundleIdentifier)")
                    requiresFallback = true
                } else {
                    restoreOriginalSelection()
                    return .failure(.verificationMismatch)
                }
            }
        }

        if requiresFallback && request.replacementText.isEmpty {
            do {
                try accessibilityClient.setSelectedRange(request.expectedRange, on: request.element)
                try accessibilityClient.pressDelete()
            } catch {
                restoreOriginalSelection()
                return .failure(.partialFailure)
            }
        } else if requiresFallback {
            // Transient paste
            let savedClipboard = ClipboardSnapshot.capture()
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(request.replacementText, forType: .string)
            pb.setData(Data(), forType: PasteboardHistoryPolicy.transientType)
            let postWriteChangeCount = pb.changeCount

            do {
                try accessibilityClient.setSelectedRange(request.expectedRange, on: request.element)
                usleep(30_000)
                try accessibilityClient.paste()
                usleep(100_000)
            } catch {
                savedClipboard.restore(expectedChangeCount: postWriteChangeCount)
                restoreOriginalSelection()
                return .failure(.partialFailure)
            }

            // Restore clipboard
            usleep(200_000)
            savedClipboard.restore(expectedChangeCount: postWriteChangeCount)
        }

        // 3. Post-write verification
        let finalObservation = observedValue(expected: expectedAfterValue)
        let verified = finalObservation.matched
        let actualAfter = finalObservation.actual

        if !verified {
            restoreOriginalSelection()
            if actualAfter == request.expectedFullValue {
                return .failure(.noChange)
            }
            if (actualAfter.isEmpty || request.placeholderCandidates.contains(actualAfter)) && !expectedAfterValue.isEmpty {
                return .failure(.controlReset)
            }
            return .failure(.verificationMismatch)
        }

        let newRange = NSRange(
            location: request.expectedRange.location,
            length: (request.replacementText as NSString).length
        )
        let afterSelectedRange = try? accessibilityClient.selectedRange(of: request.element)

        let trackingContext = TrackedInjectionContext(
            element: request.element,
            processIdentifier: request.processIdentifier,
            bundleIdentifier: request.bundleIdentifier,
            baselineValue: expectedAfterValue,
            injectedRange: newRange,
            beforeSelectedRange: request.expectedRange,
            afterSelectedRange: afterSelectedRange,
            placeholderCandidates: request.placeholderCandidates,
            sourceText: request.expectedText,
            injectedText: request.replacementText,
            sourceRecordID: "",
            modeID: UUID(),
            createdAt: Date()
        )

        return .success(TrackedTextReplacementSuccess(
            afterFullValue: expectedAfterValue,
            replacementRange: newRange,
            afterSelectedRange: afterSelectedRange,
            trackingContext: trackingContext
        ))
    }
}
