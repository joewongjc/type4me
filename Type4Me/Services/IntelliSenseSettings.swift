import Foundation
import Type4MeIntelliSenseCore

extension Notification.Name {
    static let intelliSenseSettingsDidChange = Notification.Name(
        "Type4Me.intelliSenseSettingsDidChange"
    )
}

actor IntelliSenseSettingsStore {
    static let shared = IntelliSenseSettingsStore()

    static let migrationDefaultsKey = "tf_intelliSenseSettingsMigratedV1"
    static let legacyCorrectionDefaultsKey = "tf_autoCorrectionLearningEnabled"

    let fileURL: URL
    private let userDefaults: UserDefaults
    private var cached: IntelliSenseSettings?

    init(fileURL: URL? = nil, userDefaultsSuiteName: String? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let directory = AppDataLocation.directory
            self.fileURL = directory.appendingPathComponent("intelli-sense-settings.json")
        }
        if let userDefaultsSuiteName {
            self.userDefaults = UserDefaults(suiteName: userDefaultsSuiteName) ?? .standard
        } else {
            self.userDefaults = .standard
        }
    }

    func load() -> IntelliSenseSettings {
        if let cached { return cached }

        let fileExists = FileManager.default.fileExists(atPath: fileURL.path)
        let decoded: IntelliSenseSettings?
        if let data = try? Data(contentsOf: fileURL) {
            decoded = try? JSONDecoder().decode(IntelliSenseSettings.self, from: data)
        } else {
            decoded = nil
        }

        // Unknown or corrupt persisted data must not be overwritten implicitly.
        if fileExists, decoded == nil {
            let fallback = IntelliSenseSettings()
            cached = fallback
            return fallback
        }

        var settings = (decoded ?? IntelliSenseSettings()).normalized()
        if !userDefaults.bool(forKey: Self.migrationDefaultsKey) {
            if userDefaults.object(forKey: Self.legacyCorrectionDefaultsKey) != nil {
                settings.correctionDetectionEnabled = userDefaults.bool(
                    forKey: Self.legacyCorrectionDefaultsKey
                )
            }
            do {
                try persist(settings)
                userDefaults.set(true, forKey: Self.migrationDefaultsKey)
            } catch {
                NSLog("[IntelliSense] settings migration save failed: %@", String(describing: error))
            }
        }

        cached = settings
        return settings
    }

    @discardableResult
    func save(_ settings: IntelliSenseSettings) throws -> IntelliSenseSettings {
        let normalized = settings.normalized()
        try persist(normalized)
        cached = normalized
        Task { @MainActor in
            NotificationCenter.default.post(name: .intelliSenseSettingsDidChange, object: nil)
        }
        return normalized
    }

    func invalidateCache() {
        cached = nil
    }

    private func persist(_ settings: IntelliSenseSettings) throws {
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
