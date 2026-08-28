import AppKit
import ApplicationServices
import Carbon.HIToolbox

private final class ConfirmedTargetInvalidationState: @unchecked Sendable {
    private let lock = NSLock()
    private var reason: String?

    func invalidate(reason: String) {
        lock.lock()
        if self.reason == nil {
            self.reason = reason
        }
        lock.unlock()
    }

    var invalidationReason: String? {
        lock.lock()
        defer { lock.unlock() }
        return reason
    }
}

private func confirmedTargetAXObserverCallback(
    _ observer: AXObserver,
    _ element: AXUIElement,
    _ notification: CFString,
    _ refcon: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    let state = Unmanaged<ConfirmedTargetInvalidationState>
        .fromOpaque(refcon)
        .takeUnretainedValue()
    state.invalidate(reason: "accessibilityFocusChanged(\(notification))")
}

private func confirmedTargetInputEventCallback(
    _ proxy: CGEventTapProxy,
    _ type: CGEventType,
    _ event: CGEvent,
    _ refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let state = Unmanaged<ConfirmedTargetInvalidationState>
        .fromOpaque(refcon)
        .takeUnretainedValue()
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        state.invalidate(reason: "globalInputTapDisabled")
    } else {
        state.invalidate(reason: "userPointerInputAfterStop(\(type.rawValue))")
    }
    return Unmanaged.passUnretained(event)
}

final class TextInjectionEngine: @unchecked Sendable {

    /// AX-opaque editors expose the focused window but not their private text
    /// control. A pointer press can move that private focus and must invalidate
    /// the captured destination. A key-down alone does not prove a destination
    /// change, and the modifier used to stop recording can surface as a
    /// synthesized key-down after capture.
    static let opaqueTargetInvalidatingInputEventTypes: [CGEventType] = [
        .leftMouseDown,
        .rightMouseDown,
        .otherMouseDown,
    ]

    fileprivate final class FocusContinuityGuard: @unchecked Sendable {
        private let state = ConfirmedTargetInvalidationState()
        private let appElement: AXUIElement
        private var axObserver: AXObserver?
        private var axObserverContext: UnsafeMutableRawPointer?
        private var workspaceObservers: [NSObjectProtocol] = []
        private var inputEventTap: CFMachPort?
        private var inputEventTapSource: CFRunLoopSource?
        private var inputEventTapContext: UnsafeMutableRawPointer?
        private let cleanupLock = NSLock()
        private var hasStopped = false

        init(app: NSRunningApplication, observePointerInput: Bool = false) {
            appElement = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(appElement, 0.05)

            if observePointerInput {
                let eventMask = TextInjectionEngine
                    .opaqueTargetInvalidatingInputEventTypes
                    .reduce(CGEventMask(0)) {
                    $0 | (CGEventMask(1) << $1.rawValue)
                }
                let context = Unmanaged.passRetained(state).toOpaque()
                if let tap = CGEvent.tapCreate(
                    tap: .cgSessionEventTap,
                    place: .headInsertEventTap,
                    options: .listenOnly,
                    eventsOfInterest: eventMask,
                    callback: confirmedTargetInputEventCallback,
                    userInfo: context
                ), let source = CFMachPortCreateRunLoopSource(nil, tap, 0) {
                    inputEventTap = tap
                    inputEventTapSource = source
                    inputEventTapContext = context
                    CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
                    CGEvent.tapEnable(tap: tap, enable: true)
                } else {
                    Unmanaged<ConfirmedTargetInvalidationState>.fromOpaque(context).release()
                    state.invalidate(reason: "globalInputTapUnavailable")
                }
            }

            let workspaceCenter = NSWorkspace.shared.notificationCenter
            workspaceObservers.append(workspaceCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil,
                queue: nil
            ) { [weak self] notification in
                guard let self,
                      let activated = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                        as? NSRunningApplication,
                      activated.processIdentifier != app.processIdentifier
                else { return }
                self.state.invalidate(reason: "frontmostApplicationChanged")
            })
            workspaceObservers.append(workspaceCenter.addObserver(
                forName: NSWorkspace.didTerminateApplicationNotification,
                object: nil,
                queue: nil
            ) { [weak self] notification in
                guard let self,
                      let terminated = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                        as? NSRunningApplication,
                      terminated.processIdentifier == app.processIdentifier
                else { return }
                self.state.invalidate(reason: "targetApplicationTerminated")
            })

            var observer: AXObserver?
            guard AXObserverCreate(
                app.processIdentifier,
                confirmedTargetAXObserverCallback,
                &observer
            ) == .success, let observer else {
                if !observePointerInput {
                    state.invalidate(reason: "continuityObserverUnavailable")
                }
                DebugFileLogger.log("end target continuity: AX observer unavailable")
                return
            }

            let context = Unmanaged.passRetained(state).toOpaque()
            var registeredNotifications = 0
            for notification in [
                kAXFocusedUIElementChangedNotification as CFString,
                kAXFocusedWindowChangedNotification as CFString,
            ] {
                if AXObserverAddNotification(
                    observer,
                    appElement,
                    notification,
                    context
                ) == .success {
                    registeredNotifications += 1
                }
            }
            guard registeredNotifications > 0 else {
                Unmanaged<ConfirmedTargetInvalidationState>.fromOpaque(context).release()
                if !observePointerInput {
                    state.invalidate(reason: "continuityNotificationsUnavailable")
                }
                DebugFileLogger.log("end target continuity: AX notifications unavailable")
                return
            }

            axObserver = observer
            axObserverContext = context
            CFRunLoopAddSource(
                CFRunLoopGetMain(),
                AXObserverGetRunLoopSource(observer),
                .commonModes
            )
            DebugFileLogger.log(
                "end target continuity: observing notifications=\(registeredNotifications)"
            )
        }

