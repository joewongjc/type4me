import XCTest
@testable import Type4Me

final class ReviseSettingsTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ReviseSettingsTests_\(UUID().uuidString)"
        )
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        try super.tearDownWithError()
    }

    func testDefaultSettings() throws {
        let fileURL = tempDirectory.appendingPathComponent("revise-settings.json")
        let store = ReviseSettingsStore(fileURL: fileURL, userDefaultsSuiteName: UUID().uuidString)

        let settings = store.load()
        XCTAssertTrue(settings.enabled)
        XCTAssertNotNil(settings.hotkey)
        XCTAssertEqual(settings.hotkey?.keyCode, ReviseSettings.defaultKeyCode)
        XCTAssertTrue(settings.excludedApps.isEmpty)
    }

    func testSaveAndLoadSettings() throws {
        let fileURL = tempDirectory.appendingPathComponent("revise-settings.json")
        let store = ReviseSettingsStore(fileURL: fileURL, userDefaultsSuiteName: UUID().uuidString)

        var settings = store.load()
        settings.enabled = false
        settings.excludedApps = [
            ReviseExcludedApp(bundleIdentifier: "com.apple.Terminal", displayName: "Terminal"),
            ReviseExcludedApp(bundleIdentifier: "com.apple.Terminal", displayName: "Terminal Dup"),
        ]

        let saved = try store.save(settings)
        XCTAssertFalse(saved.enabled)
        XCTAssertEqual(saved.excludedApps.count, 1)
        XCTAssertEqual(saved.excludedApps[0].bundleIdentifier, "com.apple.Terminal")

        store.invalidateCache()
        let loaded = store.load()
        XCTAssertFalse(loaded.enabled)
        XCTAssertEqual(loaded.excludedApps.count, 1)
        XCTAssertTrue(loaded.isExcluded(bundleIdentifier: "com.apple.Terminal"))
        XCTAssertFalse(loaded.isExcluded(bundleIdentifier: "com.apple.Notes"))
    }
}
