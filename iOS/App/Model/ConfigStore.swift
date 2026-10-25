import Foundation
import Security
import Type4MeTransferCore

/// The speech services and the text models, synced from the Mac or entered on
/// the iPhone. One of each is active; the others are kept so Settings can
/// switch between them without typing keys again. Secrets live in this
/// device's Keychain only; the keyboard never needs them because all network
/// calls run in the app.
enum ConfigStore {
    enum Kind: String {
        case asr, llm

        var profilesAccount: String { rawValue + ".profiles" }
    }

    private static let service = "com.type4me.ios.endpoints"
    private static let metaKey = "importMeta"

    struct ImportMeta: Codable, Equatable {
        var sourceName: String?
        var importedAt: Date
        /// Last time a service was edited by hand on this iPhone.
        var editedAt: Date?
    }

    /// What to take from a synced payload. Everything by default.
    struct ImportSelection: Equatable {
        /// Providers of the speech services to keep.
        var asrs: Set<String>
        /// Becomes the active speech service; must be one of `asrs`.
        var activeASR: String?
        /// Providers of the text models to keep.
        var llms: Set<String>
        /// Becomes the active text model; must be one of `llms`.
        var activeLLM: String?
        var modes: Set<String>
        var hotwords: Bool
        var snippets: Bool

        init(all payload: Type4MeTransferPayload) {
            asrs = Set(payload.allASRs.map(\.provider))
            activeASR = payload.allASRs.first?.provider
            llms = Set(payload.allLLMs.map(\.provider))
            activeLLM = payload.allLLMs.first?.provider
            modes = Set((payload.modes ?? []).map(\.id))
            hotwords = !(payload.hotwords ?? []).isEmpty
            snippets = !(payload.snippets ?? []).isEmpty
        }

        var isEmpty: Bool { asrs.isEmpty && llms.isEmpty && modes.isEmpty && !hotwords && !snippets }
    }

    static func save(_ payload: Type4MeTransferPayload) throws {
        try save(payload, selection: ImportSelection(all: payload))
    }

    /// Applies the services part of a sync. Modes go through `ModeLibrary`,
    /// vocabulary through `VocabularyStore`.
    static func save(_ payload: Type4MeTransferPayload, selection: ImportSelection) throws {
        let asrs = payload.allASRs.filter { selection.asrs.contains($0.provider) }
        try saveProfiles(asrs, active: selection.activeASR, kind: .asr)
        let llms = payload.allLLMs.filter { selection.llms.contains($0.provider) }
        try saveProfiles(llms, active: selection.activeLLM, kind: .llm)
        if !asrs.isEmpty || !llms.isEmpty {
            let meta = ImportMeta(sourceName: payload.sourceName, importedAt: Date())
            UserDefaults.standard.set(try JSONEncoder().encode(meta), forKey: metaKey)
        }
        refreshSharedFlags()
    }

    private static func saveProfiles(_ endpoints: [Type4MeTransferPayload.Endpoint], active: String?, kind: Kind) throws {
        for endpoint in endpoints { upsertProfile(endpoint, kind: kind) }
        if let first = endpoints.first(where: { $0.provider == active }) ?? endpoints.first {
            try saveEndpoint(first, account: kind.rawValue)
        }
    }

    /// Saves one service entered in Settings, leaving the other kind alone.
    static func save(_ endpoint: Type4MeTransferPayload.Endpoint, as kind: Kind) throws {
        try saveEndpoint(endpoint, account: kind.rawValue)
        upsertProfile(endpoint, kind: kind)
        var meta = self.meta ?? ImportMeta(sourceName: nil, importedAt: Date())
        meta.editedAt = Date()
        UserDefaults.standard.set(try JSONEncoder().encode(meta), forKey: metaKey)
        refreshSharedFlags()
    }

    static func remove(_ kind: Kind) {
        if let active = active(kind) {
            let rest = profiles(kind).filter { $0.provider != active.provider }
            try? saveData(JSONEncoder().encode(rest), account: kind.profilesAccount)
        }
        SecItemDelete(query(account: kind.rawValue) as CFDictionary)
        if asr == nil, llm == nil { UserDefaults.standard.removeObject(forKey: metaKey) }
        refreshSharedFlags()
    }

    static var asr: Type4MeTransferPayload.Endpoint? { active(.asr) }
    static var llm: Type4MeTransferPayload.Endpoint? { active(.llm) }

    static func active(_ kind: Kind) -> Type4MeTransferPayload.Endpoint? {
        loadEndpoint(account: kind.rawValue)
    }

    // MARK: - Profiles

    /// Every service of a kind kept on this iPhone, one per provider.
    static func profiles(_ kind: Kind) -> [Type4MeTransferPayload.Endpoint] {
        var request = query(account: kind.profilesAccount)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let profiles = try? JSONDecoder().decode([Type4MeTransferPayload.Endpoint].self, from: data)
        else { return active(kind).map { [$0] } ?? [] }
        return profiles
    }

    static var llmProfiles: [Type4MeTransferPayload.Endpoint] { profiles(.llm) }

    static func profile(for provider: String, kind: Kind = .llm) -> Type4MeTransferPayload.Endpoint? {
        profiles(kind).first { $0.provider == provider }
    }

    private static func upsertProfile(_ endpoint: Type4MeTransferPayload.Endpoint, kind: Kind) {
        var profiles = profiles(kind).filter { $0.provider != endpoint.provider }
        profiles.append(endpoint)
        try? saveData(JSONEncoder().encode(profiles), account: kind.profilesAccount)
    }

    static var meta: ImportMeta? {
        guard let data = UserDefaults.standard.data(forKey: metaKey) else { return nil }
        return try? JSONDecoder().decode(ImportMeta.self, from: data)
    }

    static func clearAll() {
        for account in ["asr", "llm", Kind.asr.profilesAccount, Kind.llm.profilesAccount] {
            SecItemDelete(query(account: account) as CFDictionary)
        }
        UserDefaults.standard.removeObject(forKey: metaKey)
        refreshSharedFlags()
    }

    /// Mirrors "is anything configured" into the App Group so the keyboard
    /// can grey out modes that need the text model.
    static func refreshSharedFlags() {
        SharedSettings.asrConfigured = asr.flatMap(PhoneASR.config(for:)) != nil
        SharedSettings.llmConfigured = llm.flatMap(LLMEndpointConfig.init(endpoint:)) != nil
    }

    // MARK: - Keychain

    private static func query(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private static func saveEndpoint(_ endpoint: Type4MeTransferPayload.Endpoint, account: String) throws {
        try saveData(JSONEncoder().encode(endpoint), account: account)
    }

    private static func saveData(_ data: Data, account: String) throws {
        SecItemDelete(query(account: account) as CFDictionary)
        var item = query(account: account)
        item[kSecValueData as String] = data
        // Readable while the phone is locked after first unlock, so a
        // dictation started from the lock screen keyboard still works.
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    private static func loadEndpoint(account: String) -> Type4MeTransferPayload.Endpoint? {
        var request = query(account: account)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return try? JSONDecoder().decode(Type4MeTransferPayload.Endpoint.self, from: data)
    }
}

/// Display names for provider IDs that arrive from the Mac, from the same
/// provider enums the Mac uses.
enum ProviderNames {
    static func asr(_ id: String) -> String { PhoneASR.name(id) }

    static func llm(_ id: String) -> String {
        LLMProvider(rawValue: id)?.displayName ?? id
    }
}
