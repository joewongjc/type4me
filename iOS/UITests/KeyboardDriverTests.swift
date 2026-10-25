import XCTest

/// Drives the real keyboard on a device for visual checks: opens Notes,
/// switches to Type4Me, dictates a recorded sentence fed in place of the mic samples (nothing plays aloud) and
/// attaches screenshots of every phase. Not part of any CI gate.
final class KeyboardDriverTests: XCTestCase {
    private let notes = XCUIApplication(bundleIdentifier: "com.apple.mobilenotes")

    override func setUp() {
        continueAfterFailure = true
    }

    func testDictation() throws {
        let app = XCUIApplication()
        // Recorded speech replaces the mic samples, so nothing plays aloud.
        app.launchEnvironment["T4M_FAKE_SPEECH"] = "fake-speech.pcm"
        app.launch()
        sleep(3)
        snap("app-home")
        let gear = app.buttons["设置"]
        if gear.waitForExistence(timeout: 3) {
            gear.tap()
            sleep(1)
            snap("app-settings")
            let back = app.navigationBars.buttons.element(boundBy: 0)
            if back.waitForExistence(timeout: 3) { back.tap() }
            sleep(1)
        }
        // Scroll only inside the app's own scroll view; screen-edge swipes
        // can switch apps.
        let scroll = app.scrollViews.firstMatch
        if scroll.exists {
            scroll.swipeUp(velocity: .slow)
            sleep(1)
            snap("app-home-2")
        }

        notes.activate()
        XCTAssertTrue(notes.wait(for: .runningForeground, timeout: 10))
        sleep(2)
        openEditableNote()
        let mic = try ensureType4MeKeyboard()
        sleep(1)
        snap("01-idle")

        // A quick tap locks recording on.
        mic.tap()
        usleep(250_000)
        snap("02-listening")
        usleep(600_000)
        snap("03-listening")

        for index in 0..<12 {
            usleep(500_000)
            snap(String(format: "04-speaking-%02d", index))
        }
        sleep(2)
        snap("05-before-finish")

        let stop = notes.descendants(matching: .any).matching(NSPredicate(format: "label == '结束说话' OR label == 'Finish talking'")).firstMatch
        stop.tap()
        usleep(150_000)
        snap("06-processing")
        for index in 0..<6 {
            usleep(400_000)
            snap(String(format: "07-after-%02d", index))
        }
        sleep(2)
        snap("08-final")

        // Hold to talk, then slide left to cancel; the screen recording
        // captures the gesture states.
        let idleMic = notes.descendants(matching: .any).matching(NSPredicate(format: "label == '按住说话' OR label == 'Hold to talk'")).firstMatch
        let center = idleMic.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        center.press(forDuration: 3.0, thenDragTo: center.withOffset(CGVector(dx: -110, dy: 0)))
        sleep(2)
        // Hold to talk and release to insert.
        center.press(forDuration: 4.0)
        sleep(5)
        snap("09-hold-result")

        // Lock, then cancel with the key that stands in for undo.
        idleMic.tap()
        sleep(2)
        snap("09b-locked")
        let cancelKey = notes.buttons.matching(NSPredicate(format: "label CONTAINS '取消' OR label CONTAINS 'Cancel'")).firstMatch
        if cancelKey.exists { cancelKey.tap() }
        sleep(1)
        snap("09c-cancelled")

        let original = XCUIDevice.shared.appearance
        XCUIDevice.shared.appearance = .dark
        sleep(2)
        snap("10-dark-idle")
        idleMic.tap()
        sleep(3)
        snap("11-dark-recording")
        notes.descendants(matching: .any).matching(NSPredicate(format: "label == '结束说话' OR label == 'Finish talking'")).firstMatch.tap()
        usleep(300_000)
        snap("12-dark-processing")
        sleep(3)
        XCUIDevice.shared.appearance = original == .unspecified ? .light : original
        deleteCurrentNote()
        // Xcode only keeps the screen recording of failed tests, and the
        // recording is the point of this driver.
        XCTFail("intentional: keep the screen recording")
    }

