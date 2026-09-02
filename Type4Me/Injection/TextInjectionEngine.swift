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

final class TextInjectionEngine: @unchecked Sendable {

    /// Monotonic input epoch shared with `HotkeyManager`. The hotkey tap records
    /// a potentially focus-changing event before dispatching its stop callback,
    /// so a token captured by that callback includes the exact stop event but
    /// excludes every later key or pointer press.
    final class InputActivityMonitor: @unchecked Sendable {
        struct Token: Equatable, Sendable {
            fileprivate let generation: UInt64
            fileprivate let sequence: UInt64
        }

        private struct ObservedInput: Equatable {
            let typeRawValue: UInt32
            let keyCode: Int64
            let buttonNumber: Int64
            let timestamp: UInt64
            let rawFlags: UInt64
            let modifiers: UInt64
            let deviceModifiers: UInt64
            let sourceUnixProcessID: Int64
            let sourceUserData: Int64
            let sourceStateID: Int64
            let systemKeyType: Int
            let systemKeyState: Int

            init(type: CGEventType, event: CGEvent) {
                typeRawValue = type.rawValue
                keyCode = event.getIntegerValueField(.keyboardEventKeycode)
                buttonNumber = event.getIntegerValueField(.mouseEventButtonNumber)
                timestamp = event.timestamp
                rawFlags = event.flags.rawValue
                modifiers = event.flags.rawValue & InputActivityMonitor.modifierMask
                deviceModifiers = event.flags.rawValue & ModeBinding.allDeviceModifierMasks
                sourceUnixProcessID = event.getIntegerValueField(.eventSourceUnixProcessID)
                sourceUserData = event.getIntegerValueField(.eventSourceUserData)
                sourceStateID = event.getIntegerValueField(.eventSourceStateID)
                if type.rawValue == 14,
                   let nsEvent = NSEvent(cgEvent: event),
                   nsEvent.type == .systemDefined,
                   nsEvent.subtype.rawValue == 8 {
                    systemKeyType = Int((nsEvent.data1 >> 16) & 0xFFFF)
                    systemKeyState = Int((nsEvent.data1 >> 8) & 0xFF)
                } else {
                    systemKeyType = -1
                    systemKeyState = -1
                }
            }

            var diagnosticSummary: String {
                "type=\(typeRawValue),keyCode=\(keyCode),button=\(buttonNumber),"
                    + "timestamp=\(timestamp),"
                    + "rawFlags=\(rawFlags),modifiers=\(modifiers),"
                    + "deviceModifiers=\(deviceModifiers),"
                    + "sourcePID=\(sourceUnixProcessID),sourceUserData=\(sourceUserData),"
                    + "sourceStateID=\(sourceStateID),"
                    + "systemKeyType=\(systemKeyType),systemKeyState=\(systemKeyState)"
            }
        }

        private struct SequenceChange {
            let sequence: UInt64
            let input: ObservedInput
        }

        private enum PendingRelease: Equatable {
            case keyUp(keyCode: Int64)
            case mouseUp(typeRawValue: UInt32, buttonNumber: Int64)
            case systemKeyUp(keyType: Int)

            func matches(_ input: ObservedInput) -> Bool {
                switch self {
                case .keyUp(let keyCode):
                    return input.typeRawValue == CGEventType.keyUp.rawValue
                        && input.keyCode == keyCode
                case .mouseUp(let typeRawValue, let buttonNumber):
                    return input.typeRawValue == typeRawValue
                        && input.buttonNumber == buttonNumber
                case .systemKeyUp(let keyType):
                    return input.typeRawValue == 14
                        && input.systemKeyType == keyType
                        && input.systemKeyState == 0x0B
                }
            }
        }

        private struct StopGestureTail {
            private static let maximumReleaseReconciliationEvents = 2
            private static let fnSystemActionKeyCode: Int64 = 179

            var pendingRelease: PendingRelease?
            var remainingModifiers: UInt64
            var remainingDeviceModifiers: UInt64
            var releasedModifierKeyCode: Int64?
            var remainingReleaseReconciliationEvents: Int
            var pendingFnSystemActionTimestamp: UInt64?
            let expiresAt: UInt64

