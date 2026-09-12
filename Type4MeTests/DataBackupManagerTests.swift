import XCTest
import SQLite3
@testable import Type4Me

/// #302. Every test drives a temporary root: this store's real path is not
/// isolated under XCTest, and a test that wrote there would be one interrupted
/// run away from destroying the data the feature exists to protect.
final class DataBackupManagerTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("t4m-backup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeSnapshot(named name: String, fingerprint: String = "x") throws {
        let dir = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try fingerprint.write(
            to: dir.appendingPathComponent(".fingerprint"), atomically: true, encoding: .utf8
        )
    }

    // MARK: - Location

    /// The whole point: a backup inside the data directory would be taken by
    /// the same loss it is meant to survive.
    func testBackupRootIsOutsideTheDataDirectory() {
        let data = DataBackupManager.dataDirectory.standardizedFileURL.path
        let backups = DataBackupManager.backupRoot.standardizedFileURL.path

        XCTAssertFalse(backups.hasPrefix(data + "/"))
        XCTAssertNotEqual(backups, data)
        XCTAssertEqual(
            DataBackupManager.backupRoot.deletingLastPathComponent().standardizedFileURL,
            DataBackupManager.dataDirectory.deletingLastPathComponent().standardizedFileURL,
            "backups are expected to sit beside the data directory"
        )
    }

    func testTransientFilesAreNotBackedUp() {
        for name in ["debug.log", "history.db-wal", "history.db-shm"] {
            XCTAssertFalse(
                DataBackupManager.backedUpFiles.contains(name),
                "\(name) carries no user data and would only add churn"
            )
        }
        XCTAssertTrue(DataBackupManager.backedUpFiles.contains("history.db"))
        XCTAssertTrue(DataBackupManager.backedUpFiles.contains("modes.json"))
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

    func testPruneIsANoOpBelowTheLimit() throws {
        try makeSnapshot(named: "20260101-000000")
        XCTAssertTrue(DataBackupManager.prune(keeping: 3, root: root).isEmpty)
        XCTAssertEqual(DataBackupManager.snapshots(in: root).count, 1)
    }

    // MARK: - Scheduling

    func testFirstRunIsDueAndASecondRunWithinADayIsNot() {
        let defaults = UserDefaults(suiteName: "t4m-backup-\(UUID().uuidString)")!
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        XCTAssertTrue(DataBackupManager.isDue(now: now, defaults: defaults))

        defaults.set(now.timeIntervalSince1970, forKey: "tf_lastDataBackupAt")
        XCTAssertFalse(DataBackupManager.isDue(now: now.addingTimeInterval(3600), defaults: defaults))
        XCTAssertTrue(
            DataBackupManager.isDue(
                now: now.addingTimeInterval(DataBackupManager.minimumInterval), defaults: defaults
            )
        )
    }

    // MARK: - Naming

    func testSnapshotNamesSortChronologicallyAndRoundTrip() throws {
        let earlier = Date(timeIntervalSince1970: 1_700_000_000)
        let later = earlier.addingTimeInterval(86_400)

        let a = DataBackupManager.name(for: earlier)
        let b = DataBackupManager.name(for: later)

        XCTAssertLessThan(a, b, "rotation relies on lexical order matching chronological order")
        let parsed = try XCTUnwrap(DataBackupManager.date(fromSnapshotName: a))
        XCTAssertEqual(parsed.timeIntervalSince1970, earlier.timeIntervalSince1970, accuracy: 1)
    }

    // MARK: - Taking a snapshot

    private func seedDataDirectory() throws -> URL {
        let data = root.appendingPathComponent("data", isDirectory: true)
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        try #"[{"trigger":"Doc","replacement":"Docker"}]"#
            .write(to: data.appendingPathComponent("snippets.json"), atomically: true, encoding: .utf8)
        try makeDatabase(at: data.appendingPathComponent("history.db"), rows: 3)
        return data
    }

    private func makeDatabase(at url: URL, rows: Int) throws {
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &handle), SQLITE_OK)
        defer { sqlite3_close(handle) }
        XCTAssertEqual(
            sqlite3_exec(handle, "CREATE TABLE t(id INTEGER PRIMARY KEY);", nil, nil, nil),
            SQLITE_OK
        )
        for id in 1...rows {
            XCTAssertEqual(
                sqlite3_exec(handle, "INSERT INTO t(id) VALUES(\(id));", nil, nil, nil),
                SQLITE_OK
            )
        }
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

    func testSnapshotCopiesFilesAndKeepsDatabaseContentReadable() throws {
        let data = try seedDataDirectory()
        let backups = root.appendingPathComponent("backups", isDirectory: true)

        let written = try XCTUnwrap(
            DataBackupManager.snapshot(now: Date(timeIntervalSince1970: 1_700_000_000),
                                       from: data, root: backups)
        )

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: written.appendingPathComponent("snippets.json").path)
        )
        // A byte copy of a live database can be torn; the snapshot must be a
        // database SQLite will still open.
        XCTAssertEqual(rowCount(at: written.appendingPathComponent("history.db")), 3)
    }

    /// Re-copying unchanged data would evict older snapshots through rotation
    /// and shrink the window recovery is possible from.
    func testSnapshotIsSkippedWhenNothingChanged() throws {
        let data = try seedDataDirectory()
        let backups = root.appendingPathComponent("backups", isDirectory: true)

        XCTAssertNotNil(try DataBackupManager.snapshot(from: data, root: backups))
        XCTAssertNil(try DataBackupManager.snapshot(from: data, root: backups))
        XCTAssertEqual(DataBackupManager.snapshots(in: backups).count, 1)
    }

    func testSnapshotIsTakenAgainAfterAChange() throws {
        let data = try seedDataDirectory()
        let backups = root.appendingPathComponent("backups", isDirectory: true)
        XCTAssertNotNil(try DataBackupManager.snapshot(
            now: Date(timeIntervalSince1970: 1_700_000_000), from: data, root: backups))

        try #"[{"trigger":"Doc","replacement":"Dockerfile"}]"#.write(
            to: data.appendingPathComponent("snippets.json"), atomically: true, encoding: .utf8)

        XCTAssertNotNil(try DataBackupManager.snapshot(
            now: Date(timeIntervalSince1970: 1_700_086_400), from: data, root: backups))
        XCTAssertEqual(DataBackupManager.snapshots(in: backups).count, 2)
    }

    func testSnapshotIsSkippedWhenThereIsNothingToBackUp() throws {
        let empty = root.appendingPathComponent("empty", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        XCTAssertNil(try DataBackupManager.snapshot(from: empty, root: root))
    }

    // MARK: - Change detection

    func testFingerprintChangesWhenAFileChanges() throws {
        let file = root.appendingPathComponent("modes.json")
        try "one".write(to: file, atomically: true, encoding: .utf8)
        let before = DataBackupManager.fingerprint(of: [file])

        try "one plus more".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertNotEqual(before, DataBackupManager.fingerprint(of: [file]))
    }

    func testFingerprintIgnoresTheOrderFilesAreListedIn() throws {
        let a = root.appendingPathComponent("a.json")
        let b = root.appendingPathComponent("b.json")
        try "a".write(to: a, atomically: true, encoding: .utf8)
        try "b".write(to: b, atomically: true, encoding: .utf8)

        XCTAssertEqual(
            DataBackupManager.fingerprint(of: [a, b]),
            DataBackupManager.fingerprint(of: [b, a])
        )
    }
}
