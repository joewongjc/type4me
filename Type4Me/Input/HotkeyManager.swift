import Cocoa

typealias HotkeyStyle = ProcessingMode.HotkeyStyle

struct ModeBinding {
    let modeId: UUID
    let keyCode: CGKeyCode
    let modifiers: CGEventFlags  // .maskCommand etc. Use [] for no modifiers
    let style: HotkeyStyle
    let onStart: @Sendable () -> Void
    let onStop: @Sendable () -> Void

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

    /// Encode a mouse button number as a keyCode (for storage in ProcessingMode.hotkeyCode).
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

    /// Encode an NX_KEYTYPE value as a keyCode (for storage in ProcessingMode.hotkeyCode).
    static func mediaKeyCode(for keyType: Int) -> Int { mediaKeyCodeBase + keyType }

    /// Decode a media keyCode back to the NX_KEYTYPE value.
    static func mediaKeyType(from keyCode: Int) -> Int { keyCode - mediaKeyCodeBase }

    /// Check if a keyCode represents a media key.
    static func isMediaKeyCode(_ keyCode: Int) -> Bool { keyCode >= mediaKeyCodeBase }
}

final class HotkeyManager: NSObject {

    // MARK: - Configuration

    private var bindings: [ModeBinding] = []
    private var holdState: [UUID: Bool] = [:]
    private var toggleState: [UUID: Bool] = [:]
    private var wasModifierDown: [UUID: Bool] = [:]
    private var holdSafetyTimers: [UUID: Timer] = [:]
    /// Which toggle mode is currently active (recording). Only one can be active at a time.
    private var activeToggleModeId: UUID?

