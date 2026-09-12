import Foundation
import CoreGraphics

extension Notification.Name {
    static let reviseSettingsDidChange = Notification.Name(
        "Type4Me.reviseSettingsDidChange"
    )
}

struct ReviseExcludedApp: Codable, Equatable, Identifiable, Hashable, Sendable {
    var bundleIdentifier: String
    var displayName: String

    var id: String { bundleIdentifier }

    init(bundleIdentifier: String, displayName: String) {
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
    }
}

struct ReviseSettings: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    static let defaultBindingID = UUID(
        uuidString: "20000000-0000-0000-0000-000000000001"
    )!
    static let defaultKeyCode = 15 // ANSI R
    static let defaultModifiers = CGEventFlags.maskSecondaryFn.rawValue
    static let defaultStyle = ProcessingMode.HotkeyStyle.toggle

    static var defaultHotkey: HotkeyBinding {
        HotkeyBinding(
            id: defaultBindingID,
            keyCode: defaultKeyCode,
            modifiers: defaultModifiers,
            style: defaultStyle
        )
    }

    var schemaVersion: Int = currentSchemaVersion
    var enabled: Bool = true
    var hotkey: HotkeyBinding? = defaultHotkey
    var excludedApps: [ReviseExcludedApp] = []

    init(
        schemaVersion: Int = currentSchemaVersion,
        enabled: Bool = true,
        hotkey: HotkeyBinding? = defaultHotkey,
        excludedApps: [ReviseExcludedApp] = []
    ) {
        self.schemaVersion = schemaVersion
        self.enabled = enabled
        self.hotkey = hotkey
        self.excludedApps = excludedApps
    }

    func isExcluded(bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        return excludedApps.contains {
            $0.bundleIdentifier.caseInsensitiveCompare(bundleIdentifier) == .orderedSame
        }
    }

    func normalized() -> Self {
        var copy = self
        copy.schemaVersion = Self.currentSchemaVersion
        var seen = Set<String>()
        copy.excludedApps = excludedApps.compactMap { app in
            let bundleID = app.bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !bundleID.isEmpty else { return nil }
            let key = bundleID.lowercased()
            guard seen.insert(key).inserted else { return nil }
            let displayName = app.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            return ReviseExcludedApp(
                bundleIdentifier: bundleID,
                displayName: displayName.isEmpty ? bundleID : displayName
            )
        }
        return copy
    }
}

final class ReviseSettingsStore: @unchecked Sendable {
    static let shared = ReviseSettingsStore()

    static let migrationDefaultsKey = "tf_reviseSettingsMigratedV1"
    static let runtimeEnabledDefaultsKey = "tf_reviseRuntimeEnabled"

    let fileURL: URL
    private let userDefaults: UserDefaults
    private let lock = NSLock()
    private var cached: ReviseSettings?

    init(fileURL: URL? = nil, userDefaultsSuiteName: String? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let directory = AppDataLocation.directory
            self.fileURL = directory.appendingPathComponent("revise-settings.json")
        }
        if let userDefaultsSuiteName {
            self.userDefaults = UserDefaults(suiteName: userDefaultsSuiteName) ?? .standard
        } else {
            self.userDefaults = .standard
        }
    }

    static var isRuntimeEnabled: Bool {
        if let explicit = UserDefaults.standard.object(forKey: runtimeEnabledDefaultsKey) as? Bool {
            return explicit
        }
        return true
    }

    func isReviseActive() -> Bool {
        let current = load()
        return current.enabled && Self.isRuntimeEnabled
    }

    func load() -> ReviseSettings {
        lock.lock()
        defer { lock.unlock() }

        if let cached { return cached }

        let fileExists = FileManager.default.fileExists(atPath: fileURL.path)
        let decoded: ReviseSettings?
        if let data = try? Data(contentsOf: fileURL) {
            decoded = try? JSONDecoder().decode(ReviseSettings.self, from: data)
        } else {
            decoded = nil
        }

        // Unknown or corrupt persisted data must not be overwritten implicitly.
        if fileExists, decoded == nil {
            let fallback = ReviseSettings(enabled: false)
            cached = fallback
            return fallback
        }

        var initialSettings = decoded ?? ReviseSettings()
        if !userDefaults.bool(forKey: Self.migrationDefaultsKey) {
            if decoded == nil {
                let existingModes = ModeStorage().load()
                let defaultCode = ReviseSettings.defaultKeyCode
                let defaultMods = ReviseSettings.defaultModifiers
                let hasConflict = existingModes.contains { mode in
                    mode.allHotkeyBindings.contains { hk in
                        hk.keyCode == defaultCode && (hk.modifiers ?? 0) == defaultMods
                    }
                }
                if hasConflict {
                    initialSettings.hotkey = nil
                }
            }
            let normalizedSettings = initialSettings.normalized()
            do {
                try persist(normalizedSettings)
                userDefaults.set(true, forKey: Self.migrationDefaultsKey)
            } catch {
                NSLog("[Revise] settings migration save failed: %@", String(describing: error))
            }
            cached = normalizedSettings
            return normalizedSettings
        }

        let settings = initialSettings.normalized()
        cached = settings
        return settings
    }

    @discardableResult
    func save(_ settings: ReviseSettings) throws -> ReviseSettings {
        lock.lock()
        defer { lock.unlock() }

        let normalized = settings.normalized()
        try persist(normalized)
        cached = normalized
        Task { @MainActor in
            NotificationCenter.default.post(name: .reviseSettingsDidChange, object: nil)
        }
        return normalized
    }

    func invalidateCache() {
        lock.lock()
        defer { lock.unlock() }
        cached = nil
    }

    private func persist(_ settings: ReviseSettings) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(settings)
        try data.write(to: fileURL, options: .atomic)
    }
}
