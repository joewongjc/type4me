import XCTest
@testable import Type4Me

/// #295. The Dev app is a long-running dogfooding channel, so it shares the
/// user's profile with production, while per-app runtime state is kept apart and
/// tests are isolated from both.
final class AppDataLocationTests: XCTestCase {

    // MARK: - Profile

    /// Existing installs must keep the directory they already have. Renaming it
    /// would make every user look like they had lost everything.
    func testSharedProfileKeepsItsHistoricalName() {
        XCTAssertEqual(AppDataLocation.sharedProfileName, "Type4Me")
        XCTAssertEqual(AppDataLocation.profileDirectoryName(isTesting: false), "Type4Me")
    }

    /// Dogfooding is only meaningful against the same accumulated data, so the
    /// profile does not depend on which build is running at all.
    func testProductionAndDevShareOneProfile() {
        let production = AppDataLocation.profileDirectoryName(isTesting: false)
        XCTAssertEqual(production, AppDataLocation.sharedProfileName)
        XCTAssertNotEqual(production, AppDataLocation.devRuntimeName)
    }

    // MARK: - Runtime

    func testDevRuntimeIsKeptApartFromProduction() {
        let production = AppDataLocation.runtimeDirectoryName(
            bundleID: AppDataLocation.productionBundleID, isTesting: false
        )
        let dev = AppDataLocation.runtimeDirectoryName(
            bundleID: AppDataLocation.devBundleID, isTesting: false
        )
        XCTAssertEqual(dev, "Type4Me Dev")
        XCTAssertNotEqual(production, dev)
    }

    /// Production's runtime files stay where existing installs already have them
    /// — including the PID file used to stop an orphaned local ASR server.
    func testProductionRuntimeStaysWhereExistingInstallsHaveIt() {
        XCTAssertEqual(
            AppDataLocation.runtimeDirectoryName(bundleID: AppDataLocation.productionBundleID, isTesting: false),
            AppDataLocation.sharedProfileName
        )
    }

    /// An unrecognised build keeps working against the files it already has
    /// rather than silently starting over in an empty directory.
    func testUnknownBundleIsTreatedAsProduction() {
        for bundleID in [nil, "", "com.example.something", "com.type4me.app.debug"] {
            XCTAssertEqual(
                AppDataLocation.runtimeDirectoryName(bundleID: bundleID, isTesting: false),
                AppDataLocation.sharedProfileName,
                "unexpected runtime directory for \(bundleID ?? "nil")"
            )
        }
    }

    // MARK: - Tests

    func testTestsAreIsolatedFromBothProfileAndRuntime() {
        XCTAssertEqual(AppDataLocation.profileDirectoryName(isTesting: true), "Type4MeTests")
        for bundleID in [AppDataLocation.productionBundleID, AppDataLocation.devBundleID, nil] {
            XCTAssertEqual(
                AppDataLocation.runtimeDirectoryName(bundleID: bundleID, isTesting: true),
                "Type4MeTests"
            )
        }
    }

    /// The suite itself is the proof: every store resolves through this type, so
    /// a test run must not be pointing at the user's directories.
    func testTheRunningSuiteNeverResolvesToTheUsersDirectories() {
        XCTAssertEqual(AppDataLocation.profileDirectoryName, "Type4MeTests")
        XCTAssertEqual(AppDataLocation.runtimeDirectoryName, "Type4MeTests")
        XCTAssertNotEqual(AppDataLocation.profileDirectory.lastPathComponent, AppDataLocation.sharedProfileName)
        XCTAssertNotEqual(AppDataLocation.runtimeDirectory.lastPathComponent, AppDataLocation.devRuntimeName)
    }

    // MARK: - Stores

    /// Profile stores move with the profile, credentials included, so secure
    /// fields in the Keychain and file-backed fields in `credentials.json` are
    /// shared or isolated together instead of half and half.
    func testProfileStoresResolveToTheProfileDirectory() {
        let profile = AppDataLocation.profileDirectory.standardizedFileURL.path
        for url in [
            SnippetStorage.userFileURL,
            HotwordStorage.userFileURL,
            KeychainService.credentialsFileURL,
            LLMPricingSyncService.defaultCacheFileURL,
        ] {
            XCTAssertTrue(
                url.standardizedFileURL.path.hasPrefix(profile + "/"),
                "\(url.lastPathComponent) is not under the profile directory"
            )
        }
    }

    /// Backups follow the profile they protect: they are a sibling of it, and a
    /// test run can never snapshot or rotate the user's real backups.
    func testDataBackupsFollowTheProfile() {
        let profile = AppDataLocation.profileDirectory.standardizedFileURL
        XCTAssertEqual(DataBackupManager.dataDirectory.standardizedFileURL, profile)
        XCTAssertEqual(
            DataBackupManager.backupRoot.standardizedFileURL,
            profile.deletingLastPathComponent().appendingPathComponent("Type4MeTests Backups").standardizedFileURL
        )
    }

    /// Under test profile and runtime both resolve to the isolated directory, so
    /// this cannot tell one from the other — the resolution tests above cover
    /// that. What it does prove is that the logger goes through AppDataLocation at
    /// all: a hardcoded path would resolve to the user's real directory.
    func testRuntimeStateResolvesThroughTheRuntimeDirectory() {
        let runtime = AppDataLocation.runtimeDirectory.standardizedFileURL.path
        XCTAssertTrue(
            DebugFileLogger.logURL.standardizedFileURL.path.hasPrefix(runtime + "/"),
            "debug.log is not under the runtime directory"
        )
    }
}