    /// Removes the notes earlier runs left behind. Only notes containing the
    /// test sentence are touched, and Notes keeps them in Recently Deleted.
    func testCleanupNotes() throws {
        notes.activate()
        sleep(2)
        let cancelSearch = notes.buttons.matching(NSPredicate(format: "label == '取消' OR label == 'Cancel' OR label == '关闭'")).firstMatch
        if cancelSearch.exists { cancelSearch.tap(); sleep(1) }
        for _ in 0..<6 {
            let back = notes.buttons["BackButton"]
            if back.exists { back.tap(); sleep(1) } else { break }
        }
        let all = notes.cells.containing(NSPredicate(format: "label CONTAINS '全部备忘录' OR label CONTAINS 'All iCloud'")).firstMatch
        if all.waitForExistence(timeout: 2) { all.tap(); sleep(2) }
        // No screenshots here: the list shows the user's own notes.
        let predicate = NSPredicate(format: "label CONTAINS '会议室讨论一下新版本'")
        print("CLEANUP matches=\(notes.cells.containing(predicate).count) cells=\(notes.cells.count) nav=\(notes.navigationBars.firstMatch.identifier)")
        for label in notes.cells.allElementsBoundByIndex.prefix(12).map(\.label) where label.contains("下午") || label.contains("会议") {
            print("CLEANUP candidate: \(label.prefix(40))")
        }
        var deleted = 0
        for _ in 0..<20 {
            let cell = notes.cells.containing(predicate).firstMatch
            guard cell.exists else { break }
            cell.swipeLeft()
            sleep(1)
            let delete = notes.buttons.matching(NSPredicate(format: "label == '删除' OR label == 'Delete'")).firstMatch
            guard delete.waitForExistence(timeout: 2) else { break }
            delete.tap()
            deleted += 1
            sleep(1)
        }
        print("CLEANUP deleted=\(deleted)")
    }

    // MARK: Simulator

    /// Adds Type4Me with Full Access in a simulator's Settings.
    func testSimEnableKeyboard() throws {
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        settings.terminate()
        settings.activate()
        func tap(_ labels: [String], timeout: TimeInterval = 4) -> Bool {
            for label in labels {
                let e = settings.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
                if e.waitForExistence(timeout: timeout) {
                    if !e.isHittable { settings.swipeUp(velocity: .slow) }
                    e.tap(); sleep(1); return true
                }
            }
            print("SIM missing \(labels)\n\(settings.debugDescription.prefix(4000))")
            return false
        }
        guard tap(["General", "通用"]), tap(["Keyboard", "键盘"]) else { return }
        let keyboards = settings.cells["KEYBOARDS"]
        guard keyboards.waitForExistence(timeout: 4) else { return }
        keyboards.tap()
        sleep(1)
        if !settings.staticTexts["Type4Me"].exists {
            let add = settings.cells.matching(NSPredicate(format: "label BEGINSWITH '添加新键盘' OR label BEGINSWITH 'Add New Keyboard'")).firstMatch
            for _ in 0..<3 where !add.exists { settings.swipeUp(velocity: .slow) }
            guard add.waitForExistence(timeout: 3) else {
                print("SIM cells: \(settings.cells.allElementsBoundByIndex.map(\.label))")
                return
            }
            add.tap()
            sleep(2)
            let item = settings.cells.matching(NSPredicate(format: "label BEGINSWITH 'Type4Me'")).firstMatch
            for _ in 0..<4 where !item.exists { settings.swipeUp(velocity: .slow) }
            guard item.waitForExistence(timeout: 3) else {
                print("SIM add list: \(settings.cells.allElementsBoundByIndex.prefix(40).map(\.label))")
                return
            }
            item.tap()
            sleep(2)
        }
        let mine = settings.cells.matching(NSPredicate(format: "label BEGINSWITH 'Type4Me'")).firstMatch
        guard mine.waitForExistence(timeout: 3) else { return }
        mine.tap()
        sleep(1)
        let toggle = settings.switches.firstMatch
        if toggle.waitForExistence(timeout: 3), (toggle.value as? String) != "1" {
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
            sleep(2)
            let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            for scope in [settings, springboard] {
                let allow = scope.buttons.matching(NSPredicate(format: "label == '允许' OR label == 'Allow'")).firstMatch
                if allow.exists { allow.tap(); break }
            }
            sleep(1)
        }
        snap("sim-keyboard-enabled")
    }

