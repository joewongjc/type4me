import Foundation

enum AppEdition: String, Codable {
    case member   // 官方会员
    case byoKey   // 自带 API
}

enum AppEditionMigration {
    private static let editionKey = "tf_app_edition"
    private static let legacyCloudKey = "tf_use_cloud"

    /// Run once on app launch. Migrates tf_use_cloud → tf_app_edition.
    static func migrateIfNeeded() {
        let defaults = UserDefaults.standard
        // Already migrated
        if defaults.string(forKey: editionKey) != nil { return }
        // Legacy flag exists
        if defaults.object(forKey: legacyCloudKey) != nil {
            let wasCloud = defaults.bool(forKey: legacyCloudKey)
            defaults.set(
                (wasCloud ? AppEdition.member : AppEdition.byoKey).rawValue,
                forKey: editionKey
            )
        }
        // else: fresh install, leave nil → forces setup wizard
    }

    /// Current edition, nil if user hasn't chosen yet.
    static var current: AppEdition? {
        get {
            guard let raw = UserDefaults.standard.string(forKey: editionKey) else { return nil }
            return AppEdition(rawValue: raw)
        }
        set {
            UserDefaults.standard.set(newValue?.rawValue, forKey: editionKey)
        }
    }

    /// Switch edition with provider side-effects.
    static func switchTo(_ edition: AppEdition) {
        // Save current BYOK provider before switching away
        if current == .byoKey {
            let currentProvider = KeychainService.selectedASRProvider
            if currentProvider != .cloud {
                KeychainService.lastBYOKProvider = currentProvider
            }
        }
        current = edition
        switch edition {
        case .member:
            KeychainService.selectedASRProvider = .cloud
        case .byoKey:
            KeychainService.selectedASRProvider = KeychainService.lastBYOKProvider
        }
    }
}
