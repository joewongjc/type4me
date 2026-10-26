import Foundation

struct ASRBiasSettings: Codable, Sendable, Equatable {
    var boostingTableID: String = ""
    var contextHistoryLength: Int = 0

    var sanitized: ASRBiasSettings {
        ASRBiasSettings(
            boostingTableID: boostingTableID.trimmingCharacters(in: .whitespacesAndNewlines),
            contextHistoryLength: max(0, contextHistoryLength)
        )
    }
}

enum ASRBiasSettingsStorage {

    private static let key = "tf_asrBiasSettings"

    static func load() -> ASRBiasSettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              let settings = try? JSONDecoder().decode(ASRBiasSettings.self, from: data)
        else {
            return ASRBiasSettings()
        }
        return settings.sanitized
    }

    static func save(_ settings: ASRBiasSettings) {
        guard let data = try? JSONEncoder().encode(settings.sanitized) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

enum ASRIdentityStore {

    private static let key = "tf_asrUID"

    static func loadOrCreateUID() -> String {
        if let existing = UserDefaults.standard.string(forKey: key),
           !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return existing
        }

        let newValue = "type4me-\(UUID().uuidString.lowercased())"
        UserDefaults.standard.set(newValue, forKey: key)
        return newValue
    }
}