    /// Simulator keyboard pass with the scripted demo dictation.
    func testSimKeyboard() throws {
        let app = XCUIApplication()
        app.launchEnvironment = ["T4M_DEMO": "1", "T4M_KEYBOARD_DEMO": "1", "T4M_TAB": "history"]
        app.launch()
        sleep(2)
        let search = app.textFields.firstMatch
        guard search.waitForExistence(timeout: 5) else { snap("no-search"); return }
        search.tap()
        sleep(1)
        let mic = app.descendants(matching: .any).matching(NSPredicate(format: "label == '按住说话' OR label == 'Hold to talk'")).firstMatch
        if !mic.waitForExistence(timeout: 2) {
            let globe = app.buttons.matching(NSPredicate(format: "label == 'Next keyboard' OR label == '下一个键盘'")).firstMatch
            if globe.exists {
                globe.press(forDuration: 1.2)
                sleep(1)
                let item = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Type4Me'")).firstMatch
                if item.exists { item.tap() }
            }
        }
        guard mic.waitForExistence(timeout: 3) else { snap("sim-no-keyboard"); print("SIMTREE\n\(app.debugDescription)"); return }
        sleep(1)
        snap("k01-idle")
        print("MARK recording")
        mic.tap()
        for i in 0..<6 { usleep(700_000); snap(String(format: "k02-rec-%02d", i)) }
        let stop = app.descendants(matching: .any).matching(NSPredicate(format: "label == '结束说话' OR label == 'Finish talking'")).firstMatch
        stop.tap()
        usleep(300_000)
        snap("k03-processing")
        sleep(2)
        snap("k04-done")
        sleep(2)
        snap("k05-idle-after")

        XCUIDevice.shared.appearance = .dark
        sleep(2)
        snap("k06-dark-idle")
        mic.tap()
        sleep(3)
        snap("k07-dark-rec")
        stop.tap()
        usleep(400_000)
        snap("k08-dark-processing")
        sleep(2)
        XCUIDevice.shared.appearance = .light
    }

    func testSimDarkKeyboard() throws {
        XCUIDevice.shared.appearance = .dark
        let app = XCUIApplication()
        app.launchEnvironment = ["T4M_DEMO": "1", "T4M_KEYBOARD_DEMO": "1", "T4M_TAB": "history"]
        app.launch()
        sleep(2)
        app.textFields.firstMatch.tap()
        sleep(2)
        snap("dk-idle")
        let mic = app.descendants(matching: .any).matching(NSPredicate(format: "label == '按住说话' OR label == 'Hold to talk'")).firstMatch
        if mic.exists { mic.tap() }
        sleep(3)
        snap("dk-rec")
        app.descendants(matching: .any).matching(NSPredicate(format: "label == '结束说话' OR label == 'Finish talking'")).firstMatch.tap()
        usleep(500_000)
        snap("dk-processing")
        sleep(3)
        XCUIDevice.shared.appearance = .light
    }

