import XCTest
@testable import Type4Me

/// Thread-safe counters for capturing ModeBinding onStart/onStop/onAbort invocation counts.
final class BindingCounters: @unchecked Sendable {
    private let lock = NSLock()
    private var _startCount = 0
    private var _stopCount = 0
    private var _abortCount = 0

    func recordStart() {
        lock.lock(); _startCount += 1; lock.unlock()
    }
    func recordStop() {
        lock.lock(); _stopCount += 1; lock.unlock()
    }
    func recordAbort() {
        lock.lock(); _abortCount += 1; lock.unlock()
    }

    var startCount: Int { lock.lock(); defer { lock.unlock() }; return _startCount }
    var stopCount: Int { lock.lock(); defer { lock.unlock() }; return _stopCount }
    var abortCount: Int { lock.lock(); defer { lock.unlock() }; return _abortCount }

    func reset() {
        lock.lock()
        _startCount = 0
        _stopCount = 0
        _abortCount = 0
        lock.unlock()
    }
}

/// State-machine regression tests for multi-hotkey ghost hold prevention and
/// standalone modifier hotkey state machine lifecycle (Issue #243 / MSOR-7).
final class HotkeyStateMachineTests: XCTestCase {

    // MARK: - Fixtures

    private func makeManager() -> HotkeyManager {
        let manager = HotkeyManager()
        manager.registerBindings([]) // initialize dictionaries + media key session
        return manager
    }

    func testKeyboardHotkeysPreferSessionTap() {
        XCTAssertEqual(
            HotkeyManager.tapLocationPriority.map(\.rawValue),
            [
                CGEventTapLocation.cgSessionEventTap.rawValue,
            ]
        )
    }

    private func makeHoldBinding(
        modeId: UUID = UUID(),
        keyCode: CGKeyCode = 42,
        modifiers: CGEventFlags = [],
        counters: BindingCounters
    ) -> ModeBinding {
        ModeBinding(
            bindingId: UUID(),
            modeId: modeId,
            keyCode: keyCode,
            modifiers: modifiers,
            style: .hold,
            onStart: { counters.recordStart() },
            onStop: { counters.recordStop() },
            onAbort: { counters.recordAbort() }
        )
    }

    private func makeToggleBinding(
        modeId: UUID = UUID(),
        keyCode: CGKeyCode = 43,
        modifiers: CGEventFlags = [],
        counters: BindingCounters
    ) -> ModeBinding {
        ModeBinding(
            bindingId: UUID(),
            modeId: modeId,
            keyCode: keyCode,
            modifiers: modifiers,
            style: .toggle,
            onStart: { counters.recordStart() },
            onStop: { counters.recordStop() },
            onAbort: { counters.recordAbort() }
        )
    }

    private func makeFnBinding(
        style: ProcessingMode.HotkeyStyle,
        modeId: UUID = UUID(),
        counters: BindingCounters
    ) -> ModeBinding {
        ModeBinding(
            bindingId: UUID(),
            modeId: modeId,
            keyCode: 63,
            modifiers: [],
            style: style,
            onStart: { counters.recordStart() },
            onStop: { counters.recordStop() },
            onAbort: { counters.recordAbort() }
        )
    }

    private func makeFnShiftBinding(
        modeId: UUID = UUID(),
        counters: BindingCounters
    ) -> ModeBinding {
        ModeBinding(
            bindingId: UUID(),
            modeId: modeId,
            keyCode: 56,
            modifiers: .maskSecondaryFn,
            style: .toggle,
            onStart: { counters.recordStart() },
            onStop: { counters.recordStop() },
            onAbort: { counters.recordAbort() }
        )
    }

    // MARK: - Suite 1: Non-Modifier Stop Paths & Ghost Hold Prevention

    /// Direct stop path: hold press → stopActiveRecording.
    func testStopActiveRecordingClearsHoldStateAndSafetyTimer() {
        let manager = makeManager()
        let counters = BindingCounters()
        let binding = makeHoldBinding(counters: counters)

        manager.registerBindings([binding])
        manager.simulateBindingEvent(binding, pressed: true)

        XCTAssertTrue(manager.isHoldActive(for: binding.bindingId))
        XCTAssertTrue(manager.isActiveRecordingBinding(binding.bindingId))
        XCTAssertTrue(manager.hasPendingSafetyTimer(for: binding.bindingId))
        XCTAssertEqual(counters.startCount, 1)
        XCTAssertEqual(counters.stopCount, 0)

        manager.simulateStopActiveRecording()

        XCTAssertFalse(manager.isHoldActive(for: binding.bindingId))
        XCTAssertFalse(manager.isActiveRecordingBinding(binding.bindingId))
        XCTAssertFalse(manager.hasPendingSafetyTimer(for: binding.bindingId))
        XCTAssertEqual(counters.stopCount, 1, "onStop must be called exactly once")
    }

    /// Path 1: hold recording → same-mode second toggle press.
    func testHoldRecording_sameModeSecondTogglePressStopsWithoutGhostHold() {
        let manager = makeManager()
        let counters = BindingCounters()
        let modeId = UUID()
        let hold = makeHoldBinding(modeId: modeId, keyCode: 42, counters: counters)
        let toggle = makeToggleBinding(modeId: modeId, keyCode: 43, counters: counters)

        manager.registerBindings([hold, toggle])
        manager.simulateBindingEvent(hold, pressed: true)

        XCTAssertEqual(counters.startCount, 1)
        XCTAssertEqual(counters.stopCount, 0)
        XCTAssertTrue(manager.isHoldActive(for: hold.bindingId))
        XCTAssertTrue(manager.hasPendingSafetyTimer(for: hold.bindingId))

        manager.simulateBindingEvent(toggle, pressed: true)

        XCTAssertFalse(manager.isHoldActive(for: hold.bindingId),
                       "same-mode second binding must clear the hold binding's holdState")
        XCTAssertFalse(manager.hasPendingSafetyTimer(for: hold.bindingId),
                       "same-mode second binding must cancel the hold binding's safety timer")
        XCTAssertFalse(manager.isActiveRecordingBinding(hold.bindingId))
        XCTAssertEqual(counters.startCount, 1, "second binding in same mode must not start a new recording")
        XCTAssertEqual(counters.stopCount, 1, "onStop must fire exactly once for the hold recording")
    }

    /// Path 2: hold recording (mode A) → cross-mode toggle press (mode B).
    func testHoldRecording_crossModeToggleFinishesOnceAndClearsState() {
        let manager = makeManager()
        let counters = BindingCounters()
        let modeA = UUID()
        let modeB = UUID()
        let holdA = makeHoldBinding(modeId: modeA, keyCode: 42, counters: counters)
        let toggleB = makeToggleBinding(modeId: modeB, keyCode: 43, counters: counters)

        var crossModeFinishes: [UUID] = []
        manager.onCrossModeFinish = { crossModeFinishes.append($0) }

        manager.registerBindings([holdA, toggleB])
        manager.simulateBindingEvent(holdA, pressed: true)

        XCTAssertTrue(manager.isHoldActive(for: holdA.bindingId))
        XCTAssertTrue(manager.hasPendingSafetyTimer(for: holdA.bindingId))

        manager.simulateBindingEvent(toggleB, pressed: true)

        XCTAssertFalse(manager.isHoldActive(for: holdA.bindingId))
        XCTAssertFalse(manager.hasPendingSafetyTimer(for: holdA.bindingId))
        XCTAssertFalse(manager.isActiveRecordingBinding(holdA.bindingId))
        XCTAssertFalse(manager.isActiveRecordingBinding(toggleB.bindingId))
        XCTAssertEqual(crossModeFinishes, [modeB])
        XCTAssertEqual(counters.stopCount, 0)
    }

