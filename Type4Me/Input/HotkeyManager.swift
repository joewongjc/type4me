import Cocoa
import MediaPlayer

typealias HotkeyStyle = ProcessingMode.HotkeyStyle

enum GlobalHotkeyAction: String, Codable, Sendable {
    case revise
}

enum HotkeyOwner: Hashable, Sendable {
    case mode(UUID)
    case globalAction(GlobalHotkeyAction)
}

struct ModeBinding: Sendable {
    let bindingId: UUID
    let owner: HotkeyOwner
    var modeId: UUID {
        if case .mode(let id) = owner { return id }
        return UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
    }
    let keyCode: CGKeyCode
    let modifiers: CGEventFlags  // .maskCommand etc. Use [] for no modifiers
    let style: HotkeyStyle
    let onStart: @Sendable () -> Void
    let onStop: @Sendable () -> Void
    let onAbort: @Sendable () -> Void
    var onBusyConflict: (@Sendable () -> Void)? = nil

    init(
        bindingId: UUID,
        owner: HotkeyOwner,
        keyCode: CGKeyCode,
        modifiers: CGEventFlags,
        style: HotkeyStyle,
        onStart: @escaping @Sendable () -> Void,
        onStop: @escaping @Sendable () -> Void,
        onAbort: (@Sendable () -> Void)? = nil,
        onBusyConflict: (@Sendable () -> Void)? = nil
    ) {
        self.bindingId = bindingId
        self.owner = owner
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.style = style
        self.onStart = onStart
        self.onStop = onStop
        self.onAbort = onAbort ?? { @Sendable in }
        self.onBusyConflict = onBusyConflict
    }

    init(
        bindingId: UUID,
        modeId: UUID,
        keyCode: CGKeyCode,
        modifiers: CGEventFlags,
        style: HotkeyStyle,
        onStart: @escaping @Sendable () -> Void,
        onStop: @escaping @Sendable () -> Void,
        onAbort: (@Sendable () -> Void)? = nil,
        onBusyConflict: (@Sendable () -> Void)? = nil
    ) {
        self.init(
            bindingId: bindingId,
            owner: .mode(modeId),
            keyCode: keyCode,
            modifiers: modifiers,
            style: style,
            onStart: onStart,
            onStop: onStop,
            onAbort: onAbort,
            onBusyConflict: onBusyConflict
        )
    }

    /// Whether this binding is for a mouse button (encoded with high-bit keyCode).
    var isMouseButton: Bool { ModeBinding.isMouseKeyCode(Int(keyCode)) }

    /// Whether this binding is for a media key (encoded with high-bit keyCode).
    var isMediaKey: Bool { ModeBinding.isMediaKeyCode(Int(keyCode)) }

    /// The mouse button number (2=middle, 3+=side buttons). Only valid when isMouseButton is true.
    var mouseButtonNumber: Int { ModeBinding.mouseButtonNumber(from: Int(keyCode)) }

    // MARK: - Mouse Button Encoding
    //
    // Convention: keyCode = 0x8000 + buttonNumber.
    // Middle button (2) → 0x8002, Side button 3 → 0x8003, etc.
    // Keyboard keyCodes are 0–127, so no collision.
    // The encoded value fits in both Int and UInt16 (CGKeyCode).

