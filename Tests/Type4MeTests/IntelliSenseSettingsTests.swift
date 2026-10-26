import XCTest
@testable import Type4Me
@testable import Type4MeIntelliSenseCore

final class IntelliSenseSettingsTests: XCTestCase {
    private func makeDefaults() -> (UserDefaults, String) {
        let suite = "Type4MeTests.IntelliSenseSettings.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (defaults, suite)
    }

    private func makeURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("intelli-sense-settings-\(UUID().uuidString).json")
    }

    func testDefaultsAreAllDisabled() async {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let url = makeURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let settings = await IntelliSenseSettingsStore(
            fileURL: url,
            userDefaultsSuiteName: suite
        ).load()

        XCTAssertFalse(settings.applicationAwarenessEnabled)
        XCTAssertFalse(settings.contextAwarenessEnabled)
        XCTAssertFalse(settings.correctionDetectionEnabled)
        XCTAssertFalse(settings.expressionLearningEnabled)
        XCTAssertTrue(settings.blacklistedApps.isEmpty)
    }

    func testLegacyCorrectionPreferenceMigratesOnce() async throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: IntelliSenseSettingsStore.legacyCorrectionDefaultsKey)
        let url = makeURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = IntelliSenseSettingsStore(fileURL: url, userDefaultsSuiteName: suite)

        let migrated = await store.load()
        defaults.set(false, forKey: IntelliSenseSettingsStore.legacyCorrectionDefaultsKey)
        await store.invalidateCache()
        let secondLoad = await store.load()

        XCTAssertTrue(migrated.correctionDetectionEnabled)
        XCTAssertTrue(secondLoad.correctionDetectionEnabled)
        XCTAssertTrue(defaults.bool(forKey: IntelliSenseSettingsStore.migrationDefaultsKey))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testSaveNormalizesBlacklistAndRoundTrips() async throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let url = makeURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = IntelliSenseSettingsStore(fileURL: url, userDefaultsSuiteName: suite)
        var settings = IntelliSenseSettings()
        settings.applicationAwarenessEnabled = true
        settings.blacklistedApps = [
            BlacklistedApp(bundleIdentifier: " com.example.App ", displayName: " Example "),
            BlacklistedApp(bundleIdentifier: "com.example.app", displayName: "Duplicate"),
            BlacklistedApp(bundleIdentifier: "", displayName: "Invalid"),
        ]

        let saved = try await store.save(settings)
        await store.invalidateCache()
        let reloaded = await store.load()

        XCTAssertEqual(saved.blacklistedApps, [
            BlacklistedApp(bundleIdentifier: "com.example.App", displayName: "Example")
        ])
        XCTAssertEqual(reloaded, saved)
    }

    func testCorruptFileFallsBackWithoutOverwritingIt() async throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let url = makeURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let original = Data("not-json".utf8)
        try original.write(to: url)

        let settings = await IntelliSenseSettingsStore(
            fileURL: url,
            userDefaultsSuiteName: suite
        ).load()

        XCTAssertEqual(settings, IntelliSenseSettings())
        XCTAssertEqual(try Data(contentsOf: url), original)
    }
}