    /// Path 3: hold recording (mode A) → cross-mode hold press (mode B).
    func testHoldRecording_crossModeHoldClearsFormerHold() {
        let manager = makeManager()
        let counters = BindingCounters()
        let modeA = UUID()
        let modeB = UUID()
        let holdA = makeHoldBinding(modeId: modeA, keyCode: 42, counters: counters)
        let holdB = makeHoldBinding(modeId: modeB, keyCode: 43, counters: counters)

        var crossModeFinishes: [UUID] = []
        manager.onCrossModeFinish = { crossModeFinishes.append($0) }

        manager.registerBindings([holdA, holdB])
        manager.simulateBindingEvent(holdA, pressed: true)

        XCTAssertTrue(manager.isHoldActive(for: holdA.bindingId))
        XCTAssertTrue(manager.hasPendingSafetyTimer(for: holdA.bindingId))

        manager.simulateBindingEvent(holdB, pressed: true)

        XCTAssertFalse(manager.isHoldActive(for: holdA.bindingId))
        XCTAssertFalse(manager.hasPendingSafetyTimer(for: holdA.bindingId))
        XCTAssertFalse(manager.isHoldActive(for: holdB.bindingId))
        XCTAssertEqual(crossModeFinishes, [modeB])
        XCTAssertEqual(counters.stopCount, 0)
    }

    /// Normal hold release clears state and fires onStop exactly once.
    func testHoldReleaseClearsStateAndStopsOnce() {
        let manager = makeManager()
        let counters = BindingCounters()
        let binding = makeHoldBinding(counters: counters)

        manager.registerBindings([binding])
        manager.simulateBindingEvent(binding, pressed: true)

        XCTAssertTrue(manager.isHoldActive(for: binding.bindingId))
        XCTAssertTrue(manager.hasPendingSafetyTimer(for: binding.bindingId))

        manager.simulateBindingEvent(binding, pressed: false)

        XCTAssertFalse(manager.isHoldActive(for: binding.bindingId))
        XCTAssertFalse(manager.hasPendingSafetyTimer(for: binding.bindingId))
        XCTAssertFalse(manager.isActiveRecordingBinding(binding.bindingId))
        XCTAssertEqual(counters.stopCount, 1, "onStop must be called exactly once on release")
    }

    /// Cross mode stop while in revise recording.
    func testCrossModeStopWhileInReviseRecording() {
        let manager = makeManager()
        let reviseCounters = BindingCounters()
        let modeCounters = BindingCounters()

        let reviseBinding = ModeBinding(
            bindingId: UUID(),
            owner: .globalAction(.revise),
            keyCode: 15,
            modifiers: [.maskSecondaryFn],
            style: .toggle,
            onStart: { reviseCounters.recordStart() },
            onStop: { reviseCounters.recordStop() },
            onAbort: { reviseCounters.recordAbort() }
        )

        let modeBinding = ModeBinding(
            bindingId: UUID(),
            owner: .mode(UUID()),
            keyCode: 42,
            modifiers: [],
            style: .toggle,
            onStart: { modeCounters.recordStart() },
            onStop: { modeCounters.recordStop() },
            onAbort: { modeCounters.recordAbort() }
        )

        manager.registerBindings([reviseBinding, modeBinding])

        // Enter Revise via regular binding press
        manager.simulateBindingEvent(reviseBinding, pressed: true)
        manager.simulateBindingEvent(reviseBinding, pressed: false)
        XCTAssertEqual(reviseCounters.startCount, 1)
        XCTAssertEqual(reviseCounters.stopCount, 0)
        XCTAssertTrue(manager.isActiveRecordingBinding(reviseBinding.bindingId))

        // Press standard mode hotkey -> exits revise recording
        manager.simulateBindingEvent(modeBinding, pressed: true)
        manager.simulateBindingEvent(modeBinding, pressed: false)

        XCTAssertEqual(reviseCounters.stopCount, 1)
        XCTAssertFalse(manager.isActiveRecordingBinding(reviseBinding.bindingId))
    }

    // MARK: - Suite 2: Standalone Modifier Hotkey State Machine (Issue #243 / MSOR-7 Scenarios 1-13)

    /// Scenario 1: Toggle Left Command + 'M' Key Contamination.
    /// Cmd down -> candidate -> 'M' down -> disqualified -> Cmd up -> no callbacks; clean tap afterwards commits.
    func testScenario1_ToggleLeftCommand_MChordDisqualifiesAndDoesNotTriggerOnRelease() {
        let manager = makeManager()
        let counters = BindingCounters()
        let leftCmdBinding = ModeBinding(
            bindingId: UUID(),
            modeId: UUID(),
            keyCode: 55, // Left Command
            modifiers: [],
            style: .toggle,
            onStart: { counters.recordStart() },
            onStop: { counters.recordStop() },
            onAbort: { counters.recordAbort() }
        )
        manager.registerBindings([leftCmdBinding])

        let leftCmdRaw = ModeBinding.deviceLeftCommandMask | CGEventFlags.maskCommand.rawValue

        // 1. Press Left Command down -> candidate armed
        let swallowedCmd = manager.simulateModifierFlags(.maskCommand, rawFlags: leftCmdRaw, keyCode: 55)
        XCTAssertTrue(swallowedCmd)
        XCTAssertEqual(counters.startCount, 0, "Toggle candidate must not start on key down")
        XCTAssertEqual(counters.stopCount, 0)
        XCTAssertEqual(counters.abortCount, 0)

        // 2. Press regular non-modifier key 'M' (keyCode 46) -> disqualifies modifier gesture
        manager.simulateRegularKeyDown(keyCode: 46)
        XCTAssertEqual(counters.startCount, 0)
        XCTAssertEqual(counters.stopCount, 0)
        XCTAssertEqual(counters.abortCount, 0)

        // 3. Release Left Command -> clean release is suppressed due to disqualification
        let swallowedRelease = manager.simulateModifierFlags([], rawFlags: 0, keyCode: 55)
        XCTAssertFalse(swallowedRelease)
        XCTAssertEqual(counters.startCount, 0, "Disqualified toggle must not commit on release")
        XCTAssertEqual(counters.stopCount, 0)
        XCTAssertEqual(counters.abortCount, 0)
        XCTAssertFalse(manager.isActiveRecordingBinding(leftCmdBinding.bindingId))

        // 4. Subsequent clean Left Command tap (Cmd down -> Cmd up) commits normally
        _ = manager.simulateModifierFlags(.maskCommand, rawFlags: leftCmdRaw, keyCode: 55)
        XCTAssertEqual(counters.startCount, 0)
        _ = manager.simulateModifierFlags([], rawFlags: 0, keyCode: 55)
        XCTAssertEqual(counters.startCount, 1, "Clean tap after release must commit")
        XCTAssertTrue(manager.isActiveRecordingBinding(leftCmdBinding.bindingId))
    }

