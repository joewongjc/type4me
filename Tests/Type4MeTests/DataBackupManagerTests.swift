import XCTest
import SQLite3
@testable import Type4Me

/// #302. Every test drives a temporary root: this store's real path is not
/// isolated under XCTest, and a test that wrote there would be one interrupted
/// run away from destroying the data the feature exists to protect.
final class DataBackupManagerTests: XCTestCase {

    private var root: URL!
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private let t1 = Date(timeIntervalSince1970: 1_700_086_400)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("t4m-backup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Helpers

    private func makeSnapshot(named name: String, fingerprint: String? = "x") throws {
        let dir = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let fingerprint {
            try fingerprint.write(
                to: dir.appendingPathComponent(".fingerprint"), atomically: true, encoding: .utf8
            )
        }
    }

    private func exec(_ handle: OpaquePointer?, _ sql: String) {
        XCTAssertEqual(sqlite3_exec(handle, sql, nil, nil, nil), SQLITE_OK, sql)
    }

    private func makeDatabase(at url: URL, rows: Int) {
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &handle), SQLITE_OK)
        defer { sqlite3_close(handle) }
        exec(handle, "CREATE TABLE t(id INTEGER PRIMARY KEY);")
        for id in 1...rows { exec(handle, "INSERT INTO t(id) VALUES(\(id));") }
    }

    private func rowCount(at url: URL) -> Int {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return -1 }
        defer { sqlite3_close(handle) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "SELECT COUNT(*) FROM t;", -1, &stmt, nil) == SQLITE_OK
        else { return -1 }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int(stmt, 0)) : -1
    }

    private func seedDataDirectory() throws -> URL {
        let data = root.appendingPathComponent("data", isDirectory: true)
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        try #"[{"trigger":"Doc","replacement":"Docker"}]"#
            .write(to: data.appendingPathComponent("snippets.json"), atomically: true, encoding: .utf8)
        makeDatabase(at: data.appendingPathComponent("history.db"), rows: 3)
        return data
    }

    private func entries(in url: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
    }

    private func attributes(of url: URL) -> (size: Int64, modified: Date?) {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return ((attrs?[.size] as? NSNumber)?.int64Value ?? -1, attrs?[.modificationDate] as? Date)
    }

    // MARK: - Location and scope

    /// A backup inside the data directory would be taken by the same loss it is
    /// meant to survive. Being a sibling is a better bet, not a proven one.
    func testBackupRootIsOutsideTheDataDirectory() {
        let data = DataBackupManager.dataDirectory.standardizedFileURL
        let backups = DataBackupManager.backupRoot.standardizedFileURL

        XCTAssertFalse(backups.path.hasPrefix(data.path + "/"))
        XCTAssertNotEqual(backups, data)
        XCTAssertEqual(backups.deletingLastPathComponent(), data.deletingLastPathComponent())
    }

    func testScopeCoversEveryPersistentUserStore() {
        for name in [
            "history.db", "ask-anything.db", "modes.json", "snippets.json", "hotwords.json",
            "credentials.json", "intelli-sense-settings.json",
            "intelli-sense-expression-profile.json", "revise-settings.json",
            "batch-correction-suggestions-v1.json", "jieba-user-dictionary-v1.utf8",
        ] {
            XCTAssertTrue(DataBackupManager.backedUpFiles.contains(name), "\(name) is user data")
        }
        XCTAssertTrue(DataBackupManager.backedUpDirectories.contains("app-snippets"))
    }

    func testRegeneratableAndRuntimeStateIsExcluded() {
        for name in ["debug.log", "debug.log.1", "history.db-wal", "history.db-shm", "server-pids.txt"] {
            XCTAssertFalse(DataBackupManager.backedUpFiles.contains(name), "\(name) is not user data")
        }
        for name in ["models", "Sounds", "Updates"] {
            XCTAssertFalse(DataBackupManager.backedUpDirectories.contains(name), "\(name) is not user data")
        }
    }

    // MARK: - Taking a snapshot

    func testSnapshotCopiesFilesAndKeepsDatabaseContentReadable() throws {
        let data = try seedDataDirectory()
        let backups = root.appendingPathComponent("backups", isDirectory: true)

        let written = try XCTUnwrap(DataBackupManager.snapshot(now: t0, from: data, root: backups))

        XCTAssertTrue(FileManager.default.fileExists(atPath: written.appendingPathComponent("snippets.json").path))
        XCTAssertEqual(rowCount(at: written.appendingPathComponent("history.db")), 3)
    }

    func testAppSpecificRuleDirectoryIsBackedUpAndItsChangesDetected() throws {
        let data = try seedDataDirectory()
        let appRules = data.appendingPathComponent("app-snippets", isDirectory: true)
        try FileManager.default.createDirectory(at: appRules, withIntermediateDirectories: true)
        try "{}".write(to: appRules.appendingPathComponent("registry.json"), atomically: true, encoding: .utf8)
        let backups = root.appendingPathComponent("backups", isDirectory: true)

        let first = try XCTUnwrap(DataBackupManager.snapshot(now: t0, from: data, root: backups))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: first.appendingPathComponent("app-snippets/registry.json").path
        ))

        try #"[{"trigger":"a","replacement":"b"}]"#.write(
            to: appRules.appendingPathComponent("com.example.app.json"), atomically: true, encoding: .utf8
        )
        XCTAssertNotNil(
            try DataBackupManager.snapshot(now: t1, from: data, root: backups),
            "a change inside a backed-up directory must not be mistaken for no change"
        )
    }

    /// Re-copying unchanged data would evict older snapshots through rotation
    /// and shrink the window recovery is possible from.
    func testSnapshotIsSkippedWhenNothingChanged() throws {
        let data = try seedDataDirectory()
        let backups = root.appendingPathComponent("backups", isDirectory: true)

        XCTAssertNotNil(try DataBackupManager.snapshot(now: t0, from: data, root: backups))
        XCTAssertNil(try DataBackupManager.snapshot(now: t1, from: data, root: backups))
        XCTAssertEqual(DataBackupManager.snapshots(in: backups).count, 1)
    }

    func testSnapshotIsSkippedWhenThereIsNothingToBackUp() throws {
        let empty = root.appendingPathComponent("empty", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        XCTAssertNil(try DataBackupManager.snapshot(from: empty, root: root))
    }

    // MARK: - WAL

    /// Review blocker on #304. With WAL on and a writer holding the database
    /// open, a committed insert lands in `-wal` and leaves the main file's size
    /// and timestamp untouched. Detecting change from the main file alone
    /// skipped the snapshot before `VACUUM INTO` ever ran.
    func testWALOnlyChangeIsNotSkippedAndIsCaptured() throws {
        let data = root.appendingPathComponent("data", isDirectory: true)
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        let database = data.appendingPathComponent("ask-anything.db")
        let backups = root.appendingPathComponent("backups", isDirectory: true)

        var writer: OpaquePointer?
        XCTAssertEqual(sqlite3_open(database.path, &writer), SQLITE_OK)
        defer { sqlite3_close(writer) }
        exec(writer, "PRAGMA journal_mode = WAL;")
        exec(writer, "PRAGMA wal_autocheckpoint = 0;")
        exec(writer, "CREATE TABLE t(id INTEGER PRIMARY KEY);")
        exec(writer, "INSERT INTO t(id) VALUES(1);")

        let first = try XCTUnwrap(DataBackupManager.snapshot(now: t0, from: data, root: backups))
        XCTAssertEqual(rowCount(at: first.appendingPathComponent("ask-anything.db")), 1)

        let mainBefore = attributes(of: database)
        exec(writer, "INSERT INTO t(id) VALUES(2);")

        // Without this the test could pass for the wrong reason.
        let mainAfter = attributes(of: database)
        XCTAssertEqual(mainAfter.size, mainBefore.size, "precondition: the change must live only in the WAL")
        XCTAssertEqual(mainAfter.modified, mainBefore.modified, "precondition: the change must live only in the WAL")

        let second = try XCTUnwrap(
            DataBackupManager.snapshot(now: t1, from: data, root: backups),
            "a WAL-only change was treated as no change"
        )
        XCTAssertEqual(rowCount(at: second.appendingPathComponent("ask-anything.db")), 2)
    }

    // MARK: - Failure

    /// Review blocker on #304. A snapshot that fails part-way must leave nothing
    /// that is shown as the latest backup or takes a rotation slot.
    func testFailedSnapshotLeavesNothingBehindAndKeepsEarlierSnapshots() throws {
        let data = try seedDataDirectory()
        let backups = root.appendingPathComponent("backups", isDirectory: true)
        XCTAssertNotNil(try DataBackupManager.snapshot(now: t0, from: data, root: backups))

        // `ask-anything.db` is copied after `history.db`, so this fails with
        // part of the snapshot already written.
        try Data("not a database".utf8).write(to: data.appendingPathComponent("ask-anything.db"))

        XCTAssertThrowsError(try DataBackupManager.snapshot(now: t1, from: data, root: backups))

        XCTAssertEqual(
            DataBackupManager.snapshots(in: backups).map(\.lastPathComponent),
            [DataBackupManager.name(for: t0)]
        )
        let leftovers = entries(in: backups)
        XCTAssertFalse(leftovers.contains(DataBackupManager.name(for: t1)))
        XCTAssertFalse(leftovers.contains { $0.hasPrefix(".in-progress-") }, "staging was not cleaned up")
    }

    func testSnapshotsIgnoreIncompleteAndUnrecognisedDirectories() throws {
        try makeSnapshot(named: "20260101-000000")
        try makeSnapshot(named: "20260102-000000", fingerprint: nil)
        try makeSnapshot(named: "notes")
        try makeSnapshot(named: ".in-progress-abc")

        XCTAssertEqual(
            DataBackupManager.snapshots(in: root).map(\.lastPathComponent),
            ["20260101-000000"]
        )
    }

    func testStaleStagingFromACrashIsRemovedButFreshStagingIsKept() throws {
        let data = try seedDataDirectory()
        let backups = root.appendingPathComponent("backups", isDirectory: true)
        let stale = backups.appendingPathComponent(".in-progress-stale", isDirectory: true)
        let fresh = backups.appendingPathComponent(".in-progress-fresh", isDirectory: true)
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fresh, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-2 * DataBackupManager.staleStagingAge)],
            ofItemAtPath: stale.path
        )

        XCTAssertNotNil(try DataBackupManager.snapshot(now: t0, from: data, root: backups))

        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: fresh.path),
            "staging another process may still be writing must not be removed"
        )
    }

    // MARK: - Rotation

    func testSnapshotsAreOrderedOldestFirst() throws {
        try makeSnapshot(named: "20260101-000000")
        try makeSnapshot(named: "20260103-000000")
        try makeSnapshot(named: "20260102-000000")

        XCTAssertEqual(
            DataBackupManager.snapshots(in: root).map(\.lastPathComponent),
            ["20260101-000000", "20260102-000000", "20260103-000000"]
        )
    }

    func testPruneKeepsTheNewestAndDropsTheRest() throws {
        for day in 1...5 {
            try makeSnapshot(named: String(format: "202601%02d-000000", day))
        }

        let removed = DataBackupManager.prune(keeping: 3, root: root)

        XCTAssertEqual(removed.map(\.lastPathComponent), ["20260101-000000", "20260102-000000"])
        XCTAssertEqual(
            DataBackupManager.snapshots(in: root).map(\.lastPathComponent),
            ["20260103-000000", "20260104-000000", "20260105-000000"]
        )
    }

    /// An incomplete directory must not take a slot and push out a real backup.
    func testPruneDoesNotCountIncompleteDirectories() throws {
        for day in 1...3 {
            try makeSnapshot(named: String(format: "202601%02d-000000", day))
        }
        try makeSnapshot(named: "20260104-000000", fingerprint: nil)

        XCTAssertTrue(DataBackupManager.prune(keeping: 3, root: root).isEmpty)
        XCTAssertEqual(DataBackupManager.snapshots(in: root).count, 3)
    }

    // MARK: - Scheduling and naming

    func testFirstRunIsDueAndASecondRunWithinADayIsNot() {
        let defaults = UserDefaults(suiteName: "t4m-backup-\(UUID().uuidString)")!
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        XCTAssertTrue(DataBackupManager.isDue(now: now, defaults: defaults))

        defaults.set(now.timeIntervalSince1970, forKey: "tf_lastDataBackupAt")
        XCTAssertFalse(DataBackupManager.isDue(now: now.addingTimeInterval(3600), defaults: defaults))
        XCTAssertTrue(DataBackupManager.isDue(
            now: now.addingTimeInterval(DataBackupManager.minimumInterval), defaults: defaults
        ))
    }

    func testSnapshotNamesSortChronologicallyAndRoundTrip() throws {
        let a = DataBackupManager.name(for: t0)
        let b = DataBackupManager.name(for: t1)

        XCTAssertLessThan(a, b, "rotation relies on lexical order matching chronological order")
        let parsed = try XCTUnwrap(DataBackupManager.date(fromSnapshotName: a))
        XCTAssertEqual(parsed.timeIntervalSince1970, t0.timeIntervalSince1970, accuracy: 1)
    }

    // MARK: - Fingerprint

    func testFingerprintChangesWhenAFileChanges() throws {
        let file = root.appendingPathComponent("modes.json")
        try "one".write(to: file, atomically: true, encoding: .utf8)
        let before = DataBackupManager.fingerprint(of: [file])

        try "one plus more".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertNotEqual(before, DataBackupManager.fingerprint(of: [file]))
    }

    func testFingerprintIgnoresTheOrderItemsAreListedIn() throws {
        let a = root.appendingPathComponent("a.json")
        let b = root.appendingPathComponent("b.json")
        try "a".write(to: a, atomically: true, encoding: .utf8)
        try "b".write(to: b, atomically: true, encoding: .utf8)

        XCTAssertEqual(DataBackupManager.fingerprint(of: [a, b]), DataBackupManager.fingerprint(of: [b, a]))
    }
}