    /// System in English; switch the app to 中文 in Settings, check the app
    /// and the keyboard, then put it back to System.
    func testSimLanguageSwitch() throws {
        let app = XCUIApplication()
        app.launchEnvironment = ["T4M_DEMO": "1", "T4M_KEYBOARD_DEMO": "1", "T4M_TAB": "settings", "T4M_LANG": "system"]
        app.launch()
        sleep(2)
        func pick(_ option: String) {
            let picker = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Language' OR label BEGINSWITH '语言'")).firstMatch
            for _ in 0..<4 where !(picker.exists && picker.isHittable) {
                app.swipeUp(velocity: .slow)
                sleep(1)
            }
            if !picker.exists {
                print("LANG buttons: \(app.buttons.allElementsBoundByIndex.map(\.label))")
            }
            picker.tap()
            sleep(1)
            app.buttons.matching(NSPredicate(format: "label == %@", option)).firstMatch.tap()
            sleep(2)
        }
        pick("中文")
        snap("lang-zh-settings")
        app.buttons.matching(NSPredicate(format: "label == '历史'")).firstMatch.tap()
        sleep(1)
        app.textFields.firstMatch.tap()
        sleep(2)
        snap("lang-zh-keyboard")
        // The keyboard covers the tab bar; scrolling History dismisses it.
        app.scrollViews.firstMatch.swipeDown(velocity: .slow)
        sleep(1)
        app.buttons.matching(NSPredicate(format: "label == '设置'")).firstMatch.tap()
        sleep(1)
        pick("跟随系统")
        snap("lang-system-settings")
    }

    /// Onboarding try-it page: bring up Type4Me, then put it away with the
    /// keyboard's own key, then again by tapping outside.
    func testSimOnboardingTry() throws {
        let app = XCUIApplication()
        app.launchEnvironment = ["T4M_STEP": "2"]
        app.launch()
        sleep(2)
        snap("o-try")
        let field = app.textFields.firstMatch.exists ? app.textFields.firstMatch : app.textViews.firstMatch
        field.tap()
        sleep(1)
        let mic = app.descendants(matching: .any).matching(NSPredicate(format: "label == '按住说话' OR label == 'Hold to talk'")).firstMatch
        if !mic.waitForExistence(timeout: 2) {
            let globe = app.buttons.matching(NSPredicate(format: "label == 'Next keyboard' OR label == '下一个键盘'")).firstMatch
            if globe.exists {
                globe.press(forDuration: 1.2)
                sleep(1)
                app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Type4Me'")).firstMatch.tap()
            }
        }
        sleep(2)
        snap("o-try-keyboard")
        let hideKey = app.descendants(matching: .any)["keyboard.hide"]
        print("HIDEKEY exists=\(hideKey.exists)")
        hideKey.tap()
        sleep(2)
        print("AFTER_KEY keyboard visible=\(mic.exists)")
        snap("o-try-hidden-by-key")
        field.tap()
        sleep(2)
        print("REOPEN keyboard visible=\(mic.exists) appButton=\(app.buttons["onboarding.hideKeyboard"].exists)")
        app.staticTexts.matching(NSPredicate(format: "label == '试一试' OR label == 'Try It'")).firstMatch.tap()
        sleep(2)
        print("AFTER_TAP_OUTSIDE keyboard visible=\(mic.exists)")
        snap("o-try-hidden-by-tap")
    }

    /// Settings, the speech and text model pages, and the mode editors.
    func testSimSettingsPages() throws {
        let app = XCUIApplication()
        app.launchEnvironment = ["T4M_DEMO": "1", "T4M_TAB": "settings"]
        app.launch()
        sleep(2)
        snap("s1-settings")
        // Never fail here: a failed UI test leaves xcodebuild hanging.
        func open(_ label: String) {
            let predicate = NSPredicate(format: "label BEGINSWITH %@", label)
            let item = app.buttons.matching(predicate).firstMatch.exists
                ? app.buttons.matching(predicate).firstMatch
                : app.cells.matching(predicate).firstMatch
            for _ in 0..<4 where !(item.exists && item.isHittable) { app.swipeUp(velocity: .slow) }
            guard item.exists else { print("OPEN missing \(label)"); return }
            item.tap()
            sleep(1)
        }
        func back() {
            let button = app.navigationBars.buttons.element(boundBy: 0)
            if button.exists { button.tap() }
            sleep(1)
        }
        open("识别服务"); snap("s2-asr"); back()
        open("处理模型"); snap("s3-llm"); back()
        app.swipeUp(velocity: .slow); sleep(1)
        snap("s4-settings-lower")
        open("模式"); snap("s5-modes")
        open("智能感知"); snap("s6-intellisense"); back()
        open("快速"); snap("s7-quick"); back()
        open("翻译"); snap("s8-translate"); back()
        let new = app.buttons.matching(NSPredicate(format: "label CONTAINS '新建模式'")).firstMatch
        for _ in 0..<3 where !(new.exists && new.isHittable) { app.swipeUp(velocity: .slow) }
        if new.exists { new.tap() }
        sleep(1)
        snap("s9-new-mode")
    }

