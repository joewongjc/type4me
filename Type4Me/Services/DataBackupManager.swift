import Foundation
import SQLite3
#if canImport(AppKit)
import AppKit
#endif

/// Rotating local snapshots of the user's data, so an unexplained loss is
/// recoverable without the user having set anything up in advance (#302).
///
/// Snapshots are written **outside** the data directory. A backup kept inside
/// it would be taken by the same loss it exists to survive.
enum DataBackupManager {

    /// Files worth keeping. Deliberately excludes `debug.log`, SQLite sidecars
    /// (`-wal` / `-shm`, which are captured by the database snapshot itself) and
    /// `Updates/`, none of which carry user data.
    static let backedUpFiles = [
        "history.db",
        "ask-anything.db",
        "modes.json",
        "snippets.json",
        "builtin-snippets.json",
        "hotwords.json",
        "builtin-hotwords.json",
        "hotwords.txt",
        "credentials.json",
        "intelli-sense-settings.json",
    ]

    static let retainedSnapshots = 7
    static let minimumInterval: TimeInterval = 24 * 60 * 60

    private static let lastRunKey = "tf_lastDataBackupAt"

    // MARK: - Locations

    private static var appSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    }

    static var dataDirectory: URL { appSupport.appendingPathComponent("Type4Me", isDirectory: true) }

    /// A sibling of the data directory, not a child of it.
    static var backupRoot: URL {
        appSupport.appendingPathComponent("Type4Me Backups", isDirectory: true)
    }

    // MARK: - Entry point

    /// Takes a snapshot if one is due and the data has changed since the last.
    static func runIfNeeded(
        now: Date = Date(),
        defaults: UserDefaults = .standard
    ) {
        guard isDue(now: now, defaults: defaults) else { return }
        guard let snapshot = try? snapshot(now: now) else { return }
        defaults.set(now.timeIntervalSince1970, forKey: lastRunKey)
        _ = snapshot
        prune()
    }

    static func isDue(now: Date, defaults: UserDefaults) -> Bool {
        let last = defaults.object(forKey: lastRunKey) as? TimeInterval
        guard let last else { return true }
        return now.timeIntervalSince1970 - last >= minimumInterval
    }

    // MARK: - Snapshot

    /// Writes a snapshot, or returns nil when the data is identical to the
    /// newest existing one. Re-copying unchanged data would evict older
    /// snapshots through rotation and shrink the window we can recover from.
    @discardableResult
    static func snapshot(
        now: Date = Date(),
        from source: URL? = nil,
        root: URL? = nil
    ) throws -> URL? {
        let source = source ?? dataDirectory
        let root = root ?? backupRoot
        let sources = backedUpFiles
            .map { source.appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !sources.isEmpty else { return nil }

        let fingerprint = fingerprint(of: sources)
        if let newest = snapshots(in: root).last,
           (try? String(contentsOf: newest.appendingPathComponent(".fingerprint"), encoding: .utf8))
            == fingerprint {
            return nil
        }

        let destination = root.appendingPathComponent(Self.name(for: now), isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        for source in sources {
            let target = destination.appendingPathComponent(source.lastPathComponent)
            if source.pathExtension == "db" {
                // A live SQLite database cannot be copied byte-for-byte: writes
                // may be sitting in the write-ahead log. `VACUUM INTO` asks
                // SQLite for a consistent copy instead.
                try copyDatabase(from: source, to: target)
            } else {
                try FileManager.default.copyItem(at: source, to: target)
            }
        }

        try fingerprint.write(
            to: destination.appendingPathComponent(".fingerprint"),
            atomically: true,
            encoding: .utf8
        )
        return destination
    }

    private static func copyDatabase(from source: URL, to target: URL) throws {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(source.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let handle
        else {
            sqlite3_close(handle)
            throw BackupError.databaseUnreadable(source.lastPathComponent)
        }
        defer { sqlite3_close(handle) }

        let quoted = target.path.replacingOccurrences(of: "'", with: "''")
        guard sqlite3_exec(handle, "VACUUM INTO '\(quoted)';", nil, nil, nil) == SQLITE_OK else {
            throw BackupError.databaseUnreadable(source.lastPathComponent)
        }
    }

    // MARK: - Rotation

    /// Snapshot directories, oldest first. Names sort chronologically.
    static func snapshots(in root: URL? = nil) -> [URL] {
        let root = root ?? backupRoot
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        return entries
            .filter { $0.hasDirectoryPath }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    @discardableResult
    static func prune(keeping limit: Int = retainedSnapshots, root: URL? = nil) -> [URL] {
        let all = snapshots(in: root)
        guard all.count > limit else { return [] }
        let doomed = all.prefix(all.count - limit)
        for url in doomed {
            try? FileManager.default.removeItem(at: url)
        }
        return Array(doomed)
    }

    // MARK: - Reveal

    /// Restoring is left to the user in Finder on purpose: overwriting live data
    /// from inside the running app is the more dangerous half of this feature.
    static func revealInFinder() {
        try? FileManager.default.createDirectory(at: backupRoot, withIntermediateDirectories: true)
        #if canImport(AppKit)
        NSWorkspace.shared.activateFileViewerSelecting([backupRoot])
        #endif
    }

    // MARK: - Helpers

    static func name(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }

    /// Inverse of `name(for:)`, for showing when the newest snapshot was taken.
    static func date(fromSnapshotName name: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.date(from: name)
    }

    /// Size and modification date per file. Cheap, and enough to notice the
    /// edits this is meant to protect; it is not a content hash.
    static func fingerprint(of urls: [URL]) -> String {
        urls.sorted { $0.lastPathComponent < $1.lastPathComponent }.map { url in
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attrs?[.size] as? NSNumber)?.intValue ?? -1
            let modified = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1
            return "\(url.lastPathComponent):\(size):\(Int(modified))"
        }.joined(separator: "\n")
    }

    enum BackupError: Error, Equatable {
        case databaseUnreadable(String)
    }
}
