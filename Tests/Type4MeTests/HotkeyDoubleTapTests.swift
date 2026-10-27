import XCTest
@testable import Type4Me

/// Double-tap modifier hotkeys: two short clean taps toggle recording, and the
/// style stays readable by releases that only know hold/toggle.
final class HotkeyDoubleTapTests: XCTestCase {

    private let rightOption: CGKeyCode = 61
    private let rightOptionRaw = CGEventFlags.maskAlternate.rawValue | ModeBinding.deviceRightOptionMask
    private var clock: TimeInterval = 1_000
    private var previousLanguage: String?
    private var previousInterval: Any?

    override func setUp() {
        super.setUp()
        previousLanguage = UserDefaults.standard.string(forKey: "tf_language")
        previousInterval = UserDefaults.standard.object(forKey: HotkeyManager.doubleTapIntervalKey)
        UserDefaults.standard.removeObject(forKey: HotkeyManager.doubleTapIntervalKey)
    }

    override func tearDown() {
        if let previousLanguage {
            UserDefaults.standard.set(previousLanguage, forKey: "tf_language")
        } else {
            UserDefaults.standard.removeObject(forKey: "tf_language")
        }
        if let previousInterval {
            UserDefaults.standard.set(previousInterval, forKey: HotkeyManager.doubleTapIntervalKey)
        }
        super.tearDown()
    }

    // MARK: - Fixtures

    private func makeManager(bindings: [ModeBinding]) -> HotkeyManager {
        let manager = HotkeyManager()
        manager.now = { [unowned self] in self.clock }
        manager.registerBindings(bindings)
        return manager
    }

    private func makeDoubleTapBinding(counters: BindingCounters) -> ModeBinding {
        ModeBinding(
            bindingId: UUID(),
            modeId: UUID(),
            keyCode: rightOption,
            modifiers: [],
            style: .doubleTap,
            onStart: { counters.recordStart() },
            onStop: { counters.recordStop() },
            onAbort: { counters.recordAbort() }
        )
    }

    /// Presses and releases Right Option, holding it for `hold` seconds.
    /// Returns whether the press and the release were swallowed.
    @discardableResult
    private func tap(_ manager: HotkeyManager, hold: TimeInterval = 0.08) -> (press: Bool, release: Bool) {
        let press = manager.simulateModifierFlags(.maskAlternate, rawFlags: rightOptionRaw, keyCode: rightOption)
        clock += hold
        let release = manager.simulateModifierFlags([], rawFlags: 0, keyCode: rightOption)
        return (press, release)
    }

    // MARK: - Gesture

    func testTwoQuickTapsStartAndTwoMoreStop() {
        let counters = BindingCounters()
        let binding = makeDoubleTapBinding(counters: counters)
        let manager = makeManager(bindings: [binding])

        tap(manager)
        XCTAssertEqual(counters.startCount, 0)
        XCTAssertTrue(manager.hasPendingDoubleTap(for: binding.bindingId))

        clock += 0.15
        tap(manager)
        XCTAssertEqual(counters.startCount, 1)
        XCTAssertTrue(manager.isActiveRecordingBinding(binding.bindingId))
        XCTAssertFalse(manager.hasPendingDoubleTap(for: binding.bindingId))

        clock += 3
        tap(manager)
        XCTAssertEqual(counters.stopCount, 0, "A single tap must not stop a double-tap recording")
        clock += 0.15
        tap(manager)
        XCTAssertEqual(counters.stopCount, 1)
        XCTAssertFalse(manager.isActiveRecordingBinding(binding.bindingId))
    }

    func testTapsPassThroughToTheSystem() {
        let counters = BindingCounters()
        let manager = makeManager(bindings: [makeDoubleTapBinding(counters: counters)])

        let first = tap(manager)
        clock += 0.15
        let second = tap(manager)

        XCTAssertEqual(counters.startCount, 1)
        XCTAssertFalse(first.press)
        XCTAssertFalse(first.release)
        XCTAssertFalse(second.press)
        XCTAssertFalse(second.release, "The starting release must stay balanced with its unswallowed press")
    }

    func testSlowSecondTapStartsANewPairInstead() {
        let counters = BindingCounters()
        let binding = makeDoubleTapBinding(counters: counters)
        let manager = makeManager(bindings: [binding])

        tap(manager)
        clock += HotkeyManager.defaultDoubleTapInterval + 0.1
        tap(manager)
        XCTAssertEqual(counters.startCount, 0)
        XCTAssertTrue(manager.hasPendingDoubleTap(for: binding.bindingId))

        clock += 0.15
        tap(manager)
        XCTAssertEqual(counters.startCount, 1)
    }

    func testLongPressIsNotATap() {
        let counters = BindingCounters()
        let binding = makeDoubleTapBinding(counters: counters)
        let manager = makeManager(bindings: [binding])

        tap(manager, hold: 1.0)
        XCTAssertFalse(manager.hasPendingDoubleTap(for: binding.bindingId))
        clock += 0.1
        tap(manager)
        XCTAssertEqual(counters.startCount, 0)
    }

    func testTypingBetweenTapsCancelsTheFirstTap() {
        let counters = BindingCounters()
        let binding = makeDoubleTapBinding(counters: counters)
        let manager = makeManager(bindings: [binding])

        tap(manager)
        manager.simulateRegularKeyDown(keyCode: 0)
        XCTAssertFalse(manager.hasPendingDoubleTap(for: binding.bindingId))
        clock += 0.1
        tap(manager)
        XCTAssertEqual(counters.startCount, 0)
    }