            init?(trigger: ObservedInput, now: UInt64) {
                switch trigger.typeRawValue {
                case CGEventType.keyDown.rawValue:
                    pendingRelease = .keyUp(keyCode: trigger.keyCode)
                case CGEventType.keyUp.rawValue:
                    pendingRelease = nil
                case CGEventType.leftMouseDown.rawValue:
                    pendingRelease = .mouseUp(
                        typeRawValue: CGEventType.leftMouseUp.rawValue,
                        buttonNumber: trigger.buttonNumber
                    )
                case CGEventType.rightMouseDown.rawValue:
                    pendingRelease = .mouseUp(
                        typeRawValue: CGEventType.rightMouseUp.rawValue,
                        buttonNumber: trigger.buttonNumber
                    )
                case CGEventType.otherMouseDown.rawValue:
                    pendingRelease = .mouseUp(
                        typeRawValue: CGEventType.otherMouseUp.rawValue,
                        buttonNumber: trigger.buttonNumber
                    )
                case CGEventType.leftMouseUp.rawValue,
                     CGEventType.rightMouseUp.rawValue,
                     CGEventType.otherMouseUp.rawValue,
                     CGEventType.flagsChanged.rawValue:
                    pendingRelease = nil
                case 14 where trigger.systemKeyState == 0x0A:
                    pendingRelease = .systemKeyUp(keyType: trigger.systemKeyType)
                case 14:
                    pendingRelease = nil
                default:
                    return nil
                }
                remainingModifiers = trigger.modifiers
                remainingDeviceModifiers = trigger.deviceModifiers
                releasedModifierKeyCode = nil
                remainingReleaseReconciliationEvents = 0
                pendingFnSystemActionTimestamp = nil
                expiresAt = now &+ 500_000_000
                if trigger.typeRawValue == CGEventType.flagsChanged.rawValue,
                   trigger.modifiers == 0,
                   trigger.deviceModifiers == 0,
                   ModeBinding.modifierEventFlag(for: Int(trigger.keyCode)) != nil {
                    armReleaseReconciliation(for: trigger.keyCode)
                }
                guard pendingRelease != nil
                    || remainingModifiers != 0
                    || remainingDeviceModifiers != 0
                    || remainingReleaseReconciliationEvents != 0
                else { return nil }
            }

            mutating func consumeIfMatching(_ input: ObservedInput, now: UInt64) -> Bool {
                guard now <= expiresAt else { return false }
                if consumeFnSystemActionEchoIfMatching(input) {
                    return true
                }
                if consumeReleaseReconciliationIfMatching(input) {
                    return true
                }
                if let pendingRelease, pendingRelease.matches(input) {
                    guard input.modifiers & ~remainingModifiers == 0,
                          input.deviceModifiers & ~remainingDeviceModifiers == 0
                    else { return false }
                    self.pendingRelease = nil
                    remainingModifiers = input.modifiers
                    remainingDeviceModifiers = input.deviceModifiers
                    return true
                }

                guard input.typeRawValue == CGEventType.flagsChanged.rawValue else {
                    return false
                }
                let keyCode = Int(input.keyCode)
                guard let standardFlag = ModeBinding.modifierEventFlag(for: keyCode) else {
                    return false
                }
                let standardFlagRaw = standardFlag.rawValue
                guard input.modifiers & ~remainingModifiers == 0,
                      input.deviceModifiers & ~remainingDeviceModifiers == 0
                else { return false }

                if let deviceMask = ModeBinding.deviceModifierMask(for: keyCode),
                   remainingDeviceModifiers != 0 {
                    // Device-dependent bits preserve left/right identity. Only
                    // release a physical modifier that belonged to the stop
                    // chord; a newly pressed right/left sibling is never tail.
                    guard remainingDeviceModifiers & deviceMask != 0,
                          input.deviceModifiers & deviceMask == 0
                    else { return false }
                } else {
                    // Fallback for Fn and events lacking device-dependent bits:
                    // require this exact modifier class to disappear. Equal
                    // aggregate flags are a new physical event, not release tail.
                    let removedModifiers = remainingModifiers & ~input.modifiers
                    guard removedModifiers == standardFlagRaw else { return false }
                }
                remainingModifiers = input.modifiers
                remainingDeviceModifiers = input.deviceModifiers
                if remainingModifiers == 0, remainingDeviceModifiers == 0 {
                    armReleaseReconciliation(for: input.keyCode)
                }
                return true
            }

