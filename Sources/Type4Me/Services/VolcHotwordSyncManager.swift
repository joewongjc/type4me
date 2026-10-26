import Foundation
import os

/// Manages sync of local hotwords to Volcengine cloud boosting table.
/// Runs on app startup and after hotword edits in Settings.
enum VolcHotwordSyncManager {

    private static let logger = Logger(subsystem: "com.type4me.hotwords", category: "VolcHotwordSync")

    // UserDefaults keys
    private static let tableIDKey = "tf_volcBoostingTableID"
    private static let builtinVersionKey = "tf_volcBuiltinVersion"
    private static let dirtyKey = "tf_volcHotwordsDirty"

    private static let tableName = "type4me-hotwords"

    // MARK: - Public

    /// Current cloud boosting table ID, if any.
    static var boostingTableID: String? {
        UserDefaults.standard.string(forKey: tableIDKey)?.nilIfEmpty
    }

    /// Whether cloud hotword management is available (IAM credentials configured).
    static var isCloudEnabled: Bool {
        VolcBoostingTableManager.shared.loadCredentials() != nil
    }

    /// Mark hotwords as needing re-upload (e.g. after local edit).
    static func markDirty() {
        UserDefaults.standard.set(true, forKey: dirtyKey)
    }

    /// Sync hotwords to cloud if needed. Call on app startup and after hotword edits.
    /// Non-throwing: logs errors internally, never blocks the caller.
    static func syncIfNeeded() {
        guard let credentials = VolcBoostingTableManager.shared.loadCredentials() else {
            return  // No IAM credentials, skip cloud sync
        }

        Task.detached(priority: .utility) {
            do {
                try await performSync(credentials: credentials)
            } catch {
                logger.error("Cloud hotword sync failed: \(error.localizedDescription, privacy: .public)")
                DebugFileLogger.log("[HotwordSync] sync failed: \(error.localizedDescription)")
            }
        }
    }

    /// Force sync after user edits hotwords. Debounced by caller.
    static func syncAfterEdit() {
        markDirty()
        syncIfNeeded()
    }

    // MARK: - Internal

    private static func performSync(credentials: VolcBoostingTableManager.IAMCredentials) async throws {
        let manager = VolcBoostingTableManager.shared
        let words = HotwordStorage.loadCloudCompatible()
        let existingTableID = UserDefaults.standard.string(forKey: tableIDKey)?.nilIfEmpty
        let storedVersion = UserDefaults.standard.string(forKey: builtinVersionKey)
        let isDirty = UserDefaults.standard.bool(forKey: dirtyKey)
        let currentVersion = HotwordStorage.builtinVersion

        if let tableID = existingTableID {
            // Table exists: check if update needed
            let needsUpdate = isDirty || storedVersion != currentVersion
            guard needsUpdate else {
                logger.info("Cloud hotwords up to date (v\(currentVersion, privacy: .public), \(words.count) words)")
                return
            }

            try await manager.updateTable(credentials: credentials, tableID: tableID, words: words)
            UserDefaults.standard.set(currentVersion, forKey: builtinVersionKey)
            UserDefaults.standard.set(false, forKey: dirtyKey)
            DebugFileLogger.log("[HotwordSync] updated cloud table \(tableID) with \(words.count) words")

        } else {
            // No table yet: check if one already exists on the server (e.g. created manually)
            let tables = try await manager.listTables(credentials: credentials)
            if let existing = tables.first(where: { $0.tableName == tableName }) {
                // Found existing table, adopt it and update
                UserDefaults.standard.set(existing.tableID, forKey: tableIDKey)
                try await manager.updateTable(credentials: credentials, tableID: existing.tableID, words: words)
                UserDefaults.standard.set(currentVersion, forKey: builtinVersionKey)
                UserDefaults.standard.set(false, forKey: dirtyKey)
                DebugFileLogger.log("[HotwordSync] adopted existing cloud table \(existing.tableID), updated with \(words.count) words")

            } else {
                // Create new table
                let tableID = try await manager.createTable(
                    credentials: credentials,
                    name: tableName,
                    words: words
                )
                UserDefaults.standard.set(tableID, forKey: tableIDKey)
                UserDefaults.standard.set(currentVersion, forKey: builtinVersionKey)
                UserDefaults.standard.set(false, forKey: dirtyKey)
                DebugFileLogger.log("[HotwordSync] created cloud table \(tableID) with \(words.count) words")
            }
        }

        // Also update the ASRBiasSettings so recognition uses the cloud table
        var biasSettings = ASRBiasSettingsStorage.load()
        if let tableID = UserDefaults.standard.string(forKey: tableIDKey), !tableID.isEmpty {
            biasSettings.boostingTableID = tableID
            ASRBiasSettingsStorage.save(biasSettings)
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