    /// Scenario 2: Hold Left Command + 'M' Key Contamination Before 250ms Delay.
    /// Cancels candidate timer without any callbacks.
    func testScenario2_HoldLeftCommand_MChordBeforeClassificationDelayCancelsTimerWithoutCallbacks() {
        let defaults = UserDefaults.standard
        let key = HotkeyManager.modifierPrefixTriggerDelayKey
        let priorValue = defaults.object(forKey: key)
        defaults.set(0.05, forKey: key)
        defer {
            if let priorValue { defaults.set(priorValue, forKey: key) } else { defaults.removeObject(forKey: key) }
        }

        let manager = makeManager()
        let counters = BindingCounters()
        let leftCmdHold = ModeBinding(
            bindingId: UUID(),
            modeId: UUID(),
            keyCode: 55, // Left Command
            modifiers: [],
            style: .hold,
            onStart: { counters.recordStart() },
            onStop: { counters.recordStop() },
            onAbort: { counters.recordAbort() }
        )
        manager.registerBindings([leftCmdHold])

        let leftCmdRaw = ModeBinding.deviceLeftCommandMask | CGEventFlags.maskCommand.rawValue

        // 1. Press Left Command down -> candidate armed, timer running
        _ = manager.simulateModifierFlags(.maskCommand, rawFlags: leftCmdRaw, keyCode: 55)
        XCTAssertTrue(manager.hasPendingCandidateTimer())
        XCTAssertEqual(counters.startCount, 0)

        // 2. Press 'M' down before delay expires -> cancels timer and sets disqualified
        manager.simulateRegularKeyDown(keyCode: 46)
        XCTAssertFalse(manager.hasPendingCandidateTimer())
        XCTAssertEqual(counters.startCount, 0)
        XCTAssertEqual(counters.stopCount, 0)
        XCTAssertEqual(counters.abortCount, 0)

        // 3. Wait past stale timer deadline
        let delayExp = expectation(description: "stale timer deadline")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { delayExp.fulfill() }
        wait(for: [delayExp], timeout: 0.5)

        XCTAssertEqual(counters.startCount, 0, "Cancelled timer must never fire")
        XCTAssertEqual(counters.abortCount, 0)

        // 4. Release Left Command
        _ = manager.simulateModifierFlags([], rawFlags: 0, keyCode: 55)
        XCTAssertEqual(counters.stopCount, 0)
    }

