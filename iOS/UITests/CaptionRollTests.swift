import XCTest

/// Simulator pass for the keyboard's recording caption: a long locked demo
/// dictation so the transcript outgrows two lines and rolls up, then the
/// processing and done states. Screenshots only; not part of any CI gate.
final class CaptionRollTests: XCTestCase {
    func testSimCaptionRoll() throws {
        let app = XCUIApplication()
        app.launchEnvironment = ["T4M_DEMO": "1", "T4M_KEYBOARD_DEMO": "1", "T4M_TAB": "history"]
        app.launch()
        sleep(2)
        let field = app.textFields.firstMatch
        guard field.waitForExistence(timeout: 5) else { throw XCTSkip("No text field") }
        field.tap()
        let mic = app.descendants(matching: .any).matching(NSPredicate(format: "label == '按住说话' OR label == 'Hold to talk'")).firstMatch
        guard mic.waitForExistence(timeout: 4) else { throw XCTSkip("Type4Me keyboard not active") }
        sleep(1)
        // A quick tap locks recording on.
        mic.tap()
        for i in 0..<9 {
            sleep(2)
            snap(String(format: "roll-%02d", i))
        }
        // The caption is one accessibility element carrying the transcript.
        let caption = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH '明天' OR label BEGINSWITH 'Move'")).firstMatch
        XCTAssertTrue(caption.exists, "Caption should expose the live transcript")
        // Scroll back to read earlier lines; arriving words must not pull
        // the view down again.
        let middle = caption.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        middle.press(forDuration: 0.05, thenDragTo: middle.withOffset(CGVector(dx: 0, dy: 60)))
        usleep(500_000)
        snap("roll-scrolled")
        sleep(2)
        snap("roll-scrolled-later")
        let stop = app.descendants(matching: .any).matching(NSPredicate(format: "label == '结束说话' OR label == 'Finish talking'")).firstMatch
        XCTAssertTrue(stop.exists)
        stop.tap()
        usleep(400_000)
        snap("roll-processing")
        sleep(2)
        snap("roll-done")
    }

    private func snap(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