            private mutating func consumeFnSystemActionEchoIfMatching(
                _ input: ObservedInput
            ) -> Bool {
                guard releasedModifierKeyCode == Int64(kVK_Function) else { return false }
                if let pendingFnSystemActionTimestamp {
                    guard Self.isFnSystemActionEcho(input, type: .keyUp),
                          input.timestamp == pendingFnSystemActionTimestamp
                    else { return false }
                    self.pendingFnSystemActionTimestamp = nil
                    releasedModifierKeyCode = nil
                    remainingReleaseReconciliationEvents = 0
                    return true
                }

                guard remainingReleaseReconciliationEvents
                    == Self.maximumReleaseReconciliationEvents,
                    Self.isFnSystemActionEcho(input, type: .keyDown),
                    input.timestamp != 0
                else { return false }
                pendingFnSystemActionTimestamp = input.timestamp
                remainingReleaseReconciliationEvents = 0
                return true
            }

            private static func isFnSystemActionEcho(
                _ input: ObservedInput,
                type: CGEventType
            ) -> Bool {
                input.typeRawValue == type.rawValue
                    && input.keyCode == fnSystemActionKeyCode
                    && input.rawFlags == CGEventFlags.maskNonCoalesced.rawValue
                    && input.modifiers == 0
                    && input.deviceModifiers == 0
                    && input.sourceUnixProcessID == 0
                    && input.sourceUserData == 0
                    && input.sourceStateID
                        == Int64(CGEventSourceStateID.hidSystemState.rawValue)
            }

            private mutating func armReleaseReconciliation(for keyCode: Int64) {
                releasedModifierKeyCode = keyCode
                remainingReleaseReconciliationEvents = Self.maximumReleaseReconciliationEvents
            }

            private mutating func consumeReleaseReconciliationIfMatching(
                _ input: ObservedInput
            ) -> Bool {
                guard remainingReleaseReconciliationEvents > 0,
                      let releasedModifierKeyCode,
                      input.modifiers == 0,
                      input.deviceModifiers == 0
                else { return false }

                let isMatchingKeyUp = input.typeRawValue == CGEventType.keyUp.rawValue
                    && input.keyCode == releasedModifierKeyCode
                let isMatchingFlagsEcho = input.typeRawValue == CGEventType.flagsChanged.rawValue
                    && (input.keyCode == releasedModifierKeyCode || input.keyCode == 255)
                guard isMatchingKeyUp || isMatchingFlagsEcho else { return false }

                remainingReleaseReconciliationEvents -= 1
                if remainingReleaseReconciliationEvents == 0 {
                    self.releasedModifierKeyCode = nil
                }
                return true
            }

            var isComplete: Bool {
                pendingRelease == nil
                    && remainingModifiers == 0
                    && remainingDeviceModifiers == 0
                    && remainingReleaseReconciliationEvents == 0
                    && pendingFnSystemActionTimestamp == nil
            }

            var hasPendingRequiredEcho: Bool {
                pendingFnSystemActionTimestamp != nil
            }
        }

        private static let modifierMask = CGEventFlags.maskCommand.rawValue
            | CGEventFlags.maskShift.rawValue
            | CGEventFlags.maskAlternate.rawValue
            | CGEventFlags.maskControl.rawValue
            | CGEventFlags.maskSecondaryFn.rawValue

        private let lock = NSLock()
        private var generation: UInt64 = 0
        private var sequence: UInt64 = 0
        private var isAvailable = false
        private var eventTap: CFMachPort?
        private var assumesLiveForTesting = false
        private var currentEvent: ObservedInput?
        private var currentEventAuthorizedForStopCapture = false
        private var allowedStopTail: StopGestureTail?
        private var recentSequenceChanges: [SequenceChange] = []