    private static let mouseKeyCodeBase = 0x8000
    private static let mediaKeyCodeBase = 0x9000
    static let modifierKeyCodes: Set<Int> = [54, 55, 56, 58, 59, 60, 61, 62, 63]
    static let functionKeyCodes: Set<Int> = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90]
    static let standardModifierMask: CGEventFlags = [
        .maskCommand,
        .maskShift,
        .maskAlternate,
        .maskControl,
        .maskSecondaryFn,
    ]

    /// Encode a mouse button number as a keyCode (for storage in a HotkeyBinding).
    static func mouseKeyCode(for buttonNumber: Int) -> Int { mouseKeyCodeBase + buttonNumber }

    /// Decode a mouse keyCode back to a button number.
    static func mouseButtonNumber(from keyCode: Int) -> Int { keyCode - mouseKeyCodeBase }

    /// Check if a keyCode represents a mouse button.
    static func isMouseKeyCode(_ keyCode: Int) -> Bool { keyCode >= mouseKeyCodeBase && keyCode < mediaKeyCodeBase }

    // MARK: - Media Key Encoding
    //
    // Convention: keyCode = 0x9000 + NX_KEYTYPE value.
    // NX_KEYTYPE_SOUND_UP=0, NX_KEYTYPE_SOUND_DOWN=1, NX_KEYTYPE_MUTE=7,
    // NX_KEYTYPE_PLAY=16, NX_KEYTYPE_NEXT=17, NX_KEYTYPE_PREVIOUS=18,
    // NX_KEYTYPE_FAST=19, NX_KEYTYPE_REWIND=20.
    // No collision with keyboard (0–127) or mouse (0x8000+) keyCodes.

    /// Encode an NX_KEYTYPE value as a keyCode (for storage in a HotkeyBinding).
    static func mediaKeyCode(for keyType: Int) -> Int { mediaKeyCodeBase + keyType }

    /// Decode a media keyCode back to the NX_KEYTYPE value.
    static func mediaKeyType(from keyCode: Int) -> Int { keyCode - mediaKeyCodeBase }

    /// Check if a keyCode represents a media key.
    static func isMediaKeyCode(_ keyCode: Int) -> Bool { keyCode >= mediaKeyCodeBase }

    // MARK: - Device-Specific Modifier Masks
    //
    // macOS IOKit / NSEvent device-dependent modifier flags in CGEvent.flags.rawValue
    static let deviceLeftControlMask: UInt64   = 0x00000001
    static let deviceLeftShiftMask: UInt64     = 0x00000002
    static let deviceRightShiftMask: UInt64    = 0x00000004
    static let deviceLeftCommandMask: UInt64   = 0x00000008
    static let deviceRightCommandMask: UInt64  = 0x00000010
    static let deviceLeftOptionMask: UInt64    = 0x00000020
    static let deviceRightOptionMask: UInt64   = 0x00000040
    static let deviceRightControlMask: UInt64  = 0x00002000
    static let allDeviceModifierMasks: UInt64  = 0x0000207F

    static func deviceModifierMask(for keyCode: Int) -> UInt64? {
        switch keyCode {
        case 54: return deviceRightCommandMask
        case 55: return deviceLeftCommandMask
        case 56: return deviceLeftShiftMask
        case 60: return deviceRightShiftMask
        case 58: return deviceLeftOptionMask
        case 61: return deviceRightOptionMask
        case 59: return deviceLeftControlMask
        case 62: return deviceRightControlMask
        default: return nil
        }
    }

    static func isModifierPressed(keyCode: Int, flags: CGEventFlags) -> Bool {
        let raw = flags.rawValue
        switch keyCode {
        case 54:
            if raw & deviceRightCommandMask != 0 { return true }
            if raw & deviceLeftCommandMask != 0 { return false }
            return flags.contains(.maskCommand)
        case 55:
            if raw & deviceLeftCommandMask != 0 { return true }
            if raw & deviceRightCommandMask != 0 { return false }
            return flags.contains(.maskCommand)
        case 56:
            if raw & deviceLeftShiftMask != 0 { return true }
            if raw & deviceRightShiftMask != 0 { return false }
            return flags.contains(.maskShift)
        case 60:
            if raw & deviceRightShiftMask != 0 { return true }
            if raw & deviceLeftShiftMask != 0 { return false }
            return flags.contains(.maskShift)
        case 58:
            if raw & deviceLeftOptionMask != 0 { return true }
            if raw & deviceRightOptionMask != 0 { return false }
            return flags.contains(.maskAlternate)
        case 61:
            if raw & deviceRightOptionMask != 0 { return true }
            if raw & deviceLeftOptionMask != 0 { return false }
            return flags.contains(.maskAlternate)
        case 59:
            if raw & deviceLeftControlMask != 0 { return true }
            if raw & deviceRightControlMask != 0 { return false }
            return flags.contains(.maskControl)
        case 62:
            if raw & deviceRightControlMask != 0 { return true }
            if raw & deviceLeftControlMask != 0 { return false }
            return flags.contains(.maskControl)
        case 63:
            return flags.contains(.maskSecondaryFn)
        default:
            return false
        }
    }

    static func modifierKeyCodes(forRawFlags rawFlags: UInt64, standardFlags: CGEventFlags) -> Set<Int> {
        var keys = Set<Int>()
        if rawFlags & deviceLeftCommandMask != 0 { keys.insert(55) }
        if rawFlags & deviceRightCommandMask != 0 { keys.insert(54) }
        if rawFlags & deviceLeftShiftMask != 0 { keys.insert(56) }
        if rawFlags & deviceRightShiftMask != 0 { keys.insert(60) }
        if rawFlags & deviceLeftOptionMask != 0 { keys.insert(58) }
        if rawFlags & deviceRightOptionMask != 0 { keys.insert(61) }
        if rawFlags & deviceLeftControlMask != 0 { keys.insert(59) }
        if rawFlags & deviceRightControlMask != 0 { keys.insert(62) }
        if standardFlags.contains(.maskSecondaryFn) { keys.insert(63) }
        return keys
    }

    static func isModifierKeyCode(_ keyCode: Int) -> Bool {
        modifierKeyCodes.contains(keyCode)
    }

    static func isFunctionKeyCode(_ keyCode: Int) -> Bool {
        functionKeyCodes.contains(keyCode)
    }

    static func modifierEventFlag(for keyCode: Int) -> CGEventFlags? {
        switch keyCode {
        case 54, 55: return .maskCommand
        case 56, 60: return .maskShift
        case 58, 61: return .maskAlternate
        case 59, 62: return .maskControl
        case 63: return .maskSecondaryFn
        default: return nil
        }
    }

    static func normalizedModifierFlags(_ flags: CGEventFlags, forKeyCode keyCode: Int? = nil) -> CGEventFlags {
        var normalized = flags.intersection(standardModifierMask)
        // macOS reports the Fn/function modifier on F-key events themselves.
        // Treat that as part of the F-key, not as an extra hotkey modifier.
        if let keyCode, isFunctionKeyCode(keyCode) {
            normalized.remove(.maskSecondaryFn)
        }
        return normalized
    }

    static func hotkeysAreEquivalent(
        keyCode: Int,
        modifiers: UInt64?,
        otherKeyCode: Int,
        otherModifiers: UInt64?
    ) -> Bool {
        guard keyCode == otherKeyCode else { return false }
        if isMouseKeyCode(keyCode) || isMediaKeyCode(keyCode) {
            return true
        }
        let flags = normalizedModifierFlags(CGEventFlags(rawValue: modifiers ?? 0), forKeyCode: keyCode)
        let otherFlags = normalizedModifierFlags(CGEventFlags(rawValue: otherModifiers ?? 0), forKeyCode: otherKeyCode)
        return flags == otherFlags
    }

    static func fullModifierFlags(keyCode: Int, modifiers: UInt64?) -> CGEventFlags? {
        guard let ownFlag = modifierEventFlag(for: keyCode) else { return nil }
        var flags = normalizedModifierFlags(CGEventFlags(rawValue: modifiers ?? 0))
        flags.insert(ownFlag)
        return flags
    }

    static func modifierBindingIsPrefix(
        modifierKeyCode: Int,
        modifierModifiers: UInt64?,
        otherKeyCode: Int,
        otherModifiers: UInt64?
    ) -> Bool {
        guard let flags = fullModifierFlags(keyCode: modifierKeyCode, modifiers: modifierModifiers) else {
            return false
        }

        if let otherFlags = fullModifierFlags(keyCode: otherKeyCode, modifiers: otherModifiers) {
            return flags != otherFlags && flags.isSubset(of: otherFlags)
        }

        guard let regularFlags = regularKeyModifierFlags(keyCode: otherKeyCode, modifiers: otherModifiers) else {
            return false
        }
        return flags.isSubset(of: regularFlags)
    }

    static func hasModifierPrefixConflict(
        keyCode: Int,
        modifiers: UInt64?,
        otherKeyCode: Int,
        otherModifiers: UInt64?
    ) -> Bool {
        modifierBindingIsPrefix(
            modifierKeyCode: keyCode,
            modifierModifiers: modifiers,
            otherKeyCode: otherKeyCode,
            otherModifiers: otherModifiers
        ) || modifierBindingIsPrefix(
            modifierKeyCode: otherKeyCode,
            modifierModifiers: otherModifiers,
            otherKeyCode: keyCode,
            otherModifiers: modifiers
        )
    }

    private static func regularKeyModifierFlags(keyCode: Int, modifiers: UInt64?) -> CGEventFlags? {
        guard !isMouseKeyCode(keyCode),
              !isMediaKeyCode(keyCode),
              !isModifierKeyCode(keyCode)
        else { return nil }
        let flags = normalizedModifierFlags(CGEventFlags(rawValue: modifiers ?? 0), forKeyCode: keyCode)
        return flags.isEmpty ? nil : flags
    }
}

extension CGEventFlags {
    func isSubset(of other: CGEventFlags) -> Bool {
        self.intersection(other) == self
    }

    func isStrictSubset(of other: CGEventFlags) -> Bool {
        self != other && self.isSubset(of: other)
    }
}

final class HotkeyManager: NSObject {

    // MARK: - Configuration

    /// Session-level tap ensures global shortcuts work reliably without intercepting
    /// hardware IOHID streams, preventing kernel-level input freezes upon runtime permission changes.
    internal static let tapLocationPriority: [CGEventTapLocation] = [
        .cgSessionEventTap,
    ]

    private var bindings: [ModeBinding] = []
    /// Per-binding state, all keyed by `HotkeyBinding.id` so multiple bindings of the
    /// same mode never collide.
    private var holdState: [UUID: Bool] = [:]
    private var wasModifierDown: [UUID: Bool] = [:]
    private var holdSafetyTimers: [UUID: Timer] = [:]
    /// The single binding currently driving a recording (hold or toggle), if any.
    /// Only one recording can be active at a time across all modes/bindings.
    private var activeRecordingBindingId: UUID?
    /// The mode owning the active recording binding. Used to distinguish same-mode
    /// (stop) from cross-mode (switch) presses.
    private var activeRecordingModeId: UUID?
    private var activeRecordingOwner: HotkeyOwner?
    var onBusyConflict: (() -> Void)?

    private enum ModifierGestureState: Equatable {
        case idle
        case tracking
        case candidate(bindingId: UUID, expected: CGEventFlags, token: UUID?)
        case activeHold(bindingId: UUID, expected: CGEventFlags)
        case settling
        case disqualified
    }

    private var gestureState: ModifierGestureState = .idle
    private var candidateToken: UUID?
    private var candidateTimer: Timer?

    /// Normalized modifier flags observed on the previous flagsChanged event, used to
    /// distinguish building a combo up (a real press) from releasing a larger combo
    /// down through a smaller one (a transient we must not treat as a press).
    private var previousModifierFlags: CGEventFlags = []
    /// Track currently-held physical modifier key codes (e.g. 54 for Right Cmd vs 55 for Left Cmd).
    private var heldModifierKeyCodes: Set<Int> = []

    /// Maximum hold duration before auto-stop (seconds).
    private let maxHoldDuration: TimeInterval = 120

