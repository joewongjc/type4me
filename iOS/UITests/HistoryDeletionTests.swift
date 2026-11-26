import XCTest

final class HistoryDeletionTests: XCTestCase {
    // Build with T4M_BUNDLE_ID_PREFIX=com.type4me.historytests. The app and
    // App Group then use separate containers before DemoSeed changes any data.
    private static let testAppID = "com.type4me.historytests.ios"

    func testSingleHistoryDeletionInEnglish() throws {
        try verifyDeletion(
            language: "en", action: "Delete dictation",
            title: "Delete this dictation?", cancel: "Cancel", delete: "Delete",
            removed: "Let's move tomorrow's 3 PM meeting to 4 and let the design team know.",
            retained: "I'm downstairs, you can just come down."
        )
    }

    func testSingleHistoryDeletionInChinese() throws {
        try verifyDeletion(
            language: "zh", action: "删除记录",
            title: "删除这条听写记录？", cancel: "取消", delete: "删除",
            removed: "我已经到楼下了，你直接下来就行。",
            retained: "明天下午 3 点的会改到 4 点，记得通知设计组。"
        )
    }

    private func verifyDeletion(
        language: String, action: String, title: String, cancel: String, delete: String,
        removed: String, retained: String
    ) throws {
        #if DEBUG && targetEnvironment(simulator)
        guard Bundle(for: Self.self).bundleIdentifier == Self.testAppID + ".uitests" else {
            throw XCTSkip("Build using T4M_BUNDLE_ID_PREFIX=com.type4me.historytests.")
        }
        let app = XCUIApplication(bundleIdentifier: Self.testAppID)
        app.launchEnvironment = ["T4M_DEMO": "1", "T4M_LANG": language, "T4M_RESEED": "1"]
        app.launch()

        let target = app.staticTexts[removed]
        let otherEntry = app.staticTexts[retained]
        let row = app.descendants(matching: .any).matching(identifier: "history-row")
            .containing(.staticText, identifier: removed).firstMatch
        let deleteButton = row.buttons[action]
        for _ in 0..<4 where !deleteButton.isHittable {
            app.scrollViews.firstMatch.swipeUp()
        }
        XCTAssertTrue(deleteButton.isHittable)

        deleteButton.tap()
        let alert = app.alerts[title]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.buttons[cancel].tap()
        XCTAssertTrue(target.exists)

        deleteButton.tap()
        alert.buttons[delete].tap()
        XCTAssertTrue(target.waitForNonExistence(timeout: 5))
        XCTAssertTrue(otherEntry.exists)

        app.terminate()
        app.launchEnvironment.removeValue(forKey: "T4M_RESEED")
        app.launch()
        XCTAssertFalse(target.exists)
        // The third seeded entry follows both deletion targets. Scroll to it
        // to cover their positions even when the first viewport is shorter.
        let thirdEntry = app.staticTexts["Let's hold this release until QA has gone through all the issues."]
        for _ in 0..<4 where !thirdEntry.isHittable {
            app.scrollViews.firstMatch.swipeUp(velocity: .slow)
            XCTAssertFalse(target.exists)
        }
        XCTAssertTrue(thirdEntry.isHittable)
        app.scrollViews.firstMatch.swipeDown(velocity: .fast)
        XCTAssertTrue(otherEntry.waitForExistence(timeout: 5))
        #else
        throw XCTSkip("History deletion fixtures require a Debug simulator build.")
        #endif
    }
}