    func testOptionComboBetweenTapsCancelsTheFirstTap() {
        let counters = BindingCounters()
        let binding = makeDoubleTapBinding(counters: counters)
        let manager = makeManager(bindings: [binding])

        tap(manager)
        let comboFlags: CGEventFlags = [.maskAlternate, .maskShift]
        manager.simulateModifierFlags(.maskAlternate, rawFlags: rightOptionRaw, keyCode: rightOption)
        manager.simulateModifierFlags(
            comboFlags,
            rawFlags: comboFlags.rawValue | ModeBinding.deviceRightOptionMask | ModeBinding.deviceLeftShiftMask,
            keyCode: 56
        )
        manager.simulateModifierFlags([], rawFlags: 0, keyCode: rightOption)
        XCTAssertFalse(manager.hasPendingDoubleTap(for: binding.bindingId))

        clock += 0.1
        tap(manager)
        XCTAssertEqual(counters.startCount, 0)
    }

    func testIntervalCanBeOverridden() {
        UserDefaults.standard.set(0.8, forKey: HotkeyManager.doubleTapIntervalKey)
        let counters = BindingCounters()
        let manager = makeManager(bindings: [makeDoubleTapBinding(counters: counters)])

        tap(manager)
        clock += 0.6
        tap(manager)
        XCTAssertEqual(counters.startCount, 1)
    }

    // MARK: - Persistence

    func testDoubleTapIsStoredAsToggleWithFlag() throws {
        let binding = HotkeyBinding(keyCode: 61, modifiers: 0, style: .doubleTap)
        let data = try JSONEncoder().encode(binding)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(json["style"] as? String, "toggle")
        XCTAssertEqual(json["doubleTap"] as? Bool, true)
        XCTAssertEqual(try JSONDecoder().decode(HotkeyBinding.self, from: data), binding)
    }

    func testBindingsWithoutFlagDecodeUnchanged() throws {
        for style in [ProcessingMode.HotkeyStyle.hold, .toggle] {
            let binding = HotkeyBinding(keyCode: 63, modifiers: 0, style: style)
            let data = try JSONEncoder().encode(binding)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertNil(json["doubleTap"])
            XCTAssertEqual(try JSONDecoder().decode(HotkeyBinding.self, from: data).style, style)
        }

        let legacy = #"{"id":"6F1D2B6C-6C55-4D2F-9C55-1F0B0B7C2A11","keyCode":63,"modifiers":0,"style":"hold"}"#
        XCTAssertEqual(try JSONDecoder().decode(HotkeyBinding.self, from: Data(legacy.utf8)).style, .hold)
    }

    func testDoubleTapIsNeverTheGlobalDefault() {
        let key = "tf_defaultHotkeyStyle"
        let previous = UserDefaults.standard.object(forKey: key)
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        UserDefaults.standard.set("doubleTap", forKey: key)
        XCTAssertEqual(ProcessingMode.defaultHotkeyStyle, .toggle)
    }

    // MARK: - Availability & settings

    func testDoubleTapIsOnlyAvailableForModifierKeys() {
        XCTAssertTrue(ProcessingMode.HotkeyStyle.isAvailable(.doubleTap, forKeyCode: 61))
        XCTAssertTrue(ProcessingMode.HotkeyStyle.isAvailable(.doubleTap, forKeyCode: 63))
        XCTAssertFalse(ProcessingMode.HotkeyStyle.isAvailable(.doubleTap, forKeyCode: 49))
        XCTAssertFalse(ProcessingMode.HotkeyStyle.isAvailable(.doubleTap, forKeyCode: nil))
        XCTAssertTrue(ProcessingMode.HotkeyStyle.isAvailable(.toggle, forKeyCode: 49))
    }

    func testApplyBindingFallsBackToToggleForRegularKeys() {
        let modeId = UUID()
        var modes = [ProcessingMode(id: modeId, name: "M", prompt: "", isBuiltin: false, processingLabel: "")]
        let target = RecordingTarget(
            modeId: modeId, modeName: "M", editingBindingId: nil,
            initialKeyCode: nil, initialModifiers: nil, initialStyle: .toggle
        )

        ModeHotkeyEditing.applyBinding(keyCode: 49, modifiers: 0, style: .doubleTap, to: &modes, for: target)
        ModeHotkeyEditing.applyBinding(keyCode: 61, modifiers: 0, style: .doubleTap, to: &modes, for: target)

        XCTAssertEqual(modes[0].hotkeyBindings.map(\.style), [.toggle, .doubleTap])
    }

    func testStyleOptionsOfferDoubleTapInBothLanguages() {
        UserDefaults.standard.set("zh", forKey: "tf_language")
        XCTAssertEqual(HotkeyRecordingSheet.styleOptions(forKeyCode: 61).map(\.label), ["按住录制", "按下切换", "双击触发"])
        XCTAssertEqual(HotkeyRecordingSheet.styleOptions(forKeyCode: 49).map(\.label), ["按住录制", "按下切换"])

        UserDefaults.standard.set("en", forKey: "tf_language")
        XCTAssertEqual(HotkeyRecordingSheet.styleOptions(forKeyCode: 61).map(\.label), ["Hold to record", "Toggle", "Double-tap"])
        XCTAssertEqual(HotkeyRecordingSheet.styleOptions(forKeyCode: 61).map(\.value), ["hold", "toggle", "doubleTap"])
    }
}