    /// Default delay before a *prefix* modifier combo fires (e.g. `fn` when `fn+Shift`
    /// also exists), giving the user time to complete the longer combo.
    static let defaultModifierPrefixTriggerDelay: TimeInterval = 0.25
    /// UserDefaults key to override `defaultModifierPrefixTriggerDelay` at runtime.
    /// No settings UI yet — adjust via `defaults write` if needed.
    static let modifierPrefixTriggerDelayKey = "tf_modifierPrefixTriggerDelay"
    /// Effective prefix-combo trigger delay (seconds). Reads the UserDefaults override
    /// when a positive value is present, otherwise the default.
    private var modifierPrefixTriggerDelay: TimeInterval {
        let stored = UserDefaults.standard.double(forKey: Self.modifierPrefixTriggerDelayKey)
        return stored > 0 ? stored : Self.defaultModifierPrefixTriggerDelay
    }

    // MARK: - State

    /// When true, all hotkey events pass through unhandled (used during hotkey recording).
    var isSuppressed = false

    /// When true, ESC key aborts active recording.
    var isESCAbortEnabled = true

    /// When true, LLM post-processing is in progress (ESC can also abort this).
    var isProcessing = false

    /// Reset all active recording/hold state. Called when session ends (completed/error/finalized)
    /// to ensure hotkeys and ESC don't remain stuck.
    func resetActiveState() {
        clearActiveRecordingState()
        for key in wasModifierDown.keys { wasModifierDown[key] = false }
        for key in holdState.keys { holdState[key] = false }
        holdSafetyTimers.values.forEach { $0.invalidate() }
        holdSafetyTimers = [:]
        cancelCandidateTimer()
        gestureState = .idle
        previousModifierFlags = []
        heldModifierKeyCodes.removeAll()
    }

    /// Called when recording is finished by a different mode's hotkey.
    /// The application decides whether the ending mode should replace the starting mode.
    var onCrossModeFinish: ((UUID) -> Void)?

    /// Called when ESC is pressed during active recording or processing (abort).
    /// Returns true if the abort was handled (ESC should be swallowed),
    /// false if the app is not actually in an active session (ESC should pass through).
    var onESCAbort: (() -> Bool)?

    internal enum EventTapRecoveryAction: Equatable {
        case reenable
        case revoke
        case passThrough
    }

    private enum EventTapLifecycleState: Equatable {
        case stopped
        case starting
        case running
        case stopping
        case revoked
    }

    private var eventTapLifecycleState: EventTapLifecycleState = .stopped
    private var eventTapRunLoop: CFRunLoop?
    private var hasEmittedAccessibilityRevoked = false
    var onAccessibilityRevoked: (() -> Void)?

    internal var eventTapLifecycleStateDescription: String {
        switch eventTapLifecycleState {
        case .stopped: return "stopped"
        case .starting: return "starting"
        case .running: return "running"
        case .stopping: return "stopping"
        case .revoked: return "revoked"
        }
    }