        var invalidationReason: String? { state.invalidationReason }

        func stop() {
            cleanupLock.lock()
            guard !hasStopped else {
                cleanupLock.unlock()
                return
            }
            hasStopped = true
            let observer = axObserver
            let context = axObserverContext
            axObserver = nil
            axObserverContext = nil
            let eventTap = inputEventTap
            let eventTapSource = inputEventTapSource
            let eventTapContext = inputEventTapContext
            inputEventTap = nil
            inputEventTapSource = nil
            inputEventTapContext = nil
            let observers = workspaceObservers
            workspaceObservers.removeAll()
            cleanupLock.unlock()

            let workspaceCenter = NSWorkspace.shared.notificationCenter
            observers.forEach(workspaceCenter.removeObserver)
            if let observer {
                for notification in [
                    kAXFocusedUIElementChangedNotification as CFString,
                    kAXFocusedWindowChangedNotification as CFString,
                ] {
                    _ = AXObserverRemoveNotification(observer, appElement, notification)
                }
                CFRunLoopRemoveSource(
                    CFRunLoopGetMain(),
                    AXObserverGetRunLoopSource(observer),
                    .commonModes
                )
            }
            if let context {
                Unmanaged<ConfirmedTargetInvalidationState>.fromOpaque(context).release()
            }
            if let eventTapSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), eventTapSource, .commonModes)
            }
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: false)
                CFMachPortInvalidate(eventTap)
            }
            if let eventTapContext {
                Unmanaged<ConfirmedTargetInvalidationState>.fromOpaque(eventTapContext).release()
            }
        }

        deinit {
            stop()
        }
    }

    /// A strictly confirmed focused control captured at the instant the user
    /// stops a recording. Unlike normal outcome detection, this never guesses
    /// an editable control by traversing an application's accessibility tree.
    struct ConfirmedInjectionTarget: @unchecked Sendable {
        fileprivate enum Evidence: @unchecked Sendable {
            case exactElement(AXUIElement)
            case opaquePasteDestination(focusedWindow: AXUIElement)
        }

        fileprivate let evidence: Evidence
        let processIdentifier: pid_t
        let bundleIdentifier: String
        fileprivate let continuityGuard: FocusContinuityGuard

        fileprivate init(
            evidence: Evidence,
            processIdentifier: pid_t,
            bundleIdentifier: String,
            continuityGuard: FocusContinuityGuard
        ) {
            self.evidence = evidence
            self.processIdentifier = processIdentifier
            self.bundleIdentifier = bundleIdentifier
            self.continuityGuard = continuityGuard
        }

        fileprivate func stopObserving() {
            continuityGuard.stop()
        }

        fileprivate var usesOpaquePasteDestination: Bool {
            if case .opaquePasteDestination = evidence { return true }
            return false
        }
    }

    private struct ConfirmedFocusLookup {
        let element: AXUIElement?
        let source: String?
        let rejectionReason: String
    }

    private struct OpaquePasteDestinationLookup {
        let focusedWindow: AXUIElement?
        let sourceRole: String?
        let rejectionReason: String
    }

    private enum EditableDescendantScan: Equatable {
        case found
        case none
        case indeterminate
    }

    enum ClipboardRetention: Sendable, Equatable {
        /// Keep the dictated result in the system clipboard after the paste attempt.
        case retainResult
        /// Restore the clipboard captured before the paste attempt, including
        /// when no editable target was found.
        case restoreOriginal
    }

    private struct FocusedElementSnapshot {
        let element: AXUIElement?
        let processIdentifier: pid_t?
        let bundleIdentifier: String?
        let role: String?
        let subrole: String?
        let value: String?
        let placeholder: String?
        let accessibilityDescription: String?
        let selectedRange: NSRange?
        let isEditable: Bool
        /// true when AX successfully found a focused UI element; false when
        /// no element was found (e.g. desktop, no focused window).
        let hasFocusedElement: Bool
    }

    typealias ClipboardSnapshot = Type4Me.ClipboardSnapshot

    // MARK: - Public

    /// Whether a normal paste attempt retains its result or restores the
    /// clipboard that existed before injection.
    var clipboardRetention: ClipboardRetention = .restoreOriginal

    /// Inject text into the currently focused input field.
    /// Returns the outcome as soon as the paste is dispatched.
    /// Call ``finishClipboardRestore()`` afterward to restore the original clipboard.
    func inject(
        _ text: String,
        requiring confirmedTarget: ConfirmedInjectionTarget? = nil
    ) -> InjectionOutcome {
        guard !text.isEmpty else { return .inserted }
        return injectViaClipboard(
            text,
            trackingMetadata: nil,
            requiring: confirmedTarget
        ).outcome
    }

    /// Inject text while capturing enough Accessibility context to observe a
    /// later correction in the exact field Type4Me wrote into.
    func injectTracked(
        _ text: String,
        sourceText: String,
        sourceRecordID: String,
        modeID: UUID,
        requiring confirmedTarget: ConfirmedInjectionTarget? = nil
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
            ),
            requiring: confirmedTarget
        )
    }

    /// Restore the clipboard that was saved before injection.
    /// Safe to call even if there's nothing to restore.
    func finishClipboardRestore() {
        guard let pending = pendingClipboardRestore else { return }
        pendingClipboardRestore = nil
        // Electron apps (VS Code, Slack, Notion, Feishu) may need 200-500ms
        // to read the clipboard after Cmd+V. 150ms (post-paste 100 + this 50)
        // was too fast. Bumped to 300ms here for ~400ms total.
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

    /// Capture the frontmost, truly focused editable control. This is purposely
    /// stricter than `captureFocusedElementSnapshot()`, whose tree traversal
    /// fallback is useful for paste outcome detection but cannot prove intent.
    static func captureConfirmedInjectionTarget() -> ConfirmedInjectionTarget? {
        let captureStartedAt = ContinuousClock.now
        guard AXIsProcessTrusted() else {
            DebugFileLogger.log(
                "end target capture rejected reason=accessibilityUntrusted "
                    + "latency=\(ContinuousClock.now - captureStartedAt)"
            )
            return nil
        }
        guard let frontmostApp = NSWorkspace.shared.frontmostApplication else {
            DebugFileLogger.log(
                "end target capture rejected reason=frontmostMissing "
                    + "latency=\(ContinuousClock.now - captureStartedAt)"
            )
            return nil
        }
        guard frontmostApp.bundleIdentifier != Bundle.main.bundleIdentifier,
              let frontmostBundleIdentifier = frontmostApp.bundleIdentifier
        else {
            DebugFileLogger.log(
                "end target capture rejected reason=frontmostSelfOrMissingBundle "
                    + "latency=\(ContinuousClock.now - captureStartedAt)"
            )
            return nil
        }

        let lookup = confirmedFocusedElement(in: frontmostApp, prepareIfNeeded: true)
        if let element = lookup.element {
            let continuityGuard = FocusContinuityGuard(app: frontmostApp)
            DebugFileLogger.log(
                "end target capture confirmed pid=\(frontmostApp.processIdentifier) "
                    + "source=\(lookup.source ?? "unknown") "
                    + "latency=\(ContinuousClock.now - captureStartedAt)"
            )
            return ConfirmedInjectionTarget(
                evidence: .exactElement(element),
                processIdentifier: frontmostApp.processIdentifier,
                bundleIdentifier: frontmostBundleIdentifier,
                continuityGuard: continuityGuard
            )
        }

        let opaqueLookup = confirmedOpaquePasteDestination(in: frontmostApp)
        guard let focusedWindow = opaqueLookup.focusedWindow else {
            DebugFileLogger.log(
                "end target capture rejected reason=\(lookup.rejectionReason) "
                    + "opaque=\(opaqueLookup.rejectionReason) "
                    + "latency=\(ContinuousClock.now - captureStartedAt)"
            )
            return nil
        }

        // Some custom editors (notably fully custom AppKit/WebKit surfaces)
        // accept normal Paste but intentionally expose only their focused
        // window to Accessibility. Preserve the user's exact stop-time intent
        // by pinning that window and invalidating on subsequent pointer-driven
        // focus changes. App/window and AX focus changes are tracked separately.
        let continuityGuard = FocusContinuityGuard(
            app: frontmostApp,
            observePointerInput: true
        )
        DebugFileLogger.log(
            "end target capture confirmed pid=\(frontmostApp.processIdentifier) "
                + "source=opaquePasteDestination "
                + "role=\(opaqueLookup.sourceRole ?? "unknown") "
                + "latency=\(ContinuousClock.now - captureStartedAt)"
        )
        return ConfirmedInjectionTarget(
            evidence: .opaquePasteDestination(focusedWindow: focusedWindow),
            processIdentifier: frontmostApp.processIdentifier,
            bundleIdentifier: frontmostBundleIdentifier,
            continuityGuard: continuityGuard
        )
    }

    /// Chromium and Electron may keep their macOS accessibility tree dormant
    /// until an assistive client requests the enhanced interface. Preparing the
    /// active application while recording keeps stop-time capture fast and exact.
    /// This never traverses the window tree or chooses an arbitrary editable node.
    static func preparePreciseTargetCapture(for app: NSRunningApplication) {
        guard AXIsProcessTrusted(),
              app.bundleIdentifier != Bundle.main.bundleIdentifier,
              !app.isTerminated
        else { return }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 0.05)
        var currentValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            appElement,
            "AXEnhancedUserInterface" as CFString,
            &currentValue
        ) == .success,
           (currentValue as? Bool) == true {
            return
        }

        // Some Electron builds apply the value but return
        // kAXErrorNotImplemented. The subsequent focused-element query is the
        // source of truth, so this is deliberately best effort.
        _ = AXUIElementSetAttributeValue(
            appElement,
            "AXEnhancedUserInterface" as CFString,
            true as CFTypeRef
        )
    }

    /// Revalidate immediately before paste. The app and exact focused AX control
    /// must still match the stop-time snapshot; focus changes fail safe.
    private static func isStillConfirmed(_ target: ConfirmedInjectionTarget) -> Bool {
        if let reason = target.continuityGuard.invalidationReason {
            DebugFileLogger.log(
                "end target revalidate rejected reason=continuityInvalidated(\(reason))"
            )
            return false
        }
        guard let frontmostApp = NSWorkspace.shared.frontmostApplication else {
            DebugFileLogger.log("end target revalidate rejected reason=frontmostMissing")
            return false
        }
        guard frontmostApp.processIdentifier == target.processIdentifier,
              frontmostApp.bundleIdentifier?.caseInsensitiveCompare(target.bundleIdentifier) == .orderedSame
        else {
            DebugFileLogger.log("end target revalidate rejected reason=frontmostChanged")
            return false
        }

        switch target.evidence {
        case .exactElement(let targetElement):
            var lastRejectionReason = "focusedElementUnavailable"
            for attempt in 0..<4 {
                if let reason = target.continuityGuard.invalidationReason {
                    DebugFileLogger.log(
                        "end target revalidate rejected reason=continuityInvalidated(\(reason))"
                    )
                    return false
                }
                let lookup = confirmedFocusedElement(in: frontmostApp, prepareIfNeeded: false)
                if let element = lookup.element {
                    guard CFEqual(element, targetElement) else {
                        DebugFileLogger.log("end target revalidate rejected reason=elementChanged")
                        return false
                    }
                    return target.continuityGuard.invalidationReason == nil
                }
                lastRejectionReason = lookup.rejectionReason
                if attempt < 3 {
                    usleep(25_000)
                }
            }
            DebugFileLogger.log(
                "end target revalidate rejected reason=\(lastRejectionReason)"
            )
            return false

        case .opaquePasteDestination(let targetWindow):
            guard let currentWindow = focusedWindow(in: frontmostApp),
                  CFEqual(currentWindow, targetWindow)
            else {
                DebugFileLogger.log("end target revalidate rejected reason=opaqueWindowChanged")
                return false
            }
            guard standardPasteCommandState(in: frontmostApp) != nil else {
                DebugFileLogger.log("end target revalidate rejected reason=opaquePasteCommandMissing")
                return false
            }
            return target.continuityGuard.invalidationReason == nil
        }
    }

    /// Resolve only an explicitly focused element. Prefer the system-wide focus;
    /// when Chromium/Electron is AX-blind, ask the current frontmost application
    /// for its own focused element after enabling its enhanced AX bridge. Unlike
    /// normal paste outcome detection, this never scans for the first editable
    /// element, so multiple composers remain unambiguous.
    private static func confirmedFocusedElement(
        in frontmostApp: NSRunningApplication,
        prepareIfNeeded: Bool
    ) -> ConfirmedFocusLookup {
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, 0.05)
        let systemResult = copyFocusedElement(from: systemWide)
        if let element = systemResult.element,
           candidateRejectionReason(element, frontmostApp: frontmostApp) == nil {
            return ConfirmedFocusLookup(
                element: element,
                source: "systemWide",
                rejectionReason: "none"
            )
        }

        let appElement = AXUIElementCreateApplication(frontmostApp.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 0.05)
        var appResult = copyFocusedElement(from: appElement)
        if let element = appResult.element,
           candidateRejectionReason(element, frontmostApp: frontmostApp) == nil {
            return ConfirmedFocusLookup(
                element: element,
                source: "frontmostApplication",
                rejectionReason: "none"
            )
        }

        if prepareIfNeeded {
            preparePreciseTargetCapture(for: frontmostApp)
            // Chromium builds the AX tree asynchronously. Keep this bounded so
            // the global hotkey callback cannot stall for an unbounded period.
            for _ in 0..<4 {
                usleep(25_000)
                appResult = copyFocusedElement(from: appElement)
                if let element = appResult.element,
                   candidateRejectionReason(element, frontmostApp: frontmostApp) == nil {
                    return ConfirmedFocusLookup(
                        element: element,
                        source: "frontmostApplicationEnhanced",
                        rejectionReason: "none"
                    )
                }
            }
        }

        let systemCandidateReason = systemResult.element.flatMap {
            candidateRejectionReason($0, frontmostApp: frontmostApp)
        } ?? "queryError\(systemResult.error.rawValue)"
        let appCandidateReason = appResult.element.flatMap {
            candidateRejectionReason($0, frontmostApp: frontmostApp)
        } ?? "queryError\(appResult.error.rawValue)"
        return ConfirmedFocusLookup(
            element: nil,
            source: nil,
            rejectionReason: "focusedElementUnavailable(system=\(systemCandidateReason),app=\(appCandidateReason))"
        )
    }

    /// Confirm an input destination in applications that deliberately hide
    /// their internal editor from Accessibility. This is not a tree-search for
    /// an arbitrary field: the application must report the focused window
    /// itself as the focused element, expose a standard Cmd+V command,
    /// and expose no ordinary editable descendant in that window.
    private static func confirmedOpaquePasteDestination(
        in frontmostApp: NSRunningApplication
    ) -> OpaquePasteDestinationLookup {
        guard let window = focusedWindow(in: frontmostApp) else {
            return OpaquePasteDestinationLookup(
                focusedWindow: nil,
                sourceRole: nil,
                rejectionReason: "focusedWindowUnavailable"
            )
        }

        let appElement = AXUIElementCreateApplication(frontmostApp.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 0.05)
        let appFocused = copyFocusedElement(from: appElement).element
        let candidate = appFocused ?? window
        var candidatePID: pid_t = 0
        let pidMatches = AXUIElementGetPid(candidate, &candidatePID) == .success
            && candidatePID == frontmostApp.processIdentifier
        let role = stringAttribute(kAXRoleAttribute as CFString, from: candidate)
        let subrole = stringAttribute(kAXSubroleAttribute as CFString, from: candidate)
        let matchesWindow = CFEqual(candidate, window)
        let pasteCommandAvailable = standardPasteCommandState(in: frontmostApp) != nil
        let editorScan = scanForAccessibleEditableDescendant(in: window)
        let hasAccessibleEditor = editorScan == .found
        let editorScanComplete = editorScan != .indeterminate

        guard shouldUseOpaquePasteDestination(
            role: role,
            subrole: subrole,
            pasteCommandAvailable: pasteCommandAvailable,
            hasAccessibleEditableDescendant: hasAccessibleEditor,
            editableDescendantScanComplete: editorScanComplete,
            focusedElementMatchesWindow: matchesWindow,
            elementPIDMatchesFrontmost: pidMatches
        ) else {
            return OpaquePasteDestinationLookup(
                focusedWindow: nil,
                sourceRole: role,
                rejectionReason: "notConfirmed(role=\(role ?? "nil"),"
                    + "pasteCommand=\(pasteCommandAvailable),editor=\(hasAccessibleEditor),"
                    + "editorScanComplete=\(editorScanComplete),"
                    + "windowMatch=\(matchesWindow),pidMatch=\(pidMatches))"
            )
        }

        return OpaquePasteDestinationLookup(
            focusedWindow: window,
            sourceRole: role,
            rejectionReason: "none"
        )
    }

    static func shouldUseOpaquePasteDestination(
        role: String?,
        subrole: String?,
        pasteCommandAvailable: Bool,
        hasAccessibleEditableDescendant: Bool,
        editableDescendantScanComplete: Bool = true,
        focusedElementMatchesWindow: Bool,
        elementPIDMatchesFrontmost: Bool
    ) -> Bool {
        guard elementPIDMatchesFrontmost,
              focusedElementMatchesWindow,
              pasteCommandAvailable,
              !hasAccessibleEditableDescendant,
              editableDescendantScanComplete,
              !isSecureRole(role: role, subrole: subrole)
        else { return false }
        return role == (kAXWindowRole as String) || role == "AXSheet"
    }

    private static func focusedWindow(in app: NSRunningApplication) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 0.05)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedWindowAttribute as CFString,
            &value
        ) == .success, let value else { return nil }
        let window = unsafeDowncast(value, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(window, 0.05)
        return window
    }

    private static func scanForAccessibleEditableDescendant(
        in root: AXUIElement,
        depth: Int = 0,
        remainingNodeBudget: inout Int
    ) -> EditableDescendantScan {
        guard depth <= 10, remainingNodeBudget > 0 else { return .indeterminate }
        remainingNodeBudget -= 1

        func isSettable(_ attribute: CFString) -> Bool {
            var settable = DarwinBoolean(false)
            return AXUIElementIsAttributeSettable(root, attribute, &settable) == .success
                && settable.boolValue
        }
        if isStrictEditableCandidate(
            role: stringAttribute(kAXRoleAttribute as CFString, from: root),
            selectedRangeSettable: isSettable(kAXSelectedTextRangeAttribute as CFString),
            selectedTextSettable: isSettable(kAXSelectedTextAttribute as CFString),
            valueSettable: isSettable(kAXValueAttribute as CFString)
        ) {
            return .found
        }

        var childrenValue: CFTypeRef?
        let childrenResult = AXUIElementCopyAttributeValue(
            root,
            kAXChildrenAttribute as CFString,
            &childrenValue
        )
        if childrenResult == .attributeUnsupported || childrenResult == .noValue {
            return .none
        }
        guard childrenResult == .success,
              let children = childrenValue as? [AXUIElement]
        else { return .indeterminate }

        var sawIndeterminateChild = false
        for child in children where remainingNodeBudget > 0 {
            switch scanForAccessibleEditableDescendant(
                in: child,
                depth: depth + 1,
                remainingNodeBudget: &remainingNodeBudget
            ) {
            case .found:
                return .found
            case .indeterminate:
                sawIndeterminateChild = true
            case .none:
                break
            }
        }
        if remainingNodeBudget <= 0, !children.isEmpty {
            sawIndeterminateChild = true
        }
        return sawIndeterminateChild ? .indeterminate : .none
    }

    private static func scanForAccessibleEditableDescendant(
        in root: AXUIElement
    ) -> EditableDescendantScan {
        var nodeBudget = 300
        return scanForAccessibleEditableDescendant(
            in: root,
            remainingNodeBudget: &nodeBudget
        )
    }

    /// `nil` means the application has no standard Cmd+V command, `false`
    /// means the application reports it disabled, and `true` means enabled.
    /// Opaque editors may report a permanently disabled state even while their
    /// private first responder accepts Cmd+V, so only command existence is a
    /// reliable capability signal; focus continuity is verified separately.
    private static func standardPasteCommandState(in app: NSRunningApplication) -> Bool? {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 0.05)
        var menuBarValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appElement,
            kAXMenuBarAttribute as CFString,
            &menuBarValue
        ) == .success, let menuBarValue else { return nil }
        let menuBar = unsafeDowncast(menuBarValue, to: AXUIElement.self)
        return standardPasteCommandState(in: menuBar, depth: 0)
    }

    private static func standardPasteCommandState(
        in element: AXUIElement,
        depth: Int
    ) -> Bool? {
        guard depth <= 6 else { return nil }
        let role = stringAttribute(kAXRoleAttribute as CFString, from: element)
        if role == (kAXMenuItemRole as String),
           stringAttribute(kAXMenuItemCmdCharAttribute as CFString, from: element)?
            .caseInsensitiveCompare("v") == .orderedSame,
           numberAttribute(kAXMenuItemCmdModifiersAttribute as CFString, from: element) == 0 {
            return boolAttribute(kAXEnabledAttribute as CFString, from: element) == true
        }

        var childrenValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXChildrenAttribute as CFString,
            &childrenValue
        ) == .success, let children = childrenValue as? [AXUIElement]
        else { return nil }
        for child in children {
            if let state = standardPasteCommandState(in: child, depth: depth + 1) {
                return state
            }
        }
        return nil
    }

    private static func copyFocusedElement(
        from root: AXUIElement
    ) -> (element: AXUIElement?, error: AXError) {
        var focusedValue: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(
            root,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        )
        guard error == .success, let focusedValue else { return (nil, error) }
        let element = unsafeDowncast(focusedValue, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(element, 0.05)
        return (element, error)
    }

    private static func candidateRejectionReason(
        _ element: AXUIElement,
        frontmostApp: NSRunningApplication
    ) -> String? {
        var elementPID: pid_t = 0
        guard AXUIElementGetPid(element, &elementPID) == .success else {
            return "pidUnavailable"
        }
        func isSettable(_ attribute: CFString) -> Bool {
            var settable = DarwinBoolean(false)
            return AXUIElementIsAttributeSettable(element, attribute, &settable) == .success
                && settable.boolValue
        }
        return confirmedFocusRejectionReason(
            role: stringAttribute(kAXRoleAttribute as CFString, from: element),
            subrole: stringAttribute(kAXSubroleAttribute as CFString, from: element),
            isFocused: boolAttribute(kAXFocusedAttribute as CFString, from: element) == true,
            selectedRangeSettable: isSettable(kAXSelectedTextRangeAttribute as CFString),
            selectedTextSettable: isSettable(kAXSelectedTextAttribute as CFString),
            valueSettable: isSettable(kAXValueAttribute as CFString),
            elementPID: elementPID,
            frontmostPID: frontmostApp.processIdentifier
        )
    }

    static func confirmedFocusRejectionReason(
        role: String?,
        subrole: String?,
        isFocused: Bool,
        selectedRangeSettable: Bool,
        selectedTextSettable: Bool,
        valueSettable: Bool,
        elementPID: pid_t,
        frontmostPID: pid_t
    ) -> String? {
        guard elementPID == frontmostPID else { return "pidMismatch" }
        guard isFocused else { return "notFocused" }
        guard isStrictEditableCandidate(
            role: role,
            selectedRangeSettable: selectedRangeSettable,
            selectedTextSettable: selectedTextSettable,
            valueSettable: valueSettable
        ) else { return "notEditable" }
        guard !isSecureRole(role: role, subrole: subrole) else { return "secure" }
        return nil
    }

    static func isStrictEditableCandidate(
        role: String?,
        selectedRangeSettable: Bool,
        selectedTextSettable: Bool,
        valueSettable: Bool
    ) -> Bool {
        if selectedRangeSettable || selectedTextSettable { return true }
        let textRoles: Set<String> = [
            kAXTextFieldRole as String,
            kAXTextAreaRole as String,
            kAXComboBoxRole as String,
            "AXSearchField",
        ]
        return valueSettable && textRoles.contains(role ?? "")
    }

    static func isSecureRole(role: String?, subrole: String?) -> Bool {
        [role, subrole]
        .compactMap { $0?.lowercased() }
        .contains { $0.contains("secure") || $0.contains("password") }
    }

    private static func stringAttribute(
        _ attribute: CFString,
        from element: AXUIElement
    ) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private static func boolAttribute(
        _ attribute: CFString,
        from element: AXUIElement
    ) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }
        return value as? Bool
    }

    private static func numberAttribute(
        _ attribute: CFString,
        from element: AXUIElement
    ) -> Int? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }
        return (value as? NSNumber)?.intValue
    }

    // MARK: - Clipboard injection

    private struct PendingClipboardRestore {
        let snapshot: ClipboardSnapshot
        let changeCount: Int
    }

    private var pendingClipboardRestore: PendingClipboardRestore?

    private func injectViaClipboard(
        _ text: String,
        trackingMetadata: (sourceText: String, sourceRecordID: String, modeID: UUID)?,
        requiring confirmedTarget: ConfirmedInjectionTarget?
    ) -> TrackedInjectionResult {
        defer { confirmedTarget?.stopObserving() }
        let shouldRestoreClipboard = clipboardRetention == .restoreOriginal
        let savedClipboard = shouldRestoreClipboard ? ClipboardSnapshot.capture() : nil

        // If Type4Me is frontmost, yield focus so the target application receives paste
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Bundle.main.bundleIdentifier {
            DispatchQueue.main.sync {
                NSApp.hide(nil)
            }
            usleep(50_000)
        }

        // Snapshot focused element BEFORE paste for outcome detection
        let before = captureFocusedElementSnapshot()

        copyToClipboard(text, transient: shouldRestoreClipboard)
        let postWriteChangeCount = NSPasteboard.general.changeCount
        usleep(50_000)

        // Keep the strong end-target check inside the paste critical path. If
        // focus changed during processing or clipboard preparation, retain the
        // result for manual paste regardless of the normal clipboard policy.
        if let confirmedTarget, !Self.isStillConfirmed(confirmedTarget) {
            copyToClipboard(text)
            pendingClipboardRestore = nil
            DebugFileLogger.log("injection guard: end target changed; paste skipped")
            return TrackedInjectionResult(
                outcome: .copiedToClipboard,
                observationContext: nil
            )
        }
        guard simulatePaste() else {
            copyToClipboard(text)
            pendingClipboardRestore = nil
            DebugFileLogger.log("injection guard: paste event creation failed")
            return TrackedInjectionResult(
                outcome: .copiedToClipboard,
                observationContext: nil
            )
        }
        usleep(100_000)

        // Snapshot AFTER paste and compare to detect if text landed
        let after = captureFocusedElementSnapshot()
        let detectedOutcome = confirmedTarget?.usesOpaquePasteDestination == true
            ? InjectionOutcome.inserted
            : inferInjectionOutcome(before: before, after: after, pastedText: text)
        let outcome = Self.finalizeOutcome(
            detectedOutcome,
            retention: clipboardRetention
        )

        // Defer restoration so the target app has time to consume Cmd+V.
        // Keep it pending for every result so a failed paste cannot leak text
        // into the clipboard under a restoring policy.
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

    /// A restore policy cannot truthfully report a clipboard fallback: its
    /// temporary pasteboard contents are restored after the paste attempt.
    static func finalizeOutcome(
        _ detectedOutcome: InjectionOutcome,
        retention: ClipboardRetention
    ) -> InjectionOutcome {
        if detectedOutcome == .copiedToClipboard, retention == .restoreOriginal {
            return .notInserted
        }
        return detectedOutcome
    }

    private func simulatePaste() -> Bool {
        let vKeyCode: CGKeyCode = 9 // 'v'

        guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: vKeyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: vKeyCode, keyDown: false)
        else { return false }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }

    /// Ask the frontmost application to expose its enhanced AX tree. Electron
    /// implements this on the application element, not the focused window.
    private func enableEnhancedAX(for app: NSRunningApplication) {
        Self.preparePreciseTargetCapture(for: app)
    }

    private func captureFocusedElementSnapshot() -> FocusedElementSnapshot? {
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
        return snapshotFromElement(element, bundleIdentifier: frontmostBundleID)
    }

    private func snapshotFromElement(_ element: AXUIElement, bundleIdentifier: String?) -> FocusedElementSnapshot {
        AXUIElementSetMessagingTimeout(element, 0.5)
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

    private func inferInjectionOutcome(
        before: FocusedElementSnapshot?,
        after: FocusedElementSnapshot?,
        pastedText: String
    ) -> InjectionOutcome {
        DebugFileLogger.log("injection detect: before=\(before.map { "bundle=\($0.bundleIdentifier ?? "nil") role=\($0.role ?? "nil") editable=\($0.isEditable) hasFocus=\($0.hasFocusedElement) valueLength=\($0.value?.count ?? -1)" } ?? "nil")")
        DebugFileLogger.log("injection detect: after=\(after.map { "bundle=\($0.bundleIdentifier ?? "nil") role=\($0.role ?? "nil") editable=\($0.isEditable) hasFocus=\($0.hasFocusedElement) valueLength=\($0.value?.count ?? -1)" } ?? "nil")")

        guard let before, let after else {
            return .inserted
        }

        // No frontmost app → nothing to paste into (e.g. desktop)
        if before.bundleIdentifier == nil && after.bundleIdentifier == nil {
            return .copiedToClipboard
        }

        // AX completely blind (WeChat, Feishu, etc.): if we have a frontmost
        // app but can't see the focused element, assume Cmd+V worked.
        // Desktop/no-app cases are already handled above (bundleIdentifier == nil).
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