    /// Fake scan of five cycling codes, then the import page and the result.
    func testSimSyncFlow() throws {
        let app = XCUIApplication()
        app.launchEnvironment = ["T4M_DEMO": "1", "T4M_TAB": "settings", "T4M_SCAN_FILE": "sync-frames.txt"]
        app.launch()
        usleep(1_200_000); snap("y1-scan-1")
        usleep(900_000); snap("y2-scan-2")
        sleep(3)
        snap("y3-import")
        app.swipeUp(velocity: .slow); sleep(1)
        snap("y4-import-lower")
        let sync = app.buttons.matching(NSPredicate(format: "label CONTAINS '同步所选' OR label CONTAINS 'Sync Selected'")).firstMatch
        if sync.exists { sync.tap() }
        sleep(2)
        let modes = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '模式'")).firstMatch
        for _ in 0..<4 where !(modes.exists && modes.isHittable) { app.swipeUp(velocity: .slow) }
        if modes.exists { modes.tap() }
        sleep(1)
        snap("y5-modes-after")
    }

    func testSimGestures() throws {
        let app = XCUIApplication()
        app.launchEnvironment = ["T4M_DEMO": "1", "T4M_KEYBOARD_DEMO": "1", "T4M_TAB": "history"]
        app.launch()
        sleep(2)
        app.textFields.firstMatch.tap()
        sleep(1)
        let mic = app.descendants(matching: .any).matching(NSPredicate(format: "label == '按住说话' OR label == 'Hold to talk'")).firstMatch
        guard mic.waitForExistence(timeout: 3) else { return }
        let center = mic.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        print("MARK hold-cancel")
        center.press(forDuration: 2.0, thenDragTo: center.withOffset(CGVector(dx: -120, dy: 0)), withVelocity: .slow, thenHoldForDuration: 1.0)
        sleep(2)
        print("MARK hold-lock")
        center.press(forDuration: 2.0, thenDragTo: center.withOffset(CGVector(dx: 0, dy: -90)), withVelocity: .slow, thenHoldForDuration: 1.0)
        sleep(2)
        snap("g-locked")
        app.buttons.matching(NSPredicate(format: "label CONTAINS '取消' OR label CONTAINS 'Cancel'")).firstMatch.tap()
        sleep(1)
        print("MARK hold-release")
        center.press(forDuration: 3.0)
        sleep(3)
        snap("g-after")
    }

    func testSimScrollHitches() throws {
        let app = XCUIApplication()
        app.launchEnvironment = ["T4M_DEMO": "1"]
        app.launch()
        sleep(2)
        let scroll = app.scrollViews.firstMatch
        let options = XCTMeasureOptions()
        options.iterationCount = 3
        measure(metrics: [XCTOSSignpostMetric.scrollingAndDecelerationMetric], options: options) {
            scroll.swipeUp(velocity: .fast)
            scroll.swipeDown(velocity: .fast)
        }
    }

