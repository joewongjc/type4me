import Foundation
import AppKit
import SQLite3

extension HistoryStore {

    struct ModeUsageRow: Sendable, Equatable {
        let modeId: String?
        let modeName: String?
        let count: Int
    }

    /// Records backfilled from Intelli Sense traces may only know the app's
    /// name, so apps are keyed by bundle ID when known and by name otherwise.
    struct AppUsage: Sendable, Equatable, Identifiable {
        let key: String
        let bundleId: String?
        let appName: String?
        let characterCount: Int
        var id: String { key }
    }

    /// Statuses whose text reached the user as dictation output. Mac Action
    /// results are command feedback, not dictated text, so they are excluded.
    static let dictationStatusSQLCondition =
        "status IN ('completed', 'stream_recovered', 'llm_error', 'translation_error')"

    func modeUsageRows(from start: Date, to end: Date) async -> [ModeUsageRow] {
        let sql = """
        SELECT processing_mode_id, processing_mode, COUNT(*)
        FROM recognition_history
        WHERE \(Self.activeStatusSQLCondition) AND created_at >= ? AND created_at < ?
        GROUP BY processing_mode_id, processing_mode;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        bindRange(stmt, start, end)
        var rows: [ModeUsageRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            rows.append(ModeUsageRow(
                modeId: sqlite3_column_type(stmt, 0) == SQLITE_NULL ? nil : column(stmt, 0),
                modeName: sqlite3_column_type(stmt, 1) == SQLITE_NULL ? nil : column(stmt, 1),
                count: Int(sqlite3_column_int(stmt, 2))
            ))
        }
        return rows
    }

    /// Characters per target app, largest first. Records with no known app
    /// are left out.
    func appUsage(from start: Date, to end: Date, limit: Int) async -> [AppUsage] {
        let sql = """
        SELECT COALESCE(target_bundle_id, target_app_name) AS app_key,
               MAX(target_bundle_id),
               (SELECT latest.target_app_name FROM recognition_history AS latest
                WHERE COALESCE(latest.target_bundle_id, latest.target_app_name)
                      = COALESCE(h.target_bundle_id, h.target_app_name)
                  AND latest.target_app_name IS NOT NULL
                ORDER BY latest.created_at DESC LIMIT 1),
               COALESCE(SUM(COALESCE(character_count, 0)), 0) AS chars
        FROM recognition_history AS h
        WHERE \(Self.dictationStatusSQLCondition)
          AND COALESCE(target_bundle_id, target_app_name) IS NOT NULL
          AND created_at >= ? AND created_at < ?
        GROUP BY app_key
        ORDER BY chars DESC
        LIMIT \(limit);
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        bindRange(stmt, start, end)
        var rows: [AppUsage] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            rows.append(AppUsage(
                key: column(stmt, 0),
                bundleId: sqlite3_column_type(stmt, 1) == SQLITE_NULL ? nil : column(stmt, 1),
                appName: sqlite3_column_type(stmt, 2) == SQLITE_NULL ? nil : column(stmt, 2),
                characterCount: Int(sqlite3_column_int(stmt, 3))
            ))
        }
        return rows
    }

    func dictationRecords(from start: Date, to end: Date, limit: Int) async -> [HistoryRecord] {
        let sql = """
        SELECT * FROM recognition_history
        WHERE \(Self.dictationStatusSQLCondition) AND created_at >= ? AND created_at < ?
        ORDER BY created_at DESC LIMIT \(limit);
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        bindRange(stmt, start, end)
        return readRows(stmt)
    }

    func dictationRecordCount(from start: Date, to end: Date) async -> Int {
        let sql = """
        SELECT COUNT(*) FROM recognition_history
        WHERE \(Self.dictationStatusSQLCondition) AND created_at >= ? AND created_at < ?;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        bindRange(stmt, start, end)
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int(stmt, 0)) : 0
    }

    // MARK: - Backfill

    /// Intelli Sense traces recorded the app name before target columns
    /// existed. Copy it into the target columns, resolving the bundle ID from
    /// installed apps when possible. Rows stay untouched when the trace has no
    /// app or names Type4Me itself, so this is safe to run on every launch.
    func backfillTargetAppsFromTraces(
        resolveBundleId: @Sendable (String) -> String? = InstalledAppIndex.bundleId(forAppName:)
    ) async {
        let selectSQL = """
        SELECT id, json_extract(intelli_sense_trace, '$.appName')
        FROM recognition_history
        WHERE target_bundle_id IS NULL AND target_app_name IS NULL
          AND intelli_sense_trace IS NOT NULL
          AND json_extract(intelli_sense_trace, '$.appName') IS NOT NULL;
        """
        var select: OpaquePointer?
        guard sqlite3_prepare_v2(db, selectSQL, -1, &select, nil) == SQLITE_OK else { return }
        var pending: [(id: String, appName: String)] = []
        while sqlite3_step(select) == SQLITE_ROW {
            let name = column(select, 1)
            if !name.isEmpty, name != "Type4Me" { pending.append((column(select, 0), name)) }
        }
        sqlite3_finalize(select)
        guard !pending.isEmpty else { return }

        var resolved: [String: String?] = [:]
        let updateSQL = "UPDATE recognition_history SET target_app_name = ?, target_bundle_id = ? WHERE id = ?;"
        var update: OpaquePointer?
        guard sqlite3_prepare_v2(db, updateSQL, -1, &update, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(update) }
        sqlite3_exec(db, "BEGIN;", nil, nil, nil)
        for row in pending {
            if resolved[row.appName] == nil { resolved[row.appName] = .some(resolveBundleId(row.appName)) }
            let bundleId = resolved[row.appName] ?? nil
            sqlite3_reset(update)
            bind(update, 1, row.appName)
            bindOptional(update, 2, bundleId)
            bind(update, 3, row.id)
            sqlite3_step(update)
        }
        sqlite3_exec(db, "COMMIT;", nil, nil, nil)
        postDidChangeNotification()
    }

    private func bindRange(_ stmt: OpaquePointer?, _ start: Date, _ end: Date) {
        let iso = ISO8601DateFormatter()
        bind(stmt, 1, iso.string(from: start))
        bind(stmt, 2, iso.string(from: end))
    }
}

/// Maps app names, as Intelli Sense recorded them, to bundle IDs of apps
/// installed in the standard locations. Matches the file name, the bundle
/// name, the display name, and Finder's localized name.
enum InstalledAppIndex {
    static func bundleId(forAppName name: String) -> String? {
        index[name.lowercased()]
    }

    private static let index: [String: String] = {
        let fileManager = FileManager.default
        let directories = [
            "/Applications", "/Applications/Utilities",
            "/System/Applications", "/System/Applications/Utilities",
            NSHomeDirectory() + "/Applications",
        ]
        var result: [String: String] = [:]
        for directory in directories {
            guard let entries = try? fileManager.contentsOfDirectory(atPath: directory) else { continue }
            for entry in entries where entry.hasSuffix(".app") {
                let path = directory + "/" + entry
                guard let bundle = Bundle(path: path), let bundleId = bundle.bundleIdentifier else { continue }
                let names = [
                    String(entry.dropLast(4)),
                    bundle.object(forInfoDictionaryKey: "CFBundleName") as? String,
                    bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
                    fileManager.displayName(atPath: path).replacingOccurrences(of: ".app", with: ""),
                ]
                for name in names.compactMap({ $0 }) where result[name.lowercased()] == nil {
                    result[name.lowercased()] = bundleId
                }
            }
        }
        return result
    }()
}