    internal static func recoveryAction(
        for type: CGEventType,
        isAccessibilityTrusted: Bool
    ) -> EventTapRecoveryAction {
        if !isAccessibilityTrusted {
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                return .revoke
            }
        } else {
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                return .reenable
            }
        }
        return .passThrough
    }
    internal func simulateRevocationForTesting() {
        if eventTapLifecycleState != .running && eventTapLifecycleState != .revoked {
            eventTapLifecycleState = .running
        }
        tearDownEventTap(finalState: .revoked)
    }

    internal func resetRevocationGenerationForTesting() {
        hasEmittedAccessibilityRevoked = false
        eventTapLifecycleState = .running
    }

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var healthCheckTimer: Timer?
    /// Timestamp of the last event received by the tap callback.
    fileprivate var lastEventTime: Date?
    /// Set only while dispatching a binding callback from the current event.
    /// Modifier-only releases consult this so the stop event itself is swallowed.
    private var didDispatchBindingCallback = false

    /// Tokens for MPRemoteCommandCenter handlers (prevents Apple Music from auto-launching).
    private var mediaCommandTokens: [(command: MPRemoteCommand, token: Any)] = []
    private var isMediaSessionActive = false
    // MARK: - Registration

    func registerBindings(_ newBindings: [ModeBinding]) {
        bindings = newBindings
        holdState = [:]
        wasModifierDown = [:]
        clearActiveRecordingState()
        holdSafetyTimers.values.forEach { $0.invalidate() }
        holdSafetyTimers = [:]
        cancelCandidateTimer()
        gestureState = .idle
        previousModifierFlags = []
        heldModifierKeyCodes.removeAll()
        updateMediaKeySession()
    }

    // MARK: - Start / Stop

    @discardableResult
    func start() -> Bool {
        if eventTapLifecycleState == .running,
           let tap = eventTap,
           CFMachPortIsValid(tap),
           CGEvent.tapIsEnabled(tap: tap) {
            return true
        }

        guard PermissionManager.hasAccessibilityPermission else {
            tearDownEventTap(finalState: .revoked)
            return false
        }

        tearDownEventTap(finalState: .stopped)
        eventTapLifecycleState = .starting

        let hasMediaKeyBindings = bindings.contains { $0.isMediaKey }

        let eventMask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.leftMouseUp.rawValue)
            | (1 << CGEventType.rightMouseDown.rawValue)
            | (1 << CGEventType.rightMouseUp.rawValue)
            | (1 << CGEventType.otherMouseDown.rawValue)
            | (1 << CGEventType.otherMouseUp.rawValue)
            | (1 << CGEventType.leftMouseDragged.rawValue)
            | (1 << CGEventType.rightMouseDragged.rawValue)
            | (1 << CGEventType.otherMouseDragged.rawValue)
            | (1 << CGEventType.scrollWheel.rawValue)
            | (hasMediaKeyBindings ? (1 << 14) : 0)  // kCGEventSystemDefined (NX_SYSDEFINED) for media/headphone keys
        let userInfo = Unmanaged.passUnretained(self).toOpaque()

        var tap: CFMachPort?
        var selectedTapLocation: CGEventTapLocation?
        for location in Self.tapLocationPriority where tap == nil {
            tap = CGEvent.tapCreate(
                tap: location,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: eventMask,
                callback: hotkeyCallback,
                userInfo: userInfo
            )
            if tap != nil {
                selectedTapLocation = location
            }
        }

        guard let tap = tap else {
            tearDownEventTap(finalState: .stopped)
            return false
        }

        let locationName = selectedTapLocation == .cghidEventTap ? "hid" : "session"
        DebugFileLogger.log(
            "hotkey event tap installed location=\(locationName) mediaBindings=\(hasMediaKeyBindings)"
        )

        eventTap = tap
        lastEventTime = nil

        let currentRunLoop = CFRunLoopGetCurrent()
        eventTapRunLoop = currentRunLoop
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(currentRunLoop, source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        guard CGEvent.tapIsEnabled(tap: tap) else {
            tearDownEventTap(finalState: .stopped)
            return false
        }

        eventTapLifecycleState = .running
        hasEmittedAccessibilityRevoked = false
        TextInjectionEngine.globalInputMonitorDidStart(eventTap: tap)

        startHealthCheck()
        updateMediaKeySession()
        return true
    }

    func stop() {
        tearDownEventTap(finalState: .stopped)
    }

    private func tearDownEventTap(finalState: EventTapLifecycleState) {
        let previousState = eventTapLifecycleState
        eventTapLifecycleState = .stopping

        healthCheckTimer?.invalidate()
        healthCheckTimer = nil

        deactivateMediaKeySession()
        TextInjectionEngine.globalInputMonitorDidStop()

        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            let runLoop = eventTapRunLoop ?? CFRunLoopGetCurrent()
            CFRunLoopRemoveSource(runLoop, source, .commonModes)
            CFRunLoopSourceInvalidate(source)
        }
        if let tap = eventTap {
            CFMachPortInvalidate(tap)
        }

        eventTap = nil
        runLoopSource = nil
        eventTapRunLoop = nil
        lastEventTime = nil

        holdState = [:]
        wasModifierDown = [:]
        clearActiveRecordingState()
        holdSafetyTimers.values.forEach { $0.invalidate() }
        holdSafetyTimers = [:]
        cancelCandidateTimer()
        gestureState = .idle
        previousModifierFlags = []
        heldModifierKeyCodes.removeAll()

        eventTapLifecycleState = finalState

        if finalState == .revoked {
            if previousState == .running && !hasEmittedAccessibilityRevoked {
                hasEmittedAccessibilityRevoked = true
                DispatchQueue.main.async { [weak self] in
                    self?.onAccessibilityRevoked?()
                }
            }
        }
    }

    // MARK: - Health check

    /// Periodically verify the event tap is actually alive and permission has not been lost.
    private func startHealthCheck() {
        healthCheckTimer?.invalidate()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            guard self.eventTapLifecycleState == .running else { return }

            guard PermissionManager.hasAccessibilityPermission else {
                DebugFileLogger.log("hotkey watchdog detected accessibility permission loss")
                self.tearDownEventTap(finalState: .revoked)
                return
            }

            guard let tap = self.eventTap else { return }

            // Check 1: Is the tap port still valid? Only recreate the tap for real invalidation,
            // not for normal idle periods with no keyboard/mouse input.
            if !CFMachPortIsValid(tap) {
                NSLog("[Type4Me] Health check: tap port invalid, reinstalling tap...")
                self.reinstallTap()
                return
            }

            // Check 2: Is the tap still enabled at the Mach port level?
            if !CGEvent.tapIsEnabled(tap: tap) {
                NSLog("[Type4Me] Health check: tap disabled, re-enabling...")
                TextInjectionEngine.globalInputMonitorDidStop()
                CGEvent.tapEnable(tap: tap, enable: true)
                if CGEvent.tapIsEnabled(tap: tap) {
                    TextInjectionEngine.globalInputMonitorDidStart(eventTap: tap)
                } else {
                    NSLog("[Type4Me] Health check: tap re-enable failed, reinstalling tap...")
                    self.reinstallTap()
                }
            }
        }
        RunLoop.current.add(timer, forMode: .common)
        healthCheckTimer = timer
    }
    /// Tear down and recreate the event tap from scratch.
    private func reinstallTap() {
        guard PermissionManager.hasAccessibilityPermission else {
            tearDownEventTap(finalState: .revoked)
            return
        }
        stop()
        let ok = start()
        NSLog("[Type4Me] Tap reinstall: %@", ok ? "OK" : "FAILED")
    }

    // MARK: - Event handling

    fileprivate func handleEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        lastEventTime = Date()
        didDispatchBindingCallback = false

        // Immediate fail-open guard: if Accessibility permission was revoked at runtime,
        // tear down the active tap immediately and pass the event untouched to the system.
        guard PermissionManager.hasAccessibilityPermission else {
            TextInjectionEngine.globalInputMonitorDidStop()
            DebugFileLogger.log("hotkey event tap untrusted during event handling, tearing down immediately")
            tearDownEventTap(finalState: .revoked)
            return Unmanaged.passUnretained(event)
        }
        let recovery = Self.recoveryAction(
            for: type,
            isAccessibilityTrusted: PermissionManager.hasAccessibilityPermission
        )
        switch recovery {
        case .revoke:
            TextInjectionEngine.globalInputMonitorDidStop()
            DebugFileLogger.log("hotkey event tap revoked on disabled event type=\(type.rawValue)")
            tearDownEventTap(finalState: .revoked)
            return Unmanaged.passUnretained(event)
        case .reenable:
            TextInjectionEngine.globalInputMonitorDidStop()
            DebugFileLogger.log(
                "hotkey event tap disabled type=\(type.rawValue) recording=\(activeRecordingBindingId != nil)"
            )
            // Any input released while the tap was disabled is unknowable.
            // Keep the monitor unavailable while a stuck hold is recovered so
            // that recovery-triggered stops cannot capture an opaque target.
            recoverStuckHolds()
            if let tap = eventTap, CFMachPortIsValid(tap) {
                CGEvent.tapEnable(tap: tap, enable: true)
                if CGEvent.tapIsEnabled(tap: tap) {
                    TextInjectionEngine.globalInputMonitorDidStart(eventTap: tap)
                } else {
                    reinstallTap()
                }
            } else {
                reinstallTap()
            }
            return Unmanaged.passUnretained(event)
        case .passThrough:
            break
        }

        // Record the event before a matching stop hotkey invokes its callback.
        // Capture may arm only this event's release-only tail; every unrelated
        // later keyboard or pointer event invalidates an opaque target.
        TextInjectionEngine.beginGlobalInputEvent(type: type, event: event)
        defer { TextInjectionEngine.endGlobalInputEvent(type: type) }

        // Type4Me's own Cmd+C / Delete / Cmd+V events must reach the target
        // application but must never trigger a user-configured Type4Me hotkey.
        if TextInjectionEngine.isSyntheticInput(event) {
            return Unmanaged.passUnretained(event)
        }

        // Pass all events through when suppressed (hotkey recording in progress)
        if isSuppressed {
            return Unmanaged.passUnretained(event)
        }

        // Left/right presses are observed only for opaque-target continuity;
        // they are never hotkeys here and must pass through untouched.
        if type == .leftMouseDown || type == .leftMouseUp
            || type == .rightMouseDown || type == .rightMouseUp {
            return Unmanaged.passUnretained(event)
        }

        // Dragging and scrolling can move selection or dismiss a private
        // editor without changing its AX window. They invalidate opaque
        // targets above and otherwise pass through untouched.
        if type == .leftMouseDragged || type == .rightMouseDragged
            || type == .otherMouseDragged || type == .scrollWheel {
            return Unmanaged.passUnretained(event)
        }

        // MARK: Mouse button events (otherMouseDown/Up = middle + side buttons)
        if type == .otherMouseDown || type == .otherMouseUp {
            let buttonNumber = Int(event.getIntegerValueField(.mouseEventButtonNumber))

            for binding in bindings {
                guard binding.isMouseButton, binding.mouseButtonNumber == buttonNumber else { continue }

                switch binding.style {
                case .hold:
                    if type == .otherMouseDown {
                        handleBindingEvent(binding: binding, pressed: true)
                    } else {
                        handleBindingEvent(binding: binding, pressed: false)
                    }
                case .toggle:
                    if type == .otherMouseDown {
                        handleTogglePress(binding: binding)
                    }
                }
                return nil  // Swallow matched mouse button events
            }

            return Unmanaged.passUnretained(event)
        }

        // MARK: Media key events (headphone buttons, keyboard media keys)
        if type.rawValue == 14 {  // kCGEventSystemDefined (NX_SYSDEFINED)
            guard let nsEvent = NSEvent(cgEvent: event),
                  nsEvent.type == .systemDefined,
                  nsEvent.subtype.rawValue == 8 else {
                return Unmanaged.passUnretained(event)
            }

            let keyType = Int((nsEvent.data1 >> 16) & 0xFFFF)
            let keyState = Int((nsEvent.data1 >> 8) & 0xFF)
            let isKeyDown = keyState == 0x0A
            let isKeyUp = keyState == 0x0B

            guard Self.isKnownMediaKeyType(keyType) else {
                return Unmanaged.passUnretained(event)
            }

            let encodedKeyCode = ModeBinding.mediaKeyCode(for: keyType)

            for binding in bindings {
                guard binding.isMediaKey, Int(binding.keyCode) == encodedKeyCode else { continue }

                switch binding.style {
                case .hold:
                    if isKeyDown {
                        handleBindingEvent(binding: binding, pressed: true)
                    } else if isKeyUp {
                        handleBindingEvent(binding: binding, pressed: false)
                    }
                case .toggle:
                    if isKeyDown {
                        handleTogglePress(binding: binding)
                    }
                }
                return nil  // Swallow matched media key events
            }

            return Unmanaged.passUnretained(event)
        }

        // MARK: Keyboard events
        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        if type == .keyDown {
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            if !isModifierKeyCode(keyCode) {
                reduceRegularKeyDownBeforeDispatch(keyCode: keyCode, isRepeat: isRepeat)
            }
        }

        // Modifier-only combos (fn, Ctrl+Shift, fn+Shift, …) are matched by their full
        // set of held flags, independent of the physical order the keys were pressed.
        // Handle them all in one place on every flagsChanged event. When the current
        // flags exactly match a registered combo, swallow the event so the modifier
        // doesn't also trigger its own system behavior.
        if type == .flagsChanged {
            if activeRecordingBindingId != nil {
                DebugFileLogger.log(
                    "hotkey flagsChanged keyCode=\(keyCode) rawFlags=\(normalizedModifierFlags(event.flags).rawValue) previousFlags=\(previousModifierFlags.rawValue)"
                )
            }
            let matchedCombo = evaluateModifierBindings(
                currentFlags: event.flags,
                rawFlags: event.flags.rawValue,
                keyCode: keyCode
            )
            return (matchedCombo || didDispatchBindingCallback)
                ? nil
                : Unmanaged.passUnretained(event)
        }

        for binding in bindings {
            // Skip mouse button and media key bindings in the keyboard path
            guard !binding.isMouseButton && !binding.isMediaKey else { continue }
            // Modifier-only bindings are handled by evaluateModifierBindings above.
            guard !isModifierKeyCode(binding.keyCode) else { continue }
            guard binding.keyCode == keyCode else { continue }

            // Regular keys: check modifier flags match
            let requiredMods = normalizedModifierFlags(binding.modifiers, forKeyCode: Int(binding.keyCode))
            let currentMods = normalizedModifierFlags(event.flags, forKeyCode: Int(keyCode))
            guard currentMods == requiredMods else { continue }

            switch binding.style {
            case .hold:
                if type == .keyDown {
                    let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat)
                    if isRepeat != 0 { return nil }
                    handleBindingEvent(binding: binding, pressed: true)
                } else if type == .keyUp {
                    handleBindingEvent(binding: binding, pressed: false)
                }
            case .toggle:
                if type == .keyDown {
                    let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat)
                    if isRepeat != 0 { return nil }
                    handleTogglePress(binding: binding)
                }
            }
            return nil  // Swallow matched regular key events
        }

        // ESC key (keyCode 53) - abort active recording or processing
        if isESCAbortEnabled && type == .keyDown && keyCode == 53 {
            let hotkeyOwnedSession = activeRecordingBindingId != nil || holdState.values.contains(true)
            // A recording session may also be driven outside the hotkey system
            // (e.g. a `type4me://` URL Scheme command), in which case none of this
            // manager's hotkey bookkeeping is set. `onESCAbort` validates the real
            // session phase via appState and returns false when idle, so consult it
            // on every ESC — not only when this manager owns the recording —
            // otherwise URL-initiated recordings can never be cancelled with ESC.
            if onESCAbort?() == true {
                return nil  // Swallow ESC: abort was handled
            }
            if hotkeyOwnedSession || isProcessing {
                // We believed a session was active but the callback declined —
                // stale state. Clean up and let ESC pass through to the system.
                NSLog("[HotkeyManager] ESC abort not handled, resetting stale state")
                isProcessing = false
                resetActiveState()
            }
        }

        return Unmanaged.passUnretained(event)
    }

    // MARK: - Binding dispatch

    /// Unified per-binding event handler.
    /// - Hold bindings: press/release drive start/stop.
    /// - Toggle bindings: only the pressed edge is actionable; modifier toggles arrive as
    ///   level-triggered `flagsChanged`, so they're edge-gated via `wasModifierDown`.
    private func handleBindingEvent(binding: ModeBinding, pressed: Bool) {
        switch binding.style {
        case .hold:
            if pressed {
                handleHoldPress(binding: binding)
            } else {
                handleHoldRelease(binding: binding)
            }

        case .toggle:
            let bindingId = binding.bindingId
            if pressed {
                let wasDown = wasModifierDown[bindingId] ?? false
                guard !wasDown else { return }
                wasModifierDown[bindingId] = true
                handleTogglePress(binding: binding)
            } else {
                wasModifierDown[bindingId] = false
            }
        }
    }

    /// A toggle binding was pressed. Start when idle, stop when the same owner is recording,
    /// or hand off to cross-mode switching when a different mode is recording.
    private func handleTogglePress(binding: ModeBinding) {
        if isProcessing {
            binding.onBusyConflict?() ?? onBusyConflict?()
            return
        }
        if activeRecordingBindingId != nil {
            if activeRecordingOwner == binding.owner {
                // Same owner (same binding = toggle off, or a sibling binding): stop.
                stopActiveRecording()
            } else if case .mode = activeRecordingOwner, case .mode(let targetModeId) = binding.owner {
                // Different mode: finish the current recording through the app's policy.
                clearActiveRecordingState()
                dispatchCrossModeFinish(targetModeId)
            } else if case .globalAction(.revise) = activeRecordingOwner, case .mode = binding.owner {
                // Cross-mode finish for revise: pressing any mode key stops the revise recording.
                stopActiveRecording()
            } else {
                // Cross-task collision (e.g. revise while voice input active): reject!
                binding.onBusyConflict?() ?? onBusyConflict?()
            }
        } else {
            startRecording(with: binding)
        }
    }

    /// A hold binding went down.
    private func handleHoldPress(binding: ModeBinding) {
        if isProcessing {
            binding.onBusyConflict?() ?? onBusyConflict?()
            return
        }
        let bindingId = binding.bindingId
        // Ignore repeated down while already holding this binding.
        guard holdState[bindingId] != true else { return }

        if activeRecordingBindingId != nil {
            if activeRecordingOwner == binding.owner {
                // Same owner recording via another binding: this press just stops it.
                // Do not begin a hold recording, so the eventual release is a no-op.
                stopActiveRecording()
            } else if case .mode = activeRecordingOwner, case .mode(let targetModeId) = binding.owner {
                // Different mode: finish the current recording through the app's policy.
                clearActiveRecordingState()
                dispatchCrossModeFinish(targetModeId)
            } else if case .globalAction(.revise) = activeRecordingOwner, case .mode = binding.owner {
                // Cross-mode finish for revise: pressing any mode key stops the revise recording.
                stopActiveRecording()
            } else {
                // Cross-task collision: reject!
                binding.onBusyConflict?() ?? onBusyConflict?()
            }
            return
        }

        // Idle: begin hold recording.
        holdState[bindingId] = true
        startSafetyTimer(for: binding)
        startRecording(with: binding)
    }

    /// A hold binding was released.
    private func handleHoldRelease(binding: ModeBinding) {
        let bindingId = binding.bindingId
        guard holdState[bindingId] == true else { return }
        guard activeRecordingBindingId == bindingId else {
            // Held binding was interrupted/stopped earlier by another event.
            // Consume the release and cancel its timer without firing onStop.
            holdState[bindingId] = false
            cancelSafetyTimer(for: bindingId)
            return
        }
        holdState[bindingId] = false
        cancelSafetyTimer(for: bindingId)
        stopActiveRecording()
    }

    // MARK: - Active recording lifecycle

    private func startRecording(with binding: ModeBinding) {
        activeRecordingBindingId = binding.bindingId
        activeRecordingModeId = binding.modeId
        activeRecordingOwner = binding.owner
        // AppDelegate may detect that its session is already recording and
        // reinterpret this nominal start callback as a stop. Route it through
        // the same authorization gate so that desync recovery can still capture
        // the actual hotkey event, without opening non-hotkey capture paths.
        dispatchBindingCallback(binding.onStart)
    }

    /// Stop the active recording, invoking its binding's `onStop`.
    private func stopActiveRecording() {
        let active = activeRecordingBinding()
        clearActiveRecordingState()
        if let active {
            dispatchBindingCallback(active.onStop)
        }
    }

    private func dispatchCrossModeFinish(_ targetModeId: UUID) {
        guard let onCrossModeFinish else { return }
        dispatchBindingCallback { onCrossModeFinish(targetModeId) }
    }

    private func dispatchBindingCallback(_ callback: () -> Void) {
        didDispatchBindingCallback = true
        TextInjectionEngine.authorizeCurrentGlobalInputForStopCapture()
        callback()
    }

    /// Clear all active-recording bookkeeping. This is the single point where an in-flight
    /// recording is torn down, regardless of the trigger (same-mode second binding,
    /// cross-mode toggle/hold, ESC, safety timer, reset, …). Before dropping the active
    /// binding id we clear its hold-side state (`holdState` + safety timer), so a hold
    /// binding that is interrupted mid-recording by another binding/mode cannot leave a
    /// dangling 120s safety timer that later fires `handleHoldSafetyTimer` and invokes
    /// `onStop` a second time on an already-stopped session ("ghost stop"). On the timer
    /// self-fire path the hold state is already cleared by `handleHoldSafetyTimer`, so
    /// clearing here is a safe no-op.
    private func clearActiveRecordingState() {
        if let activeId = activeRecordingBindingId {
            holdState[activeId] = false
            cancelSafetyTimer(for: activeId)
        }
        activeRecordingBindingId = nil
        activeRecordingModeId = nil
        activeRecordingOwner = nil
    }

    private func activeRecordingBinding() -> ModeBinding? {
        guard let id = activeRecordingBindingId else { return nil }
        return bindings.first { $0.bindingId == id }
    }

    // MARK: - Reducer

    internal func reduceRegularKeyDownBeforeDispatch(keyCode: CGKeyCode, isRepeat: Bool) {
        guard !isRepeat else { return }
        guard !isModifierKeyCode(keyCode) else { return }

        cancelCandidateTimer()

        switch gestureState {
        case .idle:
            break
        case .candidate:
            gestureState = .disqualified
        case .activeHold(let bindingId, _):
            gestureState = .disqualified
            if let binding = bindings.first(where: { $0.bindingId == bindingId }) {
                abortActiveHold(binding: binding)
            } else if let active = activeRecordingBinding() {
                abortActiveHold(binding: active)
            } else {
                clearActiveRecordingState()
            }
        case .tracking, .settling:
            gestureState = .disqualified
        case .disqualified:
            break
        }
    }

    private func abortActiveHold(binding: ModeBinding) {
        clearActiveRecordingState()
        binding.onAbort()
    }

    // MARK: - Test SPI (internal)
    //
    // Exposes a thin driver + read-only views of the state machine so unit tests can
    // replay the hold/toggle/cross-mode paths and assert no ghost hold state or timers
    // are left behind. These members are `internal` (not `private`) so the `@testable
    // import Type4Me` test target can reach them; they are not used by production code.

    /// Drive the state machine the same way a real key event would (press or release).
    internal func simulateBindingEvent(_ binding: ModeBinding, pressed: Bool) {
        handleBindingEvent(binding: binding, pressed: pressed)
    }

    /// Drive the modifier-combo evaluator with synthetic flags. This covers the
    /// prefix-delay path used by modifier-only bindings such as fn and fn+Shift.
    @discardableResult
    internal func simulateModifierFlags(
        _ flags: CGEventFlags,
        rawFlags: UInt64? = nil,
        keyCode: CGKeyCode? = nil
    ) -> Bool {
        didDispatchBindingCallback = false
        let matched = evaluateModifierBindings(
            currentFlags: flags,
            rawFlags: rawFlags,
            keyCode: keyCode
        )
        return matched || didDispatchBindingCallback
    }

    /// Drive the regular-key pre-dispatch reducer with a synthetic regular key-down.
    internal func simulateRegularKeyDown(keyCode: CGKeyCode, isRepeat: Bool = false) {
        reduceRegularKeyDownBeforeDispatch(keyCode: keyCode, isRepeat: isRepeat)
    }

    /// Stop the active recording (same path as ESC / safety timer / reset).
    internal func simulateStopActiveRecording() {
        stopActiveRecording()
    }

    /// True when a hold binding's press has been recorded but not yet released/stopped.
    internal func isHoldActive(for bindingId: UUID) -> Bool {
        holdState[bindingId] == true
    }

    /// True when this binding currently owns the active recording.
    internal func isActiveRecordingBinding(_ bindingId: UUID) -> Bool {
        activeRecordingBindingId == bindingId
    }

    /// True if a safety timer is still pending for this binding (would fire later).
    internal func hasPendingSafetyTimer(for bindingId: UUID) -> Bool {
        holdSafetyTimers[bindingId] != nil
    }

    /// True if a candidate classification timer is currently scheduled.
    internal func hasPendingCandidateTimer() -> Bool {
        candidateTimer != nil
    }

    /// Read-only snapshot of current modifier gesture state for tests.
    internal var currentModifierGestureStateDescription: String {
        switch gestureState {
        case .idle: return "idle"
        case .tracking: return "tracking"
        case .candidate(let id, _, let token): return "candidate(\(id), token: \(String(describing: token)))"
        case .activeHold(let id, _): return "activeHold(\(id))"
        case .settling: return "settling"
        case .disqualified: return "disqualified"
        }
    }

    // MARK: - Modifier Combo Evaluation

    /// Order-independent evaluation of modifier-only combos (e.g. `fn`, `Ctrl+Shift`,
    /// `fn+Shift`). A combo is active when the full set of currently-held modifier flags
    /// exactly equals the combo's flags, regardless of the order the keys were pressed.
    /// At most one combo matches at a time.
    /// - Returns: `true` when the current flags exactly match a registered combo, so the
    ///   caller can swallow the event and suppress the modifier's own system behavior.
    @discardableResult
    private func evaluateModifierBindings(
        currentFlags: CGEventFlags,
        rawFlags: UInt64? = nil,
        keyCode: CGKeyCode? = nil
    ) -> Bool {
        let current = normalizedModifierFlags(currentFlags)
        let previous = previousModifierFlags
        previousModifierFlags = current

        updateHeldModifierKeyCodes(currentFlags: current, rawFlags: rawFlags, keyCode: keyCode)

        let matched = bindings.first { b in
            guard isModifierKeyCode(b.keyCode), !b.isMouseButton, !b.isMediaKey,
                  let expected = ModeBinding.fullModifierFlags(
                      keyCode: Int(b.keyCode), modifiers: b.modifiers.rawValue)
            else { return false }
            guard expected == current else { return false }
            return heldModifierKeyCodes.contains(Int(b.keyCode))
        }
        let shouldSwallow = matched != nil

        if current.isEmpty {
            cancelCandidateTimer()

            switch gestureState {
            case .idle:
                return false
            case .tracking, .settling, .disqualified:
                gestureState = .idle
                return false
            case .candidate(let candidateId, let expected, _):
                gestureState = .idle
                if previous == expected {
                    if let candidateBinding = bindings.first(where: { $0.bindingId == candidateId }),
                       candidateBinding.style == .toggle {
                        handleTogglePress(binding: candidateBinding)
                    }
                }
                return false
            case .activeHold(let bindingId, let expected):
                gestureState = .idle
                if previous == expected {
                    if let activeBinding = bindings.first(where: { $0.bindingId == bindingId }) {
                        handleHoldRelease(binding: activeBinding)
                    } else {
                        stopActiveRecording()
                    }
                } else {
                    stopActiveRecording()
                }
                return false
            }
        }

        if gestureState == .disqualified {
            return false
        }

        if gestureState == .settling {
            return false
        }

        let isBuilding = !previous.isEmpty && current != previous && !current.isStrictSubset(of: previous)

        switch gestureState {
        case .idle:
            if let matched,
               let expected = ModeBinding.fullModifierFlags(keyCode: Int(matched.keyCode), modifiers: matched.modifiers.rawValue) {
                armCandidate(binding: matched, expected: expected)
                return true
            } else {
                gestureState = .tracking
                return false
            }

        case .tracking:
            if isBuilding,
               let matched,
               let expected = ModeBinding.fullModifierFlags(keyCode: Int(matched.keyCode), modifiers: matched.modifiers.rawValue) {
                armCandidate(binding: matched, expected: expected)
                return true
            }
            return false

        case .candidate(let candidateId, let expected, _):
            let candidateBinding = bindings.first(where: { $0.bindingId == candidateId })

            // Clean-release predicate:
            // previous == expected && current != expected && current.isStrictSubset(of: expected)
            if previous == expected && current != expected && current.isStrictSubset(of: expected) {
                cancelCandidateTimer()
                gestureState = current.isEmpty ? .idle : .settling

                if let candidateBinding, candidateBinding.style == .toggle {
                    handleTogglePress(binding: candidateBinding)
                }
                return false
            }

            if isBuilding {
                if let matched,
                   let newExpected = ModeBinding.fullModifierFlags(keyCode: Int(matched.keyCode), modifiers: matched.modifiers.rawValue),
                   expected.isStrictSubset(of: newExpected) {
                    cancelCandidateTimer()
                    armCandidate(binding: matched, expected: newExpected)
                    return true
                } else if expected.isStrictSubset(of: current) {
                    cancelCandidateTimer()
                    gestureState = .tracking
                    return false
                }
            }

            if current.isStrictSubset(of: previous) {
                cancelCandidateTimer()
                gestureState = current.isEmpty ? .idle : .settling
                return false
            }

            return shouldSwallow

        case .activeHold(let bindingId, let expected):
            let activeBinding = bindings.first(where: { $0.bindingId == bindingId })

            // Clean-release predicate:
            if previous == expected && current != expected && current.isStrictSubset(of: expected) {
                gestureState = current.isEmpty ? .idle : .settling
                if let activeBinding {
                    handleHoldRelease(binding: activeBinding)
                } else {
                    stopActiveRecording()
                }
                return false
            }

            if isBuilding {
                if let activeBinding {
                    handleHoldRelease(binding: activeBinding)
                } else {
                    stopActiveRecording()
                }

                if let matched,
                   let newExpected = ModeBinding.fullModifierFlags(keyCode: Int(matched.keyCode), modifiers: matched.modifiers.rawValue) {
                    armCandidate(binding: matched, expected: newExpected)
                    return true
                } else {
                    gestureState = .tracking
                    return false
                }
            }

            if current.isStrictSubset(of: previous) {
                if let activeBinding {
                    handleHoldRelease(binding: activeBinding)
                } else {
                    stopActiveRecording()
                }
                gestureState = current.isEmpty ? .idle : .settling
                return false
            }

            return shouldSwallow

        case .settling, .disqualified:
            return false
        }
    }

    private func armCandidate(binding: ModeBinding, expected: CGEventFlags) {
        cancelCandidateTimer()
        if binding.style == .hold {
            let token = UUID()
            gestureState = .candidate(bindingId: binding.bindingId, expected: expected, token: token)
            candidateToken = token
            let delay = modifierPrefixTriggerDelay
            candidateTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
                self?.fireCandidateTimer(bindingId: binding.bindingId, token: token)
            }
        } else {
            gestureState = .candidate(bindingId: binding.bindingId, expected: expected, token: nil)
        }
    }

    private func fireCandidateTimer(bindingId: UUID, token: UUID) {
        guard case .candidate(let currentBindingId, let expected, let currentToken) = gestureState,
              currentBindingId == bindingId,
              currentToken == token,
              let binding = bindings.first(where: { $0.bindingId == bindingId }),
              binding.style == .hold
        else { return }

        guard previousModifierFlags == expected else { return }
        guard heldModifierKeyCodes.contains(Int(binding.keyCode)) else { return }

        cancelCandidateTimer()
        gestureState = .activeHold(bindingId: bindingId, expected: expected)
        holdState[bindingId] = true
        startSafetyTimer(for: binding)
        startRecording(with: binding)
    }

    private func cancelCandidateTimer() {
        candidateToken = nil
        candidateTimer?.invalidate()
        candidateTimer = nil
    }

    private func updateHeldModifierKeyCodes(
        currentFlags: CGEventFlags,
        rawFlags: UInt64?,
        keyCode: CGKeyCode?
    ) {
        if let rawFlags, rawFlags & ModeBinding.allDeviceModifierMasks != 0 {
            heldModifierKeyCodes = ModeBinding.modifierKeyCodes(forRawFlags: rawFlags, standardFlags: currentFlags)
            return
        }

        if currentFlags.isEmpty {
            heldModifierKeyCodes.removeAll()
            return
        }

        if let keyCode, isModifierKeyCode(keyCode) {
            let kc = Int(keyCode)
            if ModeBinding.isModifierPressed(keyCode: kc, flags: currentFlags) {
                heldModifierKeyCodes.insert(kc)
                if currentFlags.contains(.maskSecondaryFn) {
                    heldModifierKeyCodes.insert(63)
                }
            } else {
                heldModifierKeyCodes.remove(kc)
                if let ownFlag = ModeBinding.modifierEventFlag(for: kc), !currentFlags.contains(ownFlag) {
                    switch ownFlag {
                    case .maskCommand: heldModifierKeyCodes.subtract([54, 55])
                    case .maskShift: heldModifierKeyCodes.subtract([56, 60])
                    case .maskAlternate: heldModifierKeyCodes.subtract([58, 61])
                    case .maskControl: heldModifierKeyCodes.subtract([59, 62])
                    case .maskSecondaryFn: heldModifierKeyCodes.remove(63)
                    default: break
                    }
                }
            }
            return
        }

        if currentFlags.contains(.maskSecondaryFn) {
            heldModifierKeyCodes.insert(63)
        } else {
            heldModifierKeyCodes.remove(63)
        }
        for binding in bindings where isModifierKeyCode(binding.keyCode) {
            if let expected = ModeBinding.fullModifierFlags(
                keyCode: Int(binding.keyCode), modifiers: binding.modifiers.rawValue),
               expected == currentFlags {
                heldModifierKeyCodes.insert(Int(binding.keyCode))
            }
        }
    }

    // MARK: - Safety Timer

    private func startSafetyTimer(for binding: ModeBinding) {
        cancelSafetyTimer(for: binding.bindingId)
        let id = binding.bindingId
        holdSafetyTimers[id] = Timer.scheduledTimer(
            timeInterval: maxHoldDuration,
            target: self,
            selector: #selector(handleHoldSafetyTimer(_:)),
            userInfo: id,
            repeats: false
        )
    }

    private func cancelSafetyTimer(for id: UUID) {
        holdSafetyTimers[id]?.invalidate()
        holdSafetyTimers[id] = nil
    }

    @objc
    private func handleHoldSafetyTimer(_ timer: Timer) {
        guard let id = timer.userInfo as? UUID else { return }
        guard holdState[id] == true else { return }
        guard let binding = bindings.first(where: { $0.bindingId == id }) else { return }

        NSLog("[HotkeyManager] Safety timer fired for binding %@, auto-stopping", id.uuidString)
        holdState[id] = false
        if activeRecordingBindingId == id {
            stopActiveRecording()
        } else {
            dispatchBindingCallback(binding.onStop)
        }
    }

    // MARK: - Stuck Hold Recovery

    /// After a tap re-enable, check if any held keys were released while the tap was disabled.
    private func recoverStuckHolds() {
        let currentFlags = CGEventSource.flagsState(.combinedSessionState)

        for binding in bindings where binding.style == .hold {
            let id = binding.bindingId
            guard holdState[id] == true else { continue }

            // Mouse buttons and media keys: no API to query current state, rely on release events instead.
            // Safety timer will catch truly stuck holds.
            if binding.isMouseButton || binding.isMediaKey { continue }

            let stillDown: Bool
            if isModifierKeyCode(binding.keyCode) {
                stillDown = isModifierPressed(keyCode: binding.keyCode, flags: currentFlags)
            } else {
                stillDown = CGEventSource.keyState(.combinedSessionState, key: binding.keyCode)
            }

            if !stillDown {
                NSLog("[HotkeyManager] Recovering stuck hold for binding %@", id.uuidString)
                let wasDisqualified = gestureState == .disqualified
                holdState[id] = false
                cancelSafetyTimer(for: id)
                if wasDisqualified {
                    if activeRecordingBindingId == id {
                        clearActiveRecordingState()
                    }
                    binding.onAbort()
                } else {
                    if activeRecordingBindingId == id {
                        stopActiveRecording()
                    } else {
                        dispatchBindingCallback(binding.onStop)
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private static func isKnownMediaKeyType(_ keyType: Int) -> Bool {
        // NX_KEYTYPE values from IOKit/hidsystem/IOHIDParameter.h
        // SOUND_UP=0, SOUND_DOWN=1, MUTE=7, PLAY=16, NEXT=17, PREVIOUS=18, FAST=19, REWIND=20
        [0, 1, 7, 16, 17, 18, 19, 20].contains(keyType)
    }

    private func isModifierKeyCode(_ keyCode: CGKeyCode) -> Bool {
        ModeBinding.isModifierKeyCode(Int(keyCode))
    }

    private func normalizedModifierFlags(_ flags: CGEventFlags, forKeyCode keyCode: Int? = nil) -> CGEventFlags {
        ModeBinding.normalizedModifierFlags(flags, forKeyCode: keyCode)
    }

    private func modifierEventFlag(for keyCode: CGKeyCode) -> CGEventFlags? {
        ModeBinding.modifierEventFlag(for: Int(keyCode))
    }

    private func isModifierPressed(keyCode: CGKeyCode, flags: CGEventFlags) -> Bool {
        ModeBinding.isModifierPressed(keyCode: Int(keyCode), flags: flags)
    }

    // MARK: - Media Session (prevent Apple Music auto-launch)

    /// Register as an active media session when transport media keys (play/next/prev)
    /// are bound as hotkeys, so the system doesn't launch Apple Music on key press.
    private func updateMediaKeySession() {
        for (command, token) in mediaCommandTokens {
            command.removeTarget(token)
        }
        mediaCommandTokens = []

        // Find which transport key types are bound (volume keys don't launch Apple Music)
        let boundKeyTypes = Set(bindings.filter(\.isMediaKey).map { ModeBinding.mediaKeyType(from: Int($0.keyCode)) })
        let transportKeyTypes: Set<Int> = [16, 17, 18, 19, 20]
        let boundTransportKeys = boundKeyTypes.intersection(transportKeyTypes)

        if boundTransportKeys.isEmpty {
            if isMediaSessionActive {
                MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
                MPNowPlayingInfoCenter.default().playbackState = .stopped
                isMediaSessionActive = false
                NSLog("[HotkeyManager] Deactivated media session (no transport keys bound)")
            }
            return
        }

        let commandCenter = MPRemoteCommandCenter.shared()

        if !isMediaSessionActive {
            // Must set non-empty NowPlaying info with playbackState=.playing —
            // mediaremoted on macOS 15 ignores apps with empty nowPlayingInfo.
            let nowPlayingInfo: [String: Any] = [
                MPMediaItemPropertyTitle: "Type4Me Voice Input",
                MPNowPlayingInfoPropertyPlaybackRate: 1.0,
                MPNowPlayingInfoPropertyElapsedPlaybackTime: 0.0,
            ]
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
            MPNowPlayingInfoCenter.default().playbackState = .playing
            isMediaSessionActive = true
            NSLog("[HotkeyManager] Activated media session (transport keys bound)")
        }

        let handler: (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus = { event in
            NSLog("[HotkeyManager] Media remote command received: %@", String(describing: type(of: event)))
            return .success
        }

        if boundTransportKeys.contains(16) {
            commandCenter.playCommand.isEnabled = true
            commandCenter.pauseCommand.isEnabled = true
            commandCenter.togglePlayPauseCommand.isEnabled = true

            let playToken = commandCenter.playCommand.addTarget(handler: handler)
            let pauseToken = commandCenter.pauseCommand.addTarget(handler: handler)
            let toggleToken = commandCenter.togglePlayPauseCommand.addTarget(handler: handler)
            mediaCommandTokens.append(contentsOf: [
                (command: commandCenter.playCommand, token: playToken),
                (command: commandCenter.pauseCommand, token: pauseToken),
                (command: commandCenter.togglePlayPauseCommand, token: toggleToken),
            ])
        }
        if boundTransportKeys.contains(17) {
            commandCenter.nextTrackCommand.isEnabled = true
            let token = commandCenter.nextTrackCommand.addTarget(handler: handler)
            mediaCommandTokens.append((command: commandCenter.nextTrackCommand, token: token))
        }
        if boundTransportKeys.contains(18) {
            commandCenter.previousTrackCommand.isEnabled = true
            let token = commandCenter.previousTrackCommand.addTarget(handler: handler)
            mediaCommandTokens.append((command: commandCenter.previousTrackCommand, token: token))
        }
        if boundTransportKeys.contains(19) {
            commandCenter.seekForwardCommand.isEnabled = true
            let token = commandCenter.seekForwardCommand.addTarget(handler: handler)
            mediaCommandTokens.append((command: commandCenter.seekForwardCommand, token: token))
        }
        if boundTransportKeys.contains(20) {
            commandCenter.seekBackwardCommand.isEnabled = true
            let token = commandCenter.seekBackwardCommand.addTarget(handler: handler)
            mediaCommandTokens.append((command: commandCenter.seekBackwardCommand, token: token))
        }
    }

    private func deactivateMediaKeySession() {
        for (command, token) in mediaCommandTokens {
            command.isEnabled = false
            command.removeTarget(token)
        }
        mediaCommandTokens = []
        if isMediaSessionActive {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            MPNowPlayingInfoCenter.default().playbackState = .stopped
            isMediaSessionActive = false
            NSLog("[HotkeyManager] Deactivated media session (stop)")
        }
    }
}

// MARK: - C callback

private func hotkeyCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let manager = Unmanaged<HotkeyManager>.fromOpaque(userInfo).takeUnretainedValue()
    return manager.handleEvent(type: type, event: event)
}