    /// Scenario 3: Hold Left Command + 'M' Key Contamination After Activation (Active Hold Abort).
    /// Invokes onAbort without normal stop, clearing recording and safety timer.
    func testScenario3_HoldLeftCommand_MChordAfterActivationInvokesAbortWithoutStopFeedback() {
        let defaults = UserDefaults.standard
        let key = HotkeyManager.modifierPrefixTriggerDelayKey
        let priorValue = defaults.object(forKey: key)
        defaults.set(0.02, forKey: key)
        defer {
            if let priorValue { defaults.set(priorValue, forKey: key) } else { defaults.removeObject(forKey: key) }
        }

        let manager = makeManager()
        let counters = BindingCounters()
        let leftCmdHold = ModeBinding(
            bindingId: UUID(),
            modeId: UUID(),
            keyCode: 55, // Left Command
            modifiers: [],
            style: .hold,
            onStart: { counters.recordStart() },
            onStop: { counters.recordStop() },
            onAbort: { counters.recordAbort() }
        )
        manager.registerBindings([leftCmdHold])

        let leftCmdRaw = ModeBinding.deviceLeftCommandMask | CGEventFlags.maskCommand.rawValue

        // 1. Press Left Command down -> wait for activation
        _ = manager.simulateModifierFlags(.maskCommand, rawFlags: leftCmdRaw, keyCode: 55)
        let delayExp = expectation(description: "hold delay elapsed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { delayExp.fulfill() }
        wait(for: [delayExp], timeout: 0.5)

        XCTAssertEqual(counters.startCount, 1, "Hold should become active after delay")
        XCTAssertTrue(manager.isHoldActive(for: leftCmdHold.bindingId))
        XCTAssertTrue(manager.isActiveRecordingBinding(leftCmdHold.bindingId))
        XCTAssertTrue(manager.hasPendingSafetyTimer(for: leftCmdHold.bindingId))

        // 2. Press 'M' down while active -> triggers abort
        manager.simulateRegularKeyDown(keyCode: 46)
        XCTAssertEqual(counters.abortCount, 1, "Chord contamination on active hold must invoke onAbort")
        XCTAssertEqual(counters.stopCount, 0, "Must not invoke normal onStop on abort")
        XCTAssertFalse(manager.isHoldActive(for: leftCmdHold.bindingId))
        XCTAssertFalse(manager.isActiveRecordingBinding(leftCmdHold.bindingId))
        XCTAssertFalse(manager.hasPendingSafetyTimer(for: leftCmdHold.bindingId))

        // 3. Release Left Command -> clean release does not trigger duplicate stop
        _ = manager.simulateModifierFlags([], rawFlags: 0, keyCode: 55)
        XCTAssertEqual(counters.stopCount, 0, "Release after abort must not fire onStop")
        XCTAssertEqual(counters.abortCount, 1)
    }

    /// Scenario 4: Clean Left / Right Toggle Taps Commit on Exact Combo Reduction.
    func testScenario4_CleanLeftAndRightToggleTapsCommitOnExactComboReduction() {
        let manager = makeManager()
        let leftCounters = BindingCounters()
        let rightCounters = BindingCounters()

        let leftCmdBinding = ModeBinding(
            bindingId: UUID(),
            modeId: UUID(),
            keyCode: 55, // Left Command
            modifiers: [],
            style: .toggle,
            onStart: { leftCounters.recordStart() },
            onStop: { leftCounters.recordStop() },
            onAbort: { leftCounters.recordAbort() }
        )
        let rightCmdBinding = ModeBinding(
            bindingId: UUID(),
            modeId: UUID(),
            keyCode: 54, // Right Command
            modifiers: [],
            style: .toggle,
            onStart: { rightCounters.recordStart() },
            onStop: { rightCounters.recordStop() },
            onAbort: { rightCounters.recordAbort() }
        )
        manager.registerBindings([leftCmdBinding, rightCmdBinding])

        let leftCmdRaw = ModeBinding.deviceLeftCommandMask | CGEventFlags.maskCommand.rawValue
        let rightCmdRaw = ModeBinding.deviceRightCommandMask | CGEventFlags.maskCommand.rawValue

        // 1. Left Command tap (toggle on)
        _ = manager.simulateModifierFlags(.maskCommand, rawFlags: leftCmdRaw, keyCode: 55)
        XCTAssertEqual(leftCounters.startCount, 0)
        let swallowedLeftStart = manager.simulateModifierFlags([], rawFlags: 0, keyCode: 55)
        XCTAssertTrue(swallowedLeftStart, "A modifier release that dispatches a hotkey must be swallowed")
        XCTAssertEqual(leftCounters.startCount, 1)
        XCTAssertTrue(manager.isActiveRecordingBinding(leftCmdBinding.bindingId))

        // 2. Left Command tap (toggle off)
        _ = manager.simulateModifierFlags(.maskCommand, rawFlags: leftCmdRaw, keyCode: 55)
        let swallowedLeftStop = manager.simulateModifierFlags([], rawFlags: 0, keyCode: 55)
        XCTAssertTrue(swallowedLeftStop, "The stop release must not reach the target application")
        XCTAssertEqual(leftCounters.stopCount, 1)
        XCTAssertFalse(manager.isActiveRecordingBinding(leftCmdBinding.bindingId))

        // 3. Right Command tap (toggle on)
        _ = manager.simulateModifierFlags(.maskCommand, rawFlags: rightCmdRaw, keyCode: 54)
        XCTAssertEqual(rightCounters.startCount, 0)
        let swallowedRightStart = manager.simulateModifierFlags([], rawFlags: 0, keyCode: 54)
        XCTAssertTrue(swallowedRightStart)
        XCTAssertEqual(rightCounters.startCount, 1)
        XCTAssertTrue(manager.isActiveRecordingBinding(rightCmdBinding.bindingId))

        // 4. Right Command tap (toggle off)
        _ = manager.simulateModifierFlags(.maskCommand, rawFlags: rightCmdRaw, keyCode: 54)
        let swallowedRightStop = manager.simulateModifierFlags([], rawFlags: 0, keyCode: 54)
        XCTAssertTrue(swallowedRightStop)
        XCTAssertEqual(rightCounters.stopCount, 1)
        XCTAssertFalse(manager.isActiveRecordingBinding(rightCmdBinding.bindingId))
    }

    /// Scenario 5: Clean Hold Past Delay Starts and Stops Normally on Reduction.
    func testScenario5_CleanHoldPastDelayStartsAndStopsNormallyOnReduction() {
        let defaults = UserDefaults.standard
        let key = HotkeyManager.modifierPrefixTriggerDelayKey
        let priorValue = defaults.object(forKey: key)
        defaults.set(0.02, forKey: key)
        defer {
            if let priorValue { defaults.set(priorValue, forKey: key) } else { defaults.removeObject(forKey: key) }
        }

        let manager = makeManager()
        let counters = BindingCounters()
        let leftCmdHold = ModeBinding(
            bindingId: UUID(),
            modeId: UUID(),
            keyCode: 55, // Left Command
            modifiers: [],
            style: .hold,
            onStart: { counters.recordStart() },
            onStop: { counters.recordStop() },
            onAbort: { counters.recordAbort() }
        )
        manager.registerBindings([leftCmdHold])

        let leftCmdRaw = ModeBinding.deviceLeftCommandMask | CGEventFlags.maskCommand.rawValue

        // 1. Hold Left Command down past delay
        _ = manager.simulateModifierFlags(.maskCommand, rawFlags: leftCmdRaw, keyCode: 55)
        let delayExp = expectation(description: "hold delay elapsed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { delayExp.fulfill() }
        wait(for: [delayExp], timeout: 0.5)

        XCTAssertEqual(counters.startCount, 1)
        XCTAssertTrue(manager.isHoldActive(for: leftCmdHold.bindingId))

        // 2. Release Left Command -> clean stop
        _ = manager.simulateModifierFlags([], rawFlags: 0, keyCode: 55)
        XCTAssertEqual(counters.stopCount, 1)
        XCTAssertEqual(counters.abortCount, 0)
        XCTAssertFalse(manager.isHoldActive(for: leftCmdHold.bindingId))
    }

    /// Scenario 6: Multi-Modifier Step-Down Release: Toggle `Ctrl + Shift -> Ctrl -> empty`.
    /// Commits once at first transition and suppresses Ctrl-only prefix.
    func testScenario6_MultiModifierStepDown_ToggleCtrlShift_CommitsOnceAtFirstTransitionAndSuppressesPrefix() {
        let manager = makeManager()
        let ctrlCounters = BindingCounters()
        let ctrlShiftCounters = BindingCounters()

        let ctrlBinding = ModeBinding(
            bindingId: UUID(),
            modeId: UUID(),
            keyCode: 59, // Left Control
            modifiers: [],
            style: .toggle,
            onStart: { ctrlCounters.recordStart() },
            onStop: { ctrlCounters.recordStop() },
            onAbort: { ctrlCounters.recordAbort() }
        )
        let ctrlShiftBinding = ModeBinding(
            bindingId: UUID(),
            modeId: UUID(),
            keyCode: 56, // Left Shift
            modifiers: [.maskControl],
            style: .toggle,
            onStart: { ctrlShiftCounters.recordStart() },
            onStop: { ctrlShiftCounters.recordStop() },
            onAbort: { ctrlShiftCounters.recordAbort() }
        )
        manager.registerBindings([ctrlBinding, ctrlShiftBinding])

        let ctrlRaw = ModeBinding.deviceLeftControlMask | CGEventFlags.maskControl.rawValue
        let comboRaw = ModeBinding.deviceLeftControlMask | ModeBinding.deviceLeftShiftMask | CGEventFlags.maskControl.rawValue | CGEventFlags.maskShift.rawValue

        // 1. Press Control down -> Ctrl candidate
        _ = manager.simulateModifierFlags(.maskControl, rawFlags: ctrlRaw, keyCode: 59)
        XCTAssertEqual(ctrlCounters.startCount, 0)

        // 2. Press Shift down -> builds to Ctrl+Shift candidate
        _ = manager.simulateModifierFlags([.maskControl, .maskShift], rawFlags: comboRaw, keyCode: 56)
        XCTAssertEqual(ctrlShiftCounters.startCount, 0)
        XCTAssertEqual(ctrlCounters.startCount, 0)

        // 3. Release Shift (step-down to Ctrl) -> commits Ctrl+Shift toggle, enters settling
        _ = manager.simulateModifierFlags(.maskControl, rawFlags: ctrlRaw, keyCode: 56)
        XCTAssertEqual(ctrlShiftCounters.startCount, 1, "Ctrl+Shift toggle must commit on first step-down reduction")
        XCTAssertEqual(ctrlCounters.startCount, 0, "Ctrl binding must be suppressed during settling")

        // 4. Release Control (step-down to empty) -> resets to idle
        _ = manager.simulateModifierFlags([], rawFlags: 0, keyCode: 59)
        XCTAssertEqual(ctrlCounters.startCount, 0, "Releasing remaining modifier must not trigger Ctrl binding")
        XCTAssertEqual(ctrlShiftCounters.startCount, 1)
    }

    /// Scenario 7: Multi-Modifier Step-Down Release: Hold `Ctrl + Shift -> Ctrl -> empty`.
    /// Stops once at first transition and leaves no ghost hold state.
    func testScenario7_MultiModifierStepDown_HoldCtrlShift_StopsOnceAtFirstTransitionAndLeavesNoGhostState() {
        let defaults = UserDefaults.standard
        let key = HotkeyManager.modifierPrefixTriggerDelayKey
        let priorValue = defaults.object(forKey: key)
        defaults.set(0.02, forKey: key)
        defer {
            if let priorValue { defaults.set(priorValue, forKey: key) } else { defaults.removeObject(forKey: key) }
        }

        let manager = makeManager()
        let ctrlCounters = BindingCounters()
        let ctrlShiftCounters = BindingCounters()

        let ctrlHold = ModeBinding(
            bindingId: UUID(),
            modeId: UUID(),
            keyCode: 59, // Left Control
            modifiers: [],
            style: .hold,
            onStart: { ctrlCounters.recordStart() },
            onStop: { ctrlCounters.recordStop() },
            onAbort: { ctrlCounters.recordAbort() }
        )
        let ctrlShiftHold = ModeBinding(
            bindingId: UUID(),
            modeId: UUID(),
            keyCode: 56, // Left Shift
            modifiers: [.maskControl],
            style: .hold,
            onStart: { ctrlShiftCounters.recordStart() },
            onStop: { ctrlShiftCounters.recordStop() },
            onAbort: { ctrlShiftCounters.recordAbort() }
        )
        manager.registerBindings([ctrlHold, ctrlShiftHold])

        let ctrlRaw = ModeBinding.deviceLeftControlMask | CGEventFlags.maskControl.rawValue
        let comboRaw = ModeBinding.deviceLeftControlMask | ModeBinding.deviceLeftShiftMask | CGEventFlags.maskControl.rawValue | CGEventFlags.maskShift.rawValue

        // 1. Press Control then Shift down -> combo candidate
        _ = manager.simulateModifierFlags(.maskControl, rawFlags: ctrlRaw, keyCode: 59)
        _ = manager.simulateModifierFlags([.maskControl, .maskShift], rawFlags: comboRaw, keyCode: 56)

        // Wait for classification delay to start Ctrl+Shift hold
        let delayExp = expectation(description: "combo hold delay elapsed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { delayExp.fulfill() }
        wait(for: [delayExp], timeout: 0.5)

        XCTAssertEqual(ctrlShiftCounters.startCount, 1)
        XCTAssertEqual(ctrlCounters.startCount, 0)
        XCTAssertTrue(manager.isHoldActive(for: ctrlShiftHold.bindingId))

        // 2. Release Shift (step-down to Ctrl) -> clean stop for Ctrl+Shift hold, enters settling
        _ = manager.simulateModifierFlags(.maskControl, rawFlags: ctrlRaw, keyCode: 56)
        XCTAssertEqual(ctrlShiftCounters.stopCount, 1)
        XCTAssertEqual(ctrlShiftCounters.abortCount, 0)
        XCTAssertFalse(manager.isHoldActive(for: ctrlShiftHold.bindingId))
        XCTAssertFalse(manager.hasPendingSafetyTimer(for: ctrlShiftHold.bindingId))
        XCTAssertEqual(ctrlCounters.startCount, 0)

        // 3. Release Control (step-down to empty) -> resets settling to idle
        _ = manager.simulateModifierFlags([], rawFlags: 0, keyCode: 59)
        XCTAssertEqual(ctrlCounters.startCount, 0)
        XCTAssertEqual(ctrlCounters.stopCount, 0)
        XCTAssertFalse(manager.isHoldActive(for: ctrlHold.bindingId))
        XCTAssertFalse(manager.hasPendingSafetyTimer(for: ctrlHold.bindingId))
    }

    /// Scenario 8: Larger combo reached in either modifier order produces the same candidate.
    func testScenario8_LargerComboFormedInEitherOrderProducesSameCandidate() {
        let manager = makeManager()
        let counters = BindingCounters()
        let fnLeftShiftBinding = ModeBinding(
            bindingId: UUID(),
            modeId: UUID(),
            keyCode: 56, // Left Shift
            modifiers: [.maskSecondaryFn],
            style: .toggle,
            onStart: { counters.recordStart() },
            onStop: { counters.recordStop() },
            onAbort: { counters.recordAbort() }
        )
        manager.registerBindings([fnLeftShiftBinding])

        let fnFlags: CGEventFlags = [.maskSecondaryFn]
        let fnRaw: UInt64 = CGEventFlags.maskSecondaryFn.rawValue
        let leftShiftFlags: CGEventFlags = [.maskShift]
        let leftShiftRaw: UInt64 = ModeBinding.deviceLeftShiftMask | CGEventFlags.maskShift.rawValue
        let comboFlags: CGEventFlags = [.maskSecondaryFn, .maskShift]
        let comboRaw: UInt64 = ModeBinding.deviceLeftShiftMask | CGEventFlags.maskShift.rawValue | CGEventFlags.maskSecondaryFn.rawValue

        // Order 1: Fn down (63), then Left Shift down (56) -> combo candidate -> clean release to []
        _ = manager.simulateModifierFlags(fnFlags, rawFlags: fnRaw, keyCode: 63)
        _ = manager.simulateModifierFlags(comboFlags, rawFlags: comboRaw, keyCode: 56)
        _ = manager.simulateModifierFlags([], rawFlags: 0, keyCode: 56)
        XCTAssertEqual(counters.startCount, 1)

        manager.resetActiveState()
        counters.reset()

        // Order 2: Left Shift down (56), then Fn down (63) -> combo candidate -> clean release to []
        _ = manager.simulateModifierFlags(leftShiftFlags, rawFlags: leftShiftRaw, keyCode: 56)
        _ = manager.simulateModifierFlags(comboFlags, rawFlags: comboRaw, keyCode: 63)
        _ = manager.simulateModifierFlags([], rawFlags: 0, keyCode: 63)
        XCTAssertEqual(counters.startCount, 1)
    }

    /// Scenario 9: Releasing a larger unowned combo through a registered smaller combo never arms it.
    func testScenario9_ReleasingLargerUnownedComboThroughRegisteredSmallerComboNeverArmsIt() {
        let manager = makeManager()
        let ctrlCounters = BindingCounters()

        let ctrlBinding = ModeBinding(
            bindingId: UUID(),
            modeId: UUID(),
            keyCode: 59, // Left Control
            modifiers: [],
            style: .toggle,
            onStart: { ctrlCounters.recordStart() },
            onStop: { ctrlCounters.recordStop() },
            onAbort: { ctrlCounters.recordAbort() }
        )
        manager.registerBindings([ctrlBinding])

        let ctrlRaw = ModeBinding.deviceLeftControlMask | CGEventFlags.maskControl.rawValue
        let comboRaw = ModeBinding.deviceLeftControlMask | ModeBinding.deviceLeftShiftMask | CGEventFlags.maskControl.rawValue | CGEventFlags.maskShift.rawValue

        // 1. Press unowned combo Ctrl + Shift directly
        _ = manager.simulateModifierFlags([.maskControl, .maskShift], rawFlags: comboRaw, keyCode: 56)
        XCTAssertEqual(ctrlCounters.startCount, 0)

        // 2. Release Shift (Ctrl + Shift -> Ctrl) -> step-down transient
        _ = manager.simulateModifierFlags(.maskControl, rawFlags: ctrlRaw, keyCode: 56)
        XCTAssertEqual(ctrlCounters.startCount, 0, "Step-down from unowned combo must not arm Ctrl binding")

        // 3. Release Control (Ctrl -> empty)
        _ = manager.simulateModifierFlags([], rawFlags: 0, keyCode: 59)
        XCTAssertEqual(ctrlCounters.startCount, 0)
    }

    /// Scenario 10: Regular key-up and later modifier changes do not re-arm a disqualified gesture;
    /// complete release followed by a new press does.
    func testScenario10_DisqualifiedStatePersistsUntilAllModifiersReleased() {
        let manager = makeManager()
        let counters = BindingCounters()
        let leftCmdBinding = ModeBinding(
            bindingId: UUID(),
            modeId: UUID(),
            keyCode: 55, // Left Command
            modifiers: [],
            style: .toggle,
            onStart: { counters.recordStart() },
            onStop: { counters.recordStop() },
            onAbort: { counters.recordAbort() }
        )
        manager.registerBindings([leftCmdBinding])

        let leftCmdRaw = ModeBinding.deviceLeftCommandMask | CGEventFlags.maskCommand.rawValue
        let cmdShiftRaw = ModeBinding.deviceLeftCommandMask | ModeBinding.deviceLeftShiftMask | CGEventFlags.maskCommand.rawValue | CGEventFlags.maskShift.rawValue

        // 1. Cmd down -> 'M' down -> disqualified
        _ = manager.simulateModifierFlags(.maskCommand, rawFlags: leftCmdRaw, keyCode: 55)
        manager.simulateRegularKeyDown(keyCode: 46)

        // 2. Press Shift down while disqualified (Cmd + Shift) -> still disqualified
        _ = manager.simulateModifierFlags([.maskCommand, .maskShift], rawFlags: cmdShiftRaw, keyCode: 56)
        XCTAssertEqual(counters.startCount, 0)

        // 3. Release Shift (back to Cmd) -> still disqualified
        _ = manager.simulateModifierFlags(.maskCommand, rawFlags: leftCmdRaw, keyCode: 56)
        XCTAssertEqual(counters.startCount, 0)

        // 4. Release Cmd (flags become empty) -> resets to idle
        _ = manager.simulateModifierFlags([], rawFlags: 0, keyCode: 55)
        XCTAssertEqual(counters.startCount, 0)

        // 5. New clean tap now commits
        _ = manager.simulateModifierFlags(.maskCommand, rawFlags: leftCmdRaw, keyCode: 55)
        _ = manager.simulateModifierFlags([], rawFlags: 0, keyCode: 55)
        XCTAssertEqual(counters.startCount, 1)
    }

    /// Scenario 11: Toggle candidates have no classification timer; waiting beyond delay causes no callback.
    func testScenario11_ToggleCandidateHasNoClassificationTimer() {
        let manager = makeManager()
        let counters = BindingCounters()
        let leftCmdBinding = ModeBinding(
            bindingId: UUID(),
            modeId: UUID(),
            keyCode: 55, // Left Command
            modifiers: [],
            style: .toggle,
            onStart: { counters.recordStart() },
            onStop: { counters.recordStop() },
            onAbort: { counters.recordAbort() }
        )
        manager.registerBindings([leftCmdBinding])

        let leftCmdRaw = ModeBinding.deviceLeftCommandMask | CGEventFlags.maskCommand.rawValue

        // 1. Press Cmd down
        _ = manager.simulateModifierFlags(.maskCommand, rawFlags: leftCmdRaw, keyCode: 55)
        XCTAssertFalse(manager.hasPendingCandidateTimer(), "Toggle candidate must not schedule a classification timer")

        // 2. Wait 0.05s
        let waitExp = expectation(description: "wait while holding toggle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { waitExp.fulfill() }
        wait(for: [waitExp], timeout: 0.5)

        XCTAssertEqual(counters.startCount, 0, "Toggle candidate must not commit while modifier is held")

        // 3. Release Cmd -> clean release commit
        _ = manager.simulateModifierFlags([], rawFlags: 0, keyCode: 55)
        XCTAssertEqual(counters.startCount, 1)
    }

    /// Scenario 12: Raw-device-mask and key-code-fallback inputs both preserve side matching.
    func testScenario12_RawDeviceMaskAndKeyCodeFallbackBothPreserveSideMatching() {
        let manager = makeManager()
        let leftCounters = BindingCounters()
        let rightCounters = BindingCounters()

        let leftCmdBinding = ModeBinding(
            bindingId: UUID(),
            modeId: UUID(),
            keyCode: 55, // Left Command
            modifiers: [],
            style: .toggle,
            onStart: { leftCounters.recordStart() },
            onStop: { leftCounters.recordStop() },
            onAbort: { leftCounters.recordAbort() }
        )
        let rightCmdBinding = ModeBinding(
            bindingId: UUID(),
            modeId: UUID(),
            keyCode: 54, // Right Command
            modifiers: [],
            style: .toggle,
            onStart: { rightCounters.recordStart() },
            onStop: { rightCounters.recordStop() },
            onAbort: { rightCounters.recordAbort() }
        )
        manager.registerBindings([leftCmdBinding, rightCmdBinding])

        // Path A: Raw flags mask
        let leftRaw = ModeBinding.deviceLeftCommandMask | CGEventFlags.maskCommand.rawValue
        _ = manager.simulateModifierFlags(.maskCommand, rawFlags: leftRaw, keyCode: 55)
        _ = manager.simulateModifierFlags([], rawFlags: 0, keyCode: 55)
        XCTAssertEqual(leftCounters.startCount, 1)
        XCTAssertEqual(rightCounters.startCount, 0)

        manager.resetActiveState()

        // Path B: Key-code fallback (rawFlags = 0)
        _ = manager.simulateModifierFlags(.maskCommand, rawFlags: 0, keyCode: 54)
        _ = manager.simulateModifierFlags([], rawFlags: 0, keyCode: 54)
        XCTAssertEqual(rightCounters.startCount, 1)
        XCTAssertEqual(leftCounters.startCount, 1)
    }

    /// Scenario 13: Edge Case Resets, Autorepeat, and Disqualified Stuck Hold Recovery.
    func testScenario13_EdgeCaseResetsAutorepeatAndStuckHoldRecovery() {
        let defaults = UserDefaults.standard
        let key = HotkeyManager.modifierPrefixTriggerDelayKey
        let priorValue = defaults.object(forKey: key)
        defaults.set(0.02, forKey: key)
        defer {
            if let priorValue { defaults.set(priorValue, forKey: key) } else { defaults.removeObject(forKey: key) }
        }

        let manager = makeManager()
        let counters = BindingCounters()
        let leftCmdHold = ModeBinding(
            bindingId: UUID(),
            modeId: UUID(),
            keyCode: 55, // Left Command
            modifiers: [],
            style: .hold,
            onStart: { counters.recordStart() },
            onStop: { counters.recordStop() },
            onAbort: { counters.recordAbort() }
        )
        manager.registerBindings([leftCmdHold])

        let leftCmdRaw = ModeBinding.deviceLeftCommandMask | CGEventFlags.maskCommand.rawValue

        // Autorepeat regular key ignored by reducer
        _ = manager.simulateModifierFlags(.maskCommand, rawFlags: leftCmdRaw, keyCode: 55)
        manager.simulateRegularKeyDown(keyCode: 46, isRepeat: true)
        XCTAssertTrue(manager.hasPendingCandidateTimer(), "Autorepeat regular key must not disqualify")

        // Wait for hold to activate
        let delayExp = expectation(description: "hold delay elapsed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { delayExp.fulfill() }
        wait(for: [delayExp], timeout: 0.5)
        XCTAssertEqual(counters.startCount, 1)

        // Disqualify with non-repeat regular key
        manager.simulateRegularKeyDown(keyCode: 46, isRepeat: false)
        XCTAssertEqual(counters.abortCount, 1)

        // Reset active state
        manager.resetActiveState()
        XCTAssertFalse(manager.isHoldActive(for: leftCmdHold.bindingId))
        XCTAssertFalse(manager.hasPendingCandidateTimer())
        XCTAssertFalse(manager.hasPendingSafetyTimer(for: leftCmdHold.bindingId))
    }

    // MARK: - Suite 3: App/Session Abort & SoundFeedback Cancellation Tests

    func testSoundFeedbackCancelActiveFeedbackDoesNotCrash() {
        SoundFeedback.cancelActiveFeedback()
    }

    func testReviseCoordinatorCancelActiveTransaction() async {
        await ReviseCoordinator.shared.cancelActiveTransaction()
    }

    @MainActor
    func testAppStateCancelSetsBarPhaseToHidden() {
        let appState = AppState()
        appState.startRecording()
        XCTAssertEqual(appState.barPhase, .preparing)

        appState.cancel()
        XCTAssertEqual(appState.barPhase, .hidden)
    }

    /// Scenario 14: Redundant flagsChanged and Caps Lock during active hold preserves hold state.
    func testScenario14_RedundantFlagsChangedAndCapsLockDuringActiveHoldPreservesHold() {
        let defaults = UserDefaults.standard
        let key = HotkeyManager.modifierPrefixTriggerDelayKey
        let priorValue = defaults.object(forKey: key)
        defaults.set(0.02, forKey: key)
        defer {
            if let priorValue { defaults.set(priorValue, forKey: key) } else { defaults.removeObject(forKey: key) }
        }

        let manager = makeManager()
        let counters = BindingCounters()
        let leftCmdHold = ModeBinding(
            bindingId: UUID(),
            modeId: UUID(),
            keyCode: 55, // Left Command
            modifiers: [],
            style: .hold,
            onStart: { counters.recordStart() },
            onStop: { counters.recordStop() },
            onAbort: { counters.recordAbort() }
        )
        manager.registerBindings([leftCmdHold])

        let leftCmdRaw = ModeBinding.deviceLeftCommandMask | CGEventFlags.maskCommand.rawValue

        // 1. Press Left Command
        let swallowedPress = manager.simulateModifierFlags(.maskCommand, rawFlags: leftCmdRaw, keyCode: 55)
        XCTAssertTrue(swallowedPress)

        // 2. Wait for hold classification timer to fire and activate hold
        let delayExp = expectation(description: "hold delay elapsed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { delayExp.fulfill() }
        wait(for: [delayExp], timeout: 0.5)
        XCTAssertEqual(counters.startCount, 1)
        XCTAssertEqual(counters.stopCount, 0)
        XCTAssertTrue(manager.isHoldActive(for: leftCmdHold.bindingId))

        // 3. Send Caps Lock flagsChanged event (flags include maskAlphaShift)
        let capsFlags: CGEventFlags = [.maskCommand, .maskAlphaShift]
        let swallowedCaps = manager.simulateModifierFlags(capsFlags, rawFlags: leftCmdRaw, keyCode: 57)
        XCTAssertTrue(swallowedCaps)
        XCTAssertTrue(manager.isHoldActive(for: leftCmdHold.bindingId), "Hold must remain active across Caps Lock event")
        XCTAssertEqual(counters.stopCount, 0, "No premature stop callback should occur on Caps Lock")
        XCTAssertEqual(counters.startCount, 1)

        // 4. Send redundant same-key flagsChanged event
        let swallowedRedundant = manager.simulateModifierFlags(.maskCommand, rawFlags: leftCmdRaw, keyCode: 55)
        XCTAssertTrue(swallowedRedundant)
        XCTAssertTrue(manager.isHoldActive(for: leftCmdHold.bindingId), "Hold must remain active across redundant flagsChanged")
        XCTAssertEqual(counters.stopCount, 0)

        // 5. Clean release of Left Command stops the hold cleanly
        _ = manager.simulateModifierFlags([], rawFlags: 0, keyCode: 55)
        XCTAssertEqual(counters.stopCount, 1)
        XCTAssertFalse(manager.isHoldActive(for: leftCmdHold.bindingId))
    }

    /// Scenario 15: Redundant flagsChanged and Caps Lock during toggle candidate preserves candidate.
    func testScenario15_RedundantFlagsChangedAndCapsLockDuringToggleCandidatePreservesCandidate() {
        let manager = makeManager()
        let counters = BindingCounters()
        let leftCmdToggle = ModeBinding(
            bindingId: UUID(),
            modeId: UUID(),
            keyCode: 55, // Left Command
            modifiers: [],
            style: .toggle,
            onStart: { counters.recordStart() },
            onStop: { counters.recordStop() },
            onAbort: { counters.recordAbort() }
        )
        manager.registerBindings([leftCmdToggle])

        let leftCmdRaw = ModeBinding.deviceLeftCommandMask | CGEventFlags.maskCommand.rawValue

        // 1. Press Left Command (arms toggle candidate)
        let swallowedPress = manager.simulateModifierFlags(.maskCommand, rawFlags: leftCmdRaw, keyCode: 55)
        XCTAssertTrue(swallowedPress)
        XCTAssertEqual(counters.startCount, 0)

        // 2. Send Caps Lock flagsChanged event
        let capsFlags: CGEventFlags = [.maskCommand, .maskAlphaShift]
        let swallowedCaps = manager.simulateModifierFlags(capsFlags, rawFlags: leftCmdRaw, keyCode: 57)
        XCTAssertTrue(swallowedCaps)
        XCTAssertEqual(counters.startCount, 0, "Toggle should not commit prematurely on Caps Lock")

        // 3. Send redundant same-key flagsChanged event
        let swallowedRedundant = manager.simulateModifierFlags(.maskCommand, rawFlags: leftCmdRaw, keyCode: 55)
        XCTAssertTrue(swallowedRedundant)
        XCTAssertEqual(counters.startCount, 0)

        // 4. Release Left Command cleanly -> toggle commits
        _ = manager.simulateModifierFlags([], rawFlags: 0, keyCode: 55)
        XCTAssertEqual(counters.startCount, 1, "Toggle must commit on clean release")
        XCTAssertEqual(counters.stopCount, 0)
        XCTAssertEqual(counters.abortCount, 0)
    }

    /// Scenario 16: Redundant flagsChanged during hold candidate classification allows normal activation.
    func testScenario16_RedundantFlagsChangedDuringHoldCandidateAllowsTimerActivation() {
        let defaults = UserDefaults.standard
        let key = HotkeyManager.modifierPrefixTriggerDelayKey
        let priorValue = defaults.object(forKey: key)
        defaults.set(0.05, forKey: key)
        defer {
            if let priorValue { defaults.set(priorValue, forKey: key) } else { defaults.removeObject(forKey: key) }
        }

        let manager = makeManager()
        let counters = BindingCounters()
        let leftCmdHold = ModeBinding(
            bindingId: UUID(),
            modeId: UUID(),
            keyCode: 55, // Left Command
            modifiers: [],
            style: .hold,
            onStart: { counters.recordStart() },
            onStop: { counters.recordStop() },
            onAbort: { counters.recordAbort() }
        )
        manager.registerBindings([leftCmdHold])

        let leftCmdRaw = ModeBinding.deviceLeftCommandMask | CGEventFlags.maskCommand.rawValue

        // 1. Press Left Command (arms hold candidate)
        _ = manager.simulateModifierFlags(.maskCommand, rawFlags: leftCmdRaw, keyCode: 55)
        XCTAssertTrue(manager.hasPendingCandidateTimer())

        // 2. Send Caps Lock flagsChanged event before timer expiration
        let capsFlags: CGEventFlags = [.maskCommand, .maskAlphaShift]
        _ = manager.simulateModifierFlags(capsFlags, rawFlags: leftCmdRaw, keyCode: 57)

        // 3. Wait for timer delay to expire
        let delayExp = expectation(description: "classification delay elapsed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { delayExp.fulfill() }
        wait(for: [delayExp], timeout: 0.5)

        // 4. Verify candidate successfully activated hold
        XCTAssertEqual(counters.startCount, 1)
        XCTAssertTrue(manager.isHoldActive(for: leftCmdHold.bindingId))

        // 5. Release
        _ = manager.simulateModifierFlags([], rawFlags: 0, keyCode: 55)
        XCTAssertEqual(counters.stopCount, 1)
    }

    /// Test AppDelegate onAbort bridge: start gate race invalidation and session cancel discard chain end-to-end.
    @MainActor
    func testAppDelegateOnAbortBridgeEndToEnd() async {
        // 1. Start gate unit validation
        var startGate = RecordingStartGate()
        let startToken = startGate.begin()
        XCTAssertTrue(startGate.allowsStart(token: startToken))

        // Invalidate via abort
        startGate.invalidate()
        XCTAssertFalse(startGate.allowsStart(token: startToken), "Invalidated start token must block queued recording start")

        // 2. Full session cancellation discard chain
        let appState = AppState()
        let session = RecognitionSession()

        var receivedEvents: [RecognitionEvent] = []
        let (recognitionEvents, recognitionEventContinuation) = AsyncStream<RecognitionEvent>.makeStream()
        await session.setOnASREvent { event in
            recognitionEventContinuation.yield(event)
        }

        let eventCollectorTask = Task { @MainActor in
            for await event in recognitionEvents {
                receivedEvents.append(event)
            }
        }

        // Put app state into preparing/recording
        appState.startRecording()
        XCTAssertEqual(appState.barPhase, .preparing)
        await session.setState(.recording)
        let recordingState = await session.state
        XCTAssertEqual(recordingState, .recording)

        // Execute composed AppDelegate onAbort bridge
        startGate.invalidate()
        appState.cancel()
        SoundFeedback.cancelActiveFeedback()
        await session.cancelRecording()

        // Verify side effects
        XCTAssertEqual(appState.barPhase, .hidden, "AppState must transition to .hidden without entering .processing")
        let idleState = await session.state
        XCTAssertEqual(idleState, .idle, "RecognitionSession must return to .idle")

        // Yield time for any async events
        recognitionEventContinuation.finish()
        await eventCollectorTask.value

        // Ensure no completed or finalized events were emitted
        let completedOrFinalized = receivedEvents.contains { event in
            switch event {
            case .completed, .finalized, .processingResult:
                return true
            default:
                return false
            }
        }
        XCTAssertFalse(completedOrFinalized, "Full discard abort must not emit completion or processing events")
    }

    // MARK: - Event Tap Recovery Policy & Lifecycle Tests

    func testEventTapRecoveryActionPolicy() {
        XCTAssertEqual(
            HotkeyManager.recoveryAction(for: .tapDisabledByUserInput, isAccessibilityTrusted: false),
            .revoke
        )
        XCTAssertEqual(
            HotkeyManager.recoveryAction(for: .tapDisabledByTimeout, isAccessibilityTrusted: false),
            .revoke
        )
        XCTAssertEqual(
            HotkeyManager.recoveryAction(for: .tapDisabledByUserInput, isAccessibilityTrusted: true),
            .reenable
        )
        XCTAssertEqual(
            HotkeyManager.recoveryAction(for: .tapDisabledByTimeout, isAccessibilityTrusted: true),
            .reenable
        )
        XCTAssertEqual(
            HotkeyManager.recoveryAction(for: .keyDown, isAccessibilityTrusted: false),
            .passThrough
        )
        XCTAssertEqual(
            HotkeyManager.recoveryAction(for: .keyDown, isAccessibilityTrusted: true),
            .passThrough
        )
    }

    func testRepeatedStopLeavesStoppedStateWithoutRevocationCallback() {
        let manager = makeManager()
        var revocationCount = 0
        manager.onAccessibilityRevoked = {
            revocationCount += 1
        }

        XCTAssertEqual(manager.eventTapLifecycleStateDescription, "stopped")
        manager.stop()
        XCTAssertEqual(manager.eventTapLifecycleStateDescription, "stopped")
        manager.stop()
        XCTAssertEqual(manager.eventTapLifecycleStateDescription, "stopped")

        let exp = expectation(description: "No async revocation callback")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            exp.fulfill()
        }
        wait(for: [exp], timeout: 0.2)
        XCTAssertEqual(revocationCount, 0)
    }

    func testSimulatedPermissionLossLifecycleAndOneShotRevocationCallback() {
        let manager = makeManager()
        var revocationCount = 0
        manager.onAccessibilityRevoked = {
            revocationCount += 1
        }

        // First transition to revoked
        manager.simulateRevocationForTesting()
        XCTAssertEqual(manager.eventTapLifecycleStateDescription, "revoked")

        let exp1 = expectation(description: "First revocation callback dispatched")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            exp1.fulfill()
        }
        wait(for: [exp1], timeout: 0.2)
        XCTAssertEqual(revocationCount, 1)

        // Second simulated loss in the same generation must not emit again
        manager.simulateRevocationForTesting()
        XCTAssertEqual(manager.eventTapLifecycleStateDescription, "revoked")

        let exp2 = expectation(description: "Duplicate revocation suppressed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            exp2.fulfill()
        }
        wait(for: [exp2], timeout: 0.2)
        XCTAssertEqual(revocationCount, 1)

        // Reset generation after simulated successful start
        manager.resetRevocationGenerationForTesting()
        XCTAssertEqual(manager.eventTapLifecycleStateDescription, "running")

        // Next revocation in new generation should emit once more
        manager.simulateRevocationForTesting()
        XCTAssertEqual(manager.eventTapLifecycleStateDescription, "revoked")

        let exp3 = expectation(description: "New generation revocation callback dispatched")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            exp3.fulfill()
        }
        wait(for: [exp3], timeout: 0.2)
        XCTAssertEqual(revocationCount, 2)
    }

    func testInitialStartWithoutPermissionDoesNotEmitRevocationCallback() {
        let manager = makeManager()
        var revocationCount = 0
        manager.onAccessibilityRevoked = {
            revocationCount += 1
        }

        // If permission is absent, calling start() should transition to revoked but NOT emit revocation callback
        if !PermissionManager.hasAccessibilityPermission {
            let started = manager.start()
            XCTAssertFalse(started)
            XCTAssertEqual(manager.eventTapLifecycleStateDescription, "revoked")

            let exp = expectation(description: "No revocation callback on initial start")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                exp.fulfill()
            }
            wait(for: [exp], timeout: 0.2)
            XCTAssertEqual(revocationCount, 0, "Initial denial must not trigger onAccessibilityRevoked")
        }
    }
}