        func start(eventTap: CFMachPort) {
            lock.lock()
            generation &+= 1
            isAvailable = true
            self.eventTap = eventTap
            assumesLiveForTesting = false
            currentEvent = nil
            currentEventAuthorizedForStopCapture = false
            allowedStopTail = nil
            recentSequenceChanges.removeAll(keepingCapacity: true)
            lock.unlock()
        }

        func startForTesting() {
            lock.lock()
            generation &+= 1
            isAvailable = true
            eventTap = nil
            assumesLiveForTesting = true
            currentEvent = nil
            currentEventAuthorizedForStopCapture = false
            allowedStopTail = nil
            recentSequenceChanges.removeAll(keepingCapacity: true)
            lock.unlock()
        }

        func stop() {
            lock.lock()
            generation &+= 1
            isAvailable = false
            eventTap = nil
            assumesLiveForTesting = false
            currentEvent = nil
            currentEventAuthorizedForStopCapture = false
            allowedStopTail = nil
            recentSequenceChanges.removeAll(keepingCapacity: true)
            lock.unlock()
        }

        func beginEvent(type: CGEventType, event: CGEvent, isSynthetic: Bool) {
            let input = ObservedInput(type: type, event: event)
            lock.lock()
            currentEvent = input
            currentEventAuthorizedForStopCapture = false
            guard !isSynthetic else {
                lock.unlock()
                return
            }

            let now = DispatchTime.now().uptimeNanoseconds
            if var tail = allowedStopTail,
               tail.consumeIfMatching(input, now: now) {
                allowedStopTail = tail.isComplete ? nil : tail
                lock.unlock()
                DebugFileLogger.log(
                    "opaque input continuity: consumed stop tail \(input.diagnosticSummary)"
                )
                return
            }
            allowedStopTail = nil
            sequence &+= 1
            recentSequenceChanges.append(SequenceChange(sequence: sequence, input: input))
            if recentSequenceChanges.count > 8 {
                recentSequenceChanges.removeFirst(recentSequenceChanges.count - 8)
            }
            lock.unlock()
        }

        func endEvent() {
            lock.lock()
            currentEvent = nil
            currentEventAuthorizedForStopCapture = false
            lock.unlock()
        }

        @discardableResult
        func authorizeCurrentEventForStopCapture() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard isLiveLocked(), currentEvent != nil else { return false }
            currentEventAuthorizedForStopCapture = true
            return true
        }

        func captureToken() -> Token? {
            lock.lock()
            defer { lock.unlock() }
            guard isLiveLocked() else { return nil }
            return Token(generation: generation, sequence: sequence)
        }

