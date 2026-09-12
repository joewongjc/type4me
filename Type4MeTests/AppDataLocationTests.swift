import XCTest
@testable import Type4Me

/// #295. The app is not sandboxed, so the Dev build produced by
/// `scripts/dev-run.sh` shared the production user's history, vocabulary, modes
/// and credentials despite having its own bundle id.
final class AppDataLocationTests: XCTestCase {

    // MARK: - Resolution

    /// Existing installs must keep the directory they already have. Renaming it
    /// would make every user look like they had lost everything — the exact
    /// failure this change exists to prevent.
    func testProductionKeepsItsHistoricalDirectoryName() {
        XCTAssertEqual(AppDataLocation.productionDirectoryName, "Type4Me")
        XCTAssertEqual(
            AppDataLocation.directoryName(bundleID: AppDataLocation.productionBundleID, isTesting: false),
            "Type4Me"
        )
    }

    func testDevBuildIsMovedAside() {
        XCTAssertEqual(
            AppDataLocation.directoryName(bundleID: AppDataLocation.devBundleID, isTesting: false),
            "Type4Me Dev"
        )
    }

    func testTestsGetTheirOwnDirectoryRegardlessOfBundle() {
        for bundleID in [AppDataLocation.productionBundleID, AppDataLocation.devBundleID, nil] {
            XCTAssertEqual(
                AppDataLocation.directoryName(bundleID: bundleID, isTesting: true),
                "Type4MeTests"
            )
        }
    }

    /// Deliberately conservative. Polluting the production directory is
    /// recoverable; sending a renamed production build to a fresh directory
    /// would silently hide every user's data.
    func testUnknownBundleFallsBackToProductionRatherThanAFreshDirectory() {
        for bundleID in [nil, "", "com.example.something", "com.type4me.app.debug"] {
            XCTAssertEqual(
                AppDataLocation.directoryName(bundleID: bundleID, isTesting: false),
                AppDataLocation.productionDirectoryName,
                "unexpected isolation for \(bundleID ?? "nil")"
            )
        }
    }

    func testProductionAndDevNeverResolveToTheSameDirectory() {
        XCTAssertNotEqual(
            AppDataLocation.directoryName(bundleID: AppDataLocation.productionBundleID, isTesting: false),
            AppDataLocation.directoryName(bundleID: AppDataLocation.devBundleID, isTesting: false)
        )
    }

    // MARK: - Layout

    /// The suite itself is the proof: every store now resolves through this, so
    /// a test run must not be pointing at the production directory.
    func testTheRunningTestSuiteIsNotUsingTheProductionDirectory() {
        XCTAssertEqual(AppDataLocation.directoryName, "Type4MeTests")
        XCTAssertFalse(AppDataLocation.directory.path.hasSuffix("/Type4Me"))
    }

    func testBackupDirectoryIsASiblingAndFollowsTheSameBuild() {
        let data = AppDataLocation.directory.standardizedFileURL
        let backups = AppDataLocation.backupDirectory.standardizedFileURL

        XCTAssertEqual(backups.deletingLastPathComponent(), data.deletingLastPathComponent())
        XCTAssertFalse(backups.path.hasPrefix(data.path + "/"))
        XCTAssertEqual(backups.lastPathComponent, "\(AppDataLocation.directoryName) Backups")
    }

    /// Every store reads its location from here, so the stores a Dev build
    /// touches move with it.
    func testStoresResolveThroughTheSharedLocation() {
        let root = AppDataLocation.directory.standardizedFileURL.path
        XCTAssertTrue(SnippetStorage.userFileURL.standardizedFileURL.path.hasPrefix(root + "/"))
        XCTAssertTrue(HotwordStorage.userFileURL.standardizedFileURL.path.hasPrefix(root + "/"))
        XCTAssertTrue(DataBackupManager.dataDirectory.standardizedFileURL.path == root)
    }
}