    /// Maximum hold duration before auto-stop (seconds).
    private let maxHoldDuration: TimeInterval = 120

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
        activeToggleModeId = nil
        for key in toggleState.keys { toggleState[key] = false }
        for key in holdState.keys { holdState[key] = false }
    }

    /// Called when recording is stopped by a different mode's hotkey.
    /// The UUID is the new mode's ID that should be used for processing.
    var onCrossModeStop: ((UUID) -> Void)?

    /// Called when ESC is pressed during active recording or processing (abort).
    /// Called when ESC is pressed during active recording or processing (abort).
    /// Returns true if the abort was handled (ESC should be swallowed),
    /// false if the app is not actually in an active session (ESC should pass through).
    var onESCAbort: (() -> Bool)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var healthCheckTimer: Timer?
    /// Timestamp of the last event received by the tap callback.
    fileprivate var lastEventTime: Date?

    // MARK: - Registration

    func registerBindings(_ newBindings: [ModeBinding]) {
        bindings = newBindings
        holdState = [:]
        toggleState = [:]
        wasModifierDown = [:]
        holdSafetyTimers.values.forEach { $0.invalidate() }
        holdSafetyTimers = [:]
    }

    // MARK: - Start / Stop

    @discardableResult
    func start() -> Bool {
        let eventMask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.otherMouseDown.rawValue)
            | (1 << CGEventType.otherMouseUp.rawValue)
            | (1 << 14)  // kCGEventSystemDefined (NX_SYSDEFINED) for media/headphone keys

        let userInfo = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: hotkeyCallback,
            userInfo: userInfo
        ) else {
            return false
        }

        eventTap = tap
        lastEventTime = nil

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        startHealthCheck()
        return true
    }

    func stop() {
        healthCheckTimer?.invalidate()
        healthCheckTimer = nil
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        lastEventTime = nil
        holdState = [:]
        toggleState = [:]
        wasModifierDown = [:]
        holdSafetyTimers.values.forEach { $0.invalidate() }
        holdSafetyTimers = [:]
    }

    // MARK: - Health check

    /// Periodically verify the event tap is actually alive.
    /// Detects the "silent disable" race where tapCreate succeeds but the tap is dead.
    private func startHealthCheck() {
        healthCheckTimer?.invalidate()
        healthCheckTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            guard let self, let tap = self.eventTap else { return }

            // Check 1: Is the tap still enabled at the Mach port level?
            if !CGEvent.tapIsEnabled(tap: tap) {
                NSLog("[Type4Me] Health check: tap disabled, re-enabling...")
                CGEvent.tapEnable(tap: tap, enable: true)
            }

            // Check 2: If we haven't received ANY event in 30s, the tap may be silently dead.
            // (User is almost certainly pressing keys within 30s of normal use.)
            // Only flag this if the tap has been alive for at least 30s (give it time to warm up).
            if let lastEvent = self.lastEventTime,
               Date().timeIntervalSince(lastEvent) > 30 {
                NSLog("[Type4Me] Health check: no events for 30s, reinstalling tap...")
                self.reinstallTap()
            }
        }
    }

    /// Tear down and recreate the event tap from scratch.
    private func reinstallTap() {
        stop()
        let ok = start()
        NSLog("[Type4Me] Tap reinstall: %@", ok ? "OK" : "FAILED")
    }

    // MARK: - Event handling

    fileprivate func handleEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        lastEventTime = Date()

        // Re-enable tap if system disabled it, and recover any stuck hold states.
        // When macOS disables the tap (main thread blocked >1s), keyUp events are lost.
        // We must check if held keys are still physically down; if not, fire onStop.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            recoverStuckHolds()
            return Unmanaged.passUnretained(event)
        }

        // Pass all events through when suppressed (hotkey recording in progress)
        if isSuppressed {
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
                        let id = binding.modeId
                        if let activeId = activeToggleModeId, activeId != id {
                            toggleState[activeId] = false
                            activeToggleModeId = nil
                            onCrossModeStop?(id)
                        } else {
                            let isOn = toggleState[id] ?? false
                            toggleState[id] = !isOn
                            if !isOn {
                                activeToggleModeId = id
                                binding.onStart()
                            } else {
                                activeToggleModeId = nil
                                binding.onStop()
                            }
                        }
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
                        let id = binding.modeId
                        if let activeId = activeToggleModeId, activeId != id {
                            toggleState[activeId] = false
                            activeToggleModeId = nil
                            onCrossModeStop?(id)
                        } else {
                            let isOn = toggleState[id] ?? false
                            toggleState[id] = !isOn
                            if !isOn {
                                activeToggleModeId = id
                                binding.onStart()
                            } else {
                                activeToggleModeId = nil
                                binding.onStop()
                            }
                        }
                    }
                }
                return nil  // Swallow matched media key events
            }

            return Unmanaged.passUnretained(event)
        }

        // MARK: Keyboard events
        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))

        for binding in bindings {
            // Skip mouse button and media key bindings in the keyboard path
            guard !binding.isMouseButton && !binding.isMediaKey else { continue }
            guard binding.keyCode == keyCode else { continue }

            if isModifierKeyCode(keyCode) {
                // Modifier keys: handle via flagsChanged only, don't swallow.
                // For combos like Ctrl+Shift, binding.modifiers stores "other modifiers".
                guard type == .flagsChanged else { continue }
                let pressed = isModifierPressed(keyCode: keyCode, flags: event.flags)

                if pressed {
                    let requiredMods = normalizedModifierFlags(binding.modifiers)
                    let currentMods = otherModifierFlags(for: keyCode, flags: event.flags)
                    guard currentMods == requiredMods else { continue }
                    handleBindingEvent(binding: binding, pressed: true)
                    return Unmanaged.passUnretained(event)
                } else if isModifierBindingActive(binding) {
                    // Always release active state even if other modifiers were released first.
                    handleBindingEvent(binding: binding, pressed: false)
                    return Unmanaged.passUnretained(event)
                }
                continue
            } else {
                // Regular keys: check modifier flags match
                let requiredMods = normalizedModifierFlags(binding.modifiers)
                let currentMods = normalizedModifierFlags(event.flags)
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
                        let id = binding.modeId
                        if let activeId = activeToggleModeId, activeId != id {
                            // Cross-mode stop: different mode's key pressed while recording
                            toggleState[activeId] = false
                            activeToggleModeId = nil
                            onCrossModeStop?(id)
                        } else {
                            let isOn = toggleState[id] ?? false
                            toggleState[id] = !isOn
                            if !isOn {
                                activeToggleModeId = id
                                binding.onStart()
                            } else {
                                activeToggleModeId = nil
                                binding.onStop()
                            }
                        }
                    }
                }
                return nil  // Swallow matched regular key events
            }
        }

        // ESC key (keyCode 53) - abort active recording or processing
        if isESCAbortEnabled && type == .keyDown && keyCode == 53 {
            let isRecording = activeToggleModeId != nil || holdState.values.contains(true)
            let shouldAbort = isRecording || isProcessing
            if shouldAbort {
                NSLog("[HotkeyManager] ESC pressed, triggering abort (recording=%@, processing=%@)",
                      isRecording ? "true" : "false", isProcessing ? "true" : "false")
                if onESCAbort?() == true {
                    return nil  // Swallow ESC: abort was handled
                }
                // App is not actually in an active session — stale state.
                // Clean up and let ESC pass through to the system.
                NSLog("[HotkeyManager] ESC abort not handled, resetting stale state")
                isProcessing = false
                resetActiveState()
            }
        }

        return Unmanaged.passUnretained(event)
    }

    // MARK: - Binding dispatch

    private func handleBindingEvent(binding: ModeBinding, pressed: Bool) {
        let id = binding.modeId

        switch binding.style {
        case .hold:
            let wasHolding = holdState[id] ?? false
            if pressed && !wasHolding {
                holdState[id] = true
                startSafetyTimer(for: binding)
                binding.onStart()
            } else if !pressed && wasHolding {
                holdState[id] = false
                cancelSafetyTimer(for: id)
                binding.onStop()
            }

        case .toggle:
            let wasDown = wasModifierDown[id] ?? false
            if pressed && !wasDown {
                wasModifierDown[id] = true
                if let activeId = activeToggleModeId, activeId != id {
                    // Cross-mode stop via modifier key
                    toggleState[activeId] = false
                    activeToggleModeId = nil
                    onCrossModeStop?(id)
                } else {
                    let isOn = toggleState[id] ?? false
                    toggleState[id] = !isOn
                    if !isOn {
                        activeToggleModeId = id
                        binding.onStart()
                    } else {
                        activeToggleModeId = nil
                        binding.onStop()
                    }
                }
            } else if !pressed {
                wasModifierDown[id] = false
            }
        }
    }

    // MARK: - Safety Timer

    private func startSafetyTimer(for binding: ModeBinding) {
        cancelSafetyTimer(for: binding.modeId)
        let id = binding.modeId
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
        guard let binding = bindings.first(where: { $0.modeId == id }) else { return }

        NSLog("[HotkeyManager] Safety timer fired for mode %@, auto-stopping", id.uuidString)
        holdState[id] = false
        binding.onStop()
    }

    // MARK: - Stuck Hold Recovery

    /// After a tap re-enable, check if any held keys were released while the tap was disabled.
    private func recoverStuckHolds() {
        let currentFlags = CGEventSource.flagsState(.combinedSessionState)

        for binding in bindings where binding.style == .hold {
            let id = binding.modeId
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
                NSLog("[HotkeyManager] Recovering stuck hold for mode %@", id.uuidString)
                holdState[id] = false
                cancelSafetyTimer(for: id)
                binding.onStop()
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
        [54, 55, 56, 58, 59, 60, 61, 62, 63].contains(keyCode)
    }

    private func normalizedModifierFlags(_ flags: CGEventFlags) -> CGEventFlags {
        flags.intersection([.maskCommand, .maskShift, .maskAlternate, .maskControl])
    }

    private func modifierEventFlag(for keyCode: CGKeyCode) -> CGEventFlags? {
        switch keyCode {
        case 54, 55: return .maskCommand
        case 56, 60: return .maskShift
        case 58, 61: return .maskAlternate
        case 59, 62: return .maskControl
        case 63: return .maskSecondaryFn
        default: return nil
        }
    }

    private func otherModifierFlags(for keyCode: CGKeyCode, flags: CGEventFlags) -> CGEventFlags {
        var mods = normalizedModifierFlags(flags)
        if let ownFlag = modifierEventFlag(for: keyCode) {
            mods.remove(ownFlag)
        }
        return mods
    }

    private func isModifierBindingActive(_ binding: ModeBinding) -> Bool {
        switch binding.style {
        case .hold:
            return holdState[binding.modeId] ?? false
        case .toggle:
            return wasModifierDown[binding.modeId] ?? false
        }
    }

    private func isModifierPressed(keyCode: CGKeyCode, flags: CGEventFlags) -> Bool {
        switch keyCode {
        case 54, 55: return flags.contains(.maskCommand)
        case 56, 60: return flags.contains(.maskShift)
        case 58, 61: return flags.contains(.maskAlternate)
        case 59, 62: return flags.contains(.maskControl)
        case 63: return flags.contains(.maskSecondaryFn)
        default: return false
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
