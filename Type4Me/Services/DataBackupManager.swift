import Foundation
import SQLite3
#if canImport(AppKit)
import AppKit
#endif

/// Rotating local snapshots of the user's data, so an unexplained loss is
/// recoverable without the user having set anything up in advance (#302).
///
/// Snapshots are written beside the data directory rather than inside it: a
/// backup kept inside would certainly be taken by the same loss. A sibling is
/// only a better bet, not a guarantee — nothing here proves a real failure could
/// not take the whole of Application Support.
enum DataBackupManager {

    /// Every file the stores persist as user data. Kept as an explicit list so
    /// adding a store is a visible decision about whether it is worth backing up.
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
        "intelli-sense-expression-profile.json",
        "revise-settings.json",
        "batch-correction-suggestions-v1.json",
        "jieba-user-dictionary-v1.utf8",
    ]

    /// Directories copied whole. `app-snippets/` holds per-app replacement rules
    /// and their registry.
    static let backedUpDirectories = ["app-snippets"]

    // Deliberately excluded: `models/` (large and re-downloadable), `Sounds/`
    // (a fallback lookup for bundled sounds), `debug.log*`, `Updates/` and
    // `server-pids.txt` (runtime state), `llm-pricing-cache.json` (re-fetched
    // from upstream), and the SQLite `-wal` / `-shm`
    // sidecars, whose committed contents `VACUUM INTO` folds into the copy.

    static let retainedSnapshots = 7
    static let minimumInterval: TimeInterval = 24 * 60 * 60

    /// Staging older than this is assumed to belong to a run that crashed.
    static let staleStagingAge: TimeInterval = 60 * 60

    private static let lastRunKey = "tf_lastDataBackupAt"
    private static let fingerprintFileName = ".fingerprint"
    private static let stagingPrefix = ".in-progress-"
    private static let snapshotNamePattern = #"^\d{8}-\d{6}$"#

    // MARK: - Locations

    private static var appSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    }

    static var dataDirectory: URL {
        appSupport.appendingPathComponent(AppDataLocation.profileDirectoryName, isDirectory: true)
    }

    /// A sibling of the data directory, not a child of it. Named after the
    /// profile, so production keeps `Type4Me Backups` and tests get their own.
    static var backupRoot: URL {
        appSupport.appendingPathComponent("\(AppDataLocation.profileDirectoryName) Backups", isDirectory: true)
    }

    // MARK: - Entry point

    /// Takes a snapshot if one is due and the data has changed since the last.
    static func runIfNeeded(
        now: Date = Date(),
        defaults: UserDefaults = .standard,
        source: URL? = nil,
        root: URL? = nil
    ) {
        guard isDue(now: now, defaults: defaults) else { return }
        do {
            try snapshot(now: now, from: source, root: root)
            // Recorded whether or not anything changed: today's question of
            // "is there a current snapshot" has been answered either way.
            defaults.set(now.timeIntervalSince1970, forKey: lastRunKey)
            prune(root: root)
        } catch {
            // The timestamp is left alone so the scheduler's next check retries.
            DebugFileLogger.log("data backup failed: \(error)")
        }
    }

    static func isDue(now: Date, defaults: UserDefaults) -> Bool {
        guard let last = lastRun(defaults: defaults) else { return true }
        // A timestamp from the future means the clock was moved backwards.
        // Trusting it would suspend backups until real time caught up with it,
        // which could be months.
        if now < last { return true }
        return now.timeIntervalSince(last) >= minimumInterval
    }

    static func lastRun(defaults: UserDefaults = .standard) -> Date? {
        (defaults.object(forKey: lastRunKey) as? TimeInterval).map(Date.init(timeIntervalSince1970:))
    }

    // MARK: - Snapshot

    /// Writes a snapshot, or returns nil when nothing has changed since the
    /// newest one. Re-copying unchanged data would evict older snapshots through
    /// rotation and shrink the window recovery is possible from.
    ///
    /// The snapshot is assembled in a hidden staging directory and renamed into
    /// place only once every item and the fingerprint are written, so a failure
    /// part-way through can never leave something that counts as a snapshot.
    @discardableResult
    static func snapshot(
        now: Date = Date(),
        from source: URL? = nil,
        root: URL? = nil
    ) throws -> URL? {
        let source = source ?? dataDirectory
        let root = root ?? backupRoot
        removeStaleStaging(in: root)

        let files = backedUpFiles
            .map { source.appendingPathComponent($0) }
            .filter { isDirectory($0) == false }
        let directories = backedUpDirectories
            .map { source.appendingPathComponent($0, isDirectory: true) }
            .filter { isDirectory($0) == true }
        let items = files + directories
        guard !items.isEmpty else { return nil }

        let fingerprint = fingerprint(of: items)
        if let newest = snapshots(in: root).last, storedFingerprint(of: newest) == fingerprint {
            return nil
        }

        let destination = root.appendingPathComponent(name(for: now), isDirectory: true)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw BackupError.snapshotAlreadyExists(destination.lastPathComponent)
        }

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let staging = root.appendingPathComponent(stagingPrefix + UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            for item in items {
                let target = staging.appendingPathComponent(item.lastPathComponent)
                if item.pathExtension == "db" {
                    // A live SQLite database cannot be copied byte-for-byte:
                    // committed writes may still be in the write-ahead log.
                    // `VACUUM INTO` asks SQLite for a consistent copy instead.
                    try copyDatabase(from: item, to: target)
                } else {
                    try FileManager.default.copyItem(at: item, to: target)
                }
            }
            // Written last: its presence is what marks a snapshot as complete.
            try fingerprint.write(
                to: staging.appendingPathComponent(fingerprintFileName),
                atomically: true,
                encoding: .utf8
            )
            try FileManager.default.moveItem(at: staging, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
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

    /// Staging left by a crash is invisible to `snapshots()` but still occupies
    /// disk. Only old staging is removed, so a snapshot another process is
    /// writing right now is left alone.
    static func removeStaleStaging(in root: URL) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        for name in names where name.hasPrefix(stagingPrefix) {
            let url = root.appendingPathComponent(name)
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            guard let modified = attributes?[.modificationDate] as? Date,
                  Date().timeIntervalSince(modified) > staleStagingAge
            else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Rotation

    /// Complete snapshots, oldest first. Names sort chronologically.
    static func snapshots(in root: URL? = nil) -> [URL] {
        let root = root ?? backupRoot
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        return entries
            .filter(isSnapshot)
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// A directory counts only with the expected name and a fingerprint.
    /// Anything else is an interrupted write or not ours, and must neither be
    /// shown as the latest backup nor take a rotation slot from a real one.
    static func isSnapshot(_ url: URL) -> Bool {
        guard isDirectory(url) == true,
              url.lastPathComponent.range(of: snapshotNamePattern, options: .regularExpression) != nil
        else { return false }
        return FileManager.default.fileExists(
            atPath: url.appendingPathComponent(fingerprintFileName).path
        )
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

    // MARK: - Naming

    static func name(for date: Date) -> String {
        snapshotNameFormatter().string(from: date)
    }

    /// Inverse of `name(for:)`, for showing when the newest snapshot was taken.
    static func date(fromSnapshotName name: String) -> Date? {
        snapshotNameFormatter().date(from: name)
    }

    private static func snapshotNameFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }

    // MARK: - Change detection

    /// Size and modification time per item — not a content hash, but enough to
    /// notice the edits this protects.
    ///
    /// A database also reports its write-ahead log. Committed changes can live
    /// only there, leaving the main file's size and timestamp untouched, and
    /// would otherwise be mistaken for no change at all.
    static func fingerprint(of urls: [URL]) -> String {
        urls.flatMap(signatureLines(for:)).sorted().joined(separator: "\n")
    }

    private static func signatureLines(for url: URL) -> [String] {
        if isDirectory(url) == true {
            let subpaths = (try? FileManager.default.subpathsOfDirectory(atPath: url.path)) ?? []
            let lines = subpaths.compactMap { subpath -> String? in
                let child = url.appendingPathComponent(subpath)
                guard isDirectory(child) == false else { return nil }
                return signatureLine(label: "\(url.lastPathComponent)/\(subpath)", for: child)
            }
            return lines.isEmpty ? ["\(url.lastPathComponent)/:empty"] : lines
        }

        var lines = [signatureLine(label: url.lastPathComponent, for: url)]
        if url.pathExtension == "db" {
            let wal = URL(fileURLWithPath: url.path + "-wal")
            lines.append(signatureLine(label: wal.lastPathComponent, for: wal))
        }
        return lines
    }

    private static func signatureLine(label: String, for url: URL) -> String {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return "\(label):absent"
        }
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? -1
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1
        return "\(label):\(size):\(String(format: "%.6f", modified))"
    }

    private static func storedFingerprint(of snapshot: URL) -> String? {
        try? String(contentsOf: snapshot.appendingPathComponent(fingerprintFileName), encoding: .utf8)
    }

    private static func isDirectory(_ url: URL) -> Bool? {
        var flag: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &flag) else { return nil }
        return flag.boolValue
    }

    enum BackupError: Error, Equatable {
        case databaseUnreadable(String)
        case snapshotAlreadyExists(String)
    }
}