        func isUnchanged(since token: Token) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return validationFailureReasonLocked(since: token) == nil
        }

        func validationFailureReason(since token: Token) -> String? {
            lock.lock()
            defer { lock.unlock() }
            return validationFailureReasonLocked(since: token)
        }

        @discardableResult
        func allowCurrentStopGestureTail(since token: Token) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard isLiveLocked(),
                  generation == token.generation,
                  sequence == token.sequence,
                  currentEventAuthorizedForStopCapture,
                  let currentEvent
            else { return false }
            allowedStopTail = StopGestureTail(
                trigger: currentEvent,
                now: DispatchTime.now().uptimeNanoseconds
            )
            return allowedStopTail != nil
        }

        private func isLiveLocked() -> Bool {
            guard isAvailable else { return false }
            if assumesLiveForTesting { return true }
            guard let eventTap, CFMachPortIsValid(eventTap) else { return false }
            return CGEvent.tapIsEnabled(tap: eventTap)
        }

        private func validationFailureReasonLocked(since token: Token) -> String? {
            guard isAvailable else { return "monitorUnavailable" }
            if !assumesLiveForTesting {
                guard let eventTap else { return "eventTapMissing" }
                guard CFMachPortIsValid(eventTap) else { return "eventTapInvalid" }
                guard CGEvent.tapIsEnabled(tap: eventTap) else { return "eventTapDisabled" }
            }
            guard generation == token.generation else {
                return "generationChanged(expected=\(token.generation),current=\(generation))"
            }
            if allowedStopTail?.hasPendingRequiredEcho == true {
                return "stopTailIncomplete"
            }
            guard sequence == token.sequence else {
                let changes = recentSequenceChanges
                    .filter { $0.sequence > token.sequence }
                    .map { "#\($0.sequence){\($0.input.diagnosticSummary)}" }
                    .joined(separator: ";")
                return "sequenceChanged(expected=\(token.sequence),current=\(sequence),events=[\(changes)])"
            }
            return nil
        }
    }

    private static let inputActivityMonitor = InputActivityMonitor()

    /// Physical keyboard/pointer events capable of changing a private first
    /// responder. Only the exact release-only tail armed for the current stop
    /// gesture is filtered by `InputActivityMonitor`.
    static func canChangeOpaqueInputFocus(_ type: CGEventType) -> Bool {
        switch type {
        case .keyDown, .keyUp, .flagsChanged,
             .leftMouseDown, .leftMouseUp,
             .rightMouseDown, .rightMouseUp,
             .otherMouseDown, .otherMouseUp,
             .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
             .scrollWheel:
            return true
        default:
            return type.rawValue == 14
        }
    }

    /// Per-process nonce: Type4Me can recognize its own generated shortcuts,
    /// while another process cannot bypass continuity with a public magic value.
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

    static func globalInputMonitorDidStart(eventTap: CFMachPort) {
        inputActivityMonitor.start(eventTap: eventTap)
    }

    static func globalInputMonitorDidStop() {
        inputActivityMonitor.stop()
    }

    /// Called by `HotkeyManager` immediately before a binding callback. This is
    /// the proof that a capture occurring inside the callback belongs to the
    /// current hotkey event rather than an unrelated concurrent input event.
    @discardableResult
    static func authorizeCurrentGlobalInputForStopCapture() -> Bool {
        inputActivityMonitor.authorizeCurrentEventForStopCapture()
    }

    static func beginGlobalInputEvent(type: CGEventType, event: CGEvent) {
        guard canChangeOpaqueInputFocus(type) else { return }
        inputActivityMonitor.beginEvent(
            type: type,
            event: event,
            isSynthetic: isSyntheticInput(event)
        )
    }

    static func endGlobalInputEvent(type: CGEventType) {
        guard canChangeOpaqueInputFocus(type) else { return }
        inputActivityMonitor.endEvent()
    }

    fileprivate final class FocusContinuityGuard: @unchecked Sendable {
        private let state = ConfirmedTargetInvalidationState()
        private let appElement: AXUIElement
        private var axObserver: AXObserver?
        private var axObserverContext: UnsafeMutableRawPointer?
        private var workspaceObservers: [NSObjectProtocol] = []
        private let cleanupLock = NSLock()
        private var hasStopped = false

        init(app: NSRunningApplication, requiresAXContinuity: Bool = true) {
            appElement = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(appElement, 0.05)

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
                if requiresAXContinuity {
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
                if requiresAXContinuity {
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
        }

        deinit {
            stop()
        }
    }

    /// A stop-time destination with an explicit evidence tier. Exact AX targets
    /// prove the focused editable element. Best-effort opaque targets only pin
    /// the app/window and input epoch because their private editor is invisible
    /// to Accessibility; callers must retain the dictated text in the clipboard.
    struct EndInjectionTarget: @unchecked Sendable {
        fileprivate enum Evidence: @unchecked Sendable {
            case exactElement(AXUIElement)
            case bestEffortOpaqueWindow(
                focusedWindow: AXUIElement,
                inputToken: InputActivityMonitor.Token
            )
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

        fileprivate var isBestEffortOpaque: Bool {
            if case .bestEffortOpaqueWindow = evidence { return true }
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
        let pasteCommandEnabled: Bool?
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
        /// true when AX successfully found a focused UI element; false when
        /// no element was found (e.g. desktop, no focused window).
        var hasFocusedElement: Bool = true
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
        requiring endTarget: EndInjectionTarget? = nil
    ) -> InjectionOutcome {
        guard !text.isEmpty else { return .inserted }
        return injectViaClipboard(
            text,
            trackingMetadata: nil,
            requiring: endTarget
        ).outcome
    }

    /// Inject text while capturing enough Accessibility context to observe a
    /// later correction in the exact field Type4Me wrote into.
    func injectTracked(
        _ text: String,
        sourceText: String,
        sourceRecordID: String,
        modeID: UUID,
        requiring endTarget: EndInjectionTarget? = nil
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
            requiring: endTarget
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

    /// Capture the stop-time destination. Exact AX fields remain the strong
    /// path. An AX-opaque window is captured only as an explicitly best-effort
    /// destination with a global input epoch that must remain unchanged.
    static func captureEndInjectionTarget() -> EndInjectionTarget? {
        let captureStartedAt = ContinuousClock.now
        let stopInputToken = inputActivityMonitor.captureToken()
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
            if let stopInputToken,
               !inputActivityMonitor.isUnchanged(since: stopInputToken) {
                DebugFileLogger.log(
                    "end target capture rejected reason=inputChangedDuringExactCapture "
                        + "latency=\(ContinuousClock.now - captureStartedAt)"
                )
                return nil
            }

            let continuityGuard = FocusContinuityGuard(app: frontmostApp)
            if let stopInputToken,
               !inputActivityMonitor.isUnchanged(since: stopInputToken) {
                continuityGuard.stop()
                DebugFileLogger.log(
                    "end target capture rejected reason=inputChangedBeforeExactGuard "
                        + "latency=\(ContinuousClock.now - captureStartedAt)"
                )
                return nil
            }
            DebugFileLogger.log(
                "end target capture exactConfirmed pid=\(frontmostApp.processIdentifier) "
                    + "source=\(lookup.source ?? "unknown") "
                    + "latency=\(ContinuousClock.now - captureStartedAt)"
            )
            return EndInjectionTarget(
                evidence: .exactElement(element),
                processIdentifier: frontmostApp.processIdentifier,
                bundleIdentifier: frontmostBundleIdentifier,
                continuityGuard: continuityGuard
            )
        }

        guard let stopInputToken else {
            DebugFileLogger.log(
                "end target capture rejected reason=\(lookup.rejectionReason) "
                    + "opaque=inputMonitorUnavailable "
                    + "latency=\(ContinuousClock.now - captureStartedAt)"
            )
            return nil
        }

        let opaqueLookup = bestEffortOpaquePasteDestination(in: frontmostApp)
        guard let focusedWindow = opaqueLookup.focusedWindow,
              inputActivityMonitor.isUnchanged(since: stopInputToken)
        else {
            DebugFileLogger.log(
                "end target capture rejected reason=\(lookup.rejectionReason) "
                    + "opaque=\(opaqueLookup.rejectionReason) "
                    + "latency=\(ContinuousClock.now - captureStartedAt)"
            )
            return nil
        }

        let continuityGuard = FocusContinuityGuard(
            app: frontmostApp,
            requiresAXContinuity: false
        )
        guard inputActivityMonitor.isUnchanged(since: stopInputToken) else {
            continuityGuard.stop()
            DebugFileLogger.log(
                "end target capture rejected reason=inputChangedBeforeOpaqueGuard "
                    + "latency=\(ContinuousClock.now - captureStartedAt)"
            )
            return nil
        }
        let stopTailArmed = inputActivityMonitor.allowCurrentStopGestureTail(
            since: stopInputToken
        )
        DebugFileLogger.log(
            "end target capture bestEffortOpaque pid=\(frontmostApp.processIdentifier) "
                + "role=\(opaqueLookup.sourceRole ?? "unknown") "
                + "pasteEnabled=\(opaqueLookup.pasteCommandEnabled.map(String.init) ?? "nil") "
                + "stopTailArmed=\(stopTailArmed) "
                + "latency=\(ContinuousClock.now - captureStartedAt)"
        )
        return EndInjectionTarget(
            evidence: .bestEffortOpaqueWindow(
                focusedWindow: focusedWindow,
                inputToken: stopInputToken
            ),
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

    /// Revalidate immediately before paste. Exact targets must retain the same
    /// AX element. Best-effort opaque targets must retain the same app, window,
    /// Paste command presence, and global input epoch.
    private static func isStillValid(_ target: EndInjectionTarget) -> Bool {
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

        case .bestEffortOpaqueWindow(
            let targetWindow,
            let inputToken
        ):
            if let reason = inputActivityMonitor.validationFailureReason(since: inputToken) {
                DebugFileLogger.log(
                    "end target revalidate rejected reason=opaqueInputChanged(\(reason))"
                )
                return false
            }
            let opaqueLookup = bestEffortOpaquePasteDestination(in: frontmostApp)
            guard let currentWindow = opaqueLookup.focusedWindow,
                  CFEqual(currentWindow, targetWindow)
            else {
                DebugFileLogger.log(
                    "end target revalidate rejected reason=opaqueWindowOrEvidenceChanged(\(opaqueLookup.rejectionReason))"
                )
                return false
            }
            return inputActivityMonitor.isUnchanged(since: inputToken)
                && target.continuityGuard.invalidationReason == nil
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

    /// Identify a private editor only as a best-effort destination. The
    /// focused window is not treated as proof of an editable control: command
    /// state is preserved as weak evidence, and injection keeps the new text in
    /// the clipboard regardless of whether Cmd+V is consumed.
    private static func bestEffortOpaquePasteDestination(
        in frontmostApp: NSRunningApplication
    ) -> OpaquePasteDestinationLookup {
        guard let window = focusedWindow(in: frontmostApp) else {
            return OpaquePasteDestinationLookup(
                focusedWindow: nil,
                sourceRole: nil,
                pasteCommandEnabled: nil,
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
        let pasteCommandEnabled = standardPasteCommandState(in: frontmostApp)
        let editorScan = scanForAccessibleEditableDescendant(in: window)
        let hasAccessibleEditor = editorScan == .found
        let editorScanComplete = editorScan != .indeterminate

        guard shouldUseBestEffortOpaqueDestination(
            role: role,
            subrole: subrole,
            pasteCommandPresent: pasteCommandEnabled != nil,
            hasAccessibleEditableDescendant: hasAccessibleEditor,
            editableDescendantScanComplete: editorScanComplete,
            focusedElementMatchesWindow: matchesWindow,
            elementPIDMatchesFrontmost: pidMatches
        ) else {
            return OpaquePasteDestinationLookup(
                focusedWindow: nil,
                sourceRole: role,
                pasteCommandEnabled: pasteCommandEnabled,
                rejectionReason: "notEligible(role=\(role ?? "nil"),"
                    + "pasteCommandPresent=\(pasteCommandEnabled != nil),"
                    + "pasteEnabled=\(pasteCommandEnabled.map(String.init) ?? "nil"),"
                    + "editor=\(hasAccessibleEditor),"
                    + "editorScanComplete=\(editorScanComplete),"
                    + "windowMatch=\(matchesWindow),pidMatch=\(pidMatches))"
            )
        }

        return OpaquePasteDestinationLookup(
            focusedWindow: window,
            sourceRole: role,
            pasteCommandEnabled: pasteCommandEnabled,
            rejectionReason: "none"
        )
    }

    static func shouldUseBestEffortOpaqueDestination(
        role: String?,
        subrole: String?,
        pasteCommandPresent: Bool,
        hasAccessibleEditableDescendant: Bool,
        editableDescendantScanComplete: Bool = true,
        focusedElementMatchesWindow: Bool,
        elementPIDMatchesFrontmost: Bool
    ) -> Bool {
        guard elementPIDMatchesFrontmost,
              focusedElementMatchesWindow,
              pasteCommandPresent,
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
    /// means it reports the command disabled, and `true` means enabled. Some
    /// private editors accept Cmd+V while permanently reporting `false`, so the
    /// state is weak evidence only and never upgrades an opaque window to an
    /// exact target.
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
        requiring endTarget: EndInjectionTarget?
    ) -> TrackedInjectionResult {
        defer { endTarget?.stopObserving() }
        let isBestEffortOpaque = endTarget?.isBestEffortOpaque == true
        // An opaque editor cannot prove whether Cmd+V was consumed. Its result
        // must therefore remain recoverable even when normal injections restore
        // the user's original clipboard.
        let shouldRestoreClipboard = Self.shouldRestoreClipboard(
            retention: clipboardRetention,
            isBestEffortOpaque: isBestEffortOpaque
        )
        let savedClipboard = shouldRestoreClipboard ? ClipboardSnapshot.capture() : nil

        // If Type4Me is frontmost, yield focus so the target application receives paste
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Bundle.main.bundleIdentifier {
            DispatchQueue.main.sync {
                NSApp.hide(nil)
            }
            usleep(50_000)
        }

        // Opaque targets cannot provide a meaningful field snapshot. Exact and
        // ordinary paths keep the existing outcome/correction observation flow.
        let before = isBestEffortOpaque ? nil : captureFocusedElementSnapshot()

        copyToClipboard(text, transient: shouldRestoreClipboard)
        let postWriteChangeCount = NSPasteboard.general.changeCount
        usleep(50_000)

        // Keep the strong end-target check inside the paste critical path. If
        // focus changed during processing or clipboard preparation, retain the
        // result for manual paste regardless of the normal clipboard policy.
        if let endTarget, !Self.isStillValid(endTarget) {
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

        let after = isBestEffortOpaque ? nil : captureFocusedElementSnapshot()
        let outcome: InjectionOutcome
        if isBestEffortOpaque {
            // This reports exactly what is known: Cmd+V was attempted and the
            // result remains in the clipboard. Never claim `.inserted` here.
            outcome = .pasteAttemptedClipboardRetained
        } else {
            let detectedOutcome = Self.inferInjectionOutcome(
                before: before,
                after: after,
                pastedText: text
            )
            outcome = Self.finalizeOutcome(
                detectedOutcome,
                retention: clipboardRetention
            )
        }

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
    /// Selecting the recording-end target is an explicit opt-in whose setting
    /// detail discloses that opaque attempts always retain a recoverable result.
    static func shouldRestoreClipboard(
        retention: ClipboardRetention,
        isBestEffortOpaque: Bool
    ) -> Bool {
        retention == .restoreOriginal && !isBestEffortOpaque
    }

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
        Self.markAsSyntheticInput(keyDown)
        Self.markAsSyntheticInput(keyUp)

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

    /// Standard macOS Accessibility roles representing static UI elements or
    /// controls that do not accept text input when focused.
    static let knownNonEditableRoles: Set<String> = [
        "AXApplication",
        "AXWindow",
        "AXSheet",
        "AXDialog",
        "AXAlert",
        "AXDrawer",
        "AXPopover",
        "AXGroup",
        "AXSplitGroup",
        "AXScrollArea",
        "AXButton",
        "AXPopUpButton",
        "AXMenuButton",
        "AXMenu",
        "AXMenuItem",
        "AXMenuBar",
        "AXMenuBarItem",
        "AXCheckBox",
        "AXRadioButton",
        "AXRadioGroup",
        "AXTabGroup",
        "AXSlider",
        "AXColorWell",
        "AXImage",
        "AXStaticText",
        "AXProgressIndicator",
        "AXScrollBar",
        "AXToolbar",
        "AXTable",
        "AXOutline",
        "AXRow",
        "AXColumn",
        "AXCell",
        "AXList",
        "AXHeading",
        "AXLink",
        "AXDisclosureTriangle",
        "AXIncrementor",
        "AXLevelIndicator",
        "AXPage",
        "AXRuler",
        "AXRulerMarker",
        "AXSplitter",
        "AXValueIndicator",
    ]
    static func isKnownNonEditableRole(_ role: String?) -> Bool {
        guard let role else { return false }
        return knownNonEditableRoles.contains(role)
    }

    static func inferInjectionOutcome(
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

        // Standard non-editable controls (buttons, images, static labels, etc.)
        // where pasting has nowhere to go.
        if isKnownNonEditableRole(before.role) || isKnownNonEditableRole(after.role) {
            return .copiedToClipboard
        }

        // Opaque, terminal, or custom rendering surfaces (e.g. AXUnknown, nil,
        // or custom canvas) that possess focus in an active application: assume Cmd+V worked.
        return .inserted
    }


}