    /// Home scroll, import sheets and the history push for the screen recording.
    func testSimApp() throws {
        let app = XCUIApplication()
        app.launchEnvironment = ["T4M_DEMO": "1"]
        app.launch()
        sleep(2)
        snap("a01-home")
        let scroll = app.scrollViews.firstMatch
        print("MARK scroll")
        scroll.swipeUp(velocity: .fast)
        sleep(1)
        snap("a02-home-bottom")
        scroll.swipeDown(velocity: .fast)
        sleep(1)
        app.buttons.matching(NSPredicate(format: "label CONTAINS '扫码' OR label CONTAINS 'Scan'")).firstMatch.tap()
        sleep(1)
        snap("a03-scanner")
        app.buttons.matching(NSPredicate(format: "label == '取消' OR label == 'Cancel' OR label == 'Close' OR label == '关闭'")).firstMatch.tap()
        sleep(1)
        app.buttons.matching(NSPredicate(format: "label CONTAINS '粘贴配置' OR label CONTAINS 'Paste Setup'")).firstMatch.tap()
        sleep(1)
        let allowPaste = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons.matching(NSPredicate(format: "label CONTAINS '允许' OR label CONTAINS 'Allow'")).firstMatch
        if allowPaste.waitForExistence(timeout: 1) { allowPaste.tap(); sleep(1) }
        snap("a04-import")
    }

    // MARK: Helpers

    /// Deletes the note this run typed into (it goes to Recently Deleted).
    private func deleteCurrentNote() {
        let more = notes.buttons["更多"]
        guard more.waitForExistence(timeout: 2) else { return }
        more.tap()
        sleep(1)
        let delete = notes.buttons.matching(NSPredicate(format: "label == '删除' OR label == 'Delete'")).firstMatch
        if delete.waitForExistence(timeout: 2) {
            delete.tap()
            print("NOTE deleted")
        } else {
            print("NOTE MENU TREE\n\(notes.debugDescription)")
        }
        sleep(1)
    }

    private func openEditableNote() {
        let cancelSearch = notes.buttons.matching(NSPredicate(format: "label == '取消' OR label == 'Cancel'")).firstMatch
        if cancelSearch.exists { cancelSearch.tap(); sleep(1) }
        let compose = notes.buttons["New note"]
        if !compose.waitForExistence(timeout: 2) {
            let all = notes.cells.containing(NSPredicate(format: "label CONTAINS '全部备忘录'")).firstMatch
            if all.exists { all.tap(); sleep(1) }
        }
        if !compose.exists {
            print("NOTES BUTTONS: \(notes.buttons.allElementsBoundByIndex.prefix(30).map { "\($0.identifier)|\($0.label)" })")
        }
        if compose.waitForExistence(timeout: 3) {
            compose.tap()
        } else {
            let alt = notes.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'note' OR label CONTAINS '新建'")).firstMatch
            if alt.exists { alt.tap() }
        }
        sleep(2)
        if notes.keyboards.count == 0 {
            notes.textViews.firstMatch.tap()
            sleep(1)
        }
    }

    private func ensureType4MeKeyboard() throws -> XCUIElement {
        let mic = notes.descendants(matching: .any).matching(NSPredicate(format: "label == '按住说话' OR label == 'Hold to talk'")).firstMatch
        let globe = notes.buttons.matching(NSPredicate(format: "label == 'Next keyboard' OR label == '下一个键盘'")).firstMatch
        if mic.waitForExistence(timeout: 1.5) { return mic }
        if globe.exists {
            // Third-party keyboards are not in the tap cycle during UI tests;
            // pick it from the long-press list instead.
            globe.press(forDuration: 1.2)
            sleep(1)
            snap("globe-menu")
            let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            for scope in [notes, springboard] {
                let item = scope.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Type4Me'")).firstMatch
                if item.exists {
                    item.tap()
                    break
                }
            }
            if mic.waitForExistence(timeout: 3) { return mic }
            print("AFTER MENU\n\(notes.debugDescription)")
        }
        snap("keyboard-missing")
        print("TREE\n\(notes.debugDescription)")
        throw XCTSkip("Type4Me keyboard not found")
    }

    private func snap(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
