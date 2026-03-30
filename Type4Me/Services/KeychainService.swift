import Foundation

enum KeychainService {

    private static var credentialsURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Type4Me", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("credentials.json")
    }

    // MARK: - Core read/write (now supports nested objects)

    private static func loadAll() -> [String: Any] {
        guard let data = try? Data(contentsOf: credentialsURL),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return dict
    }

    private static func saveAll(_ dict: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
        try data.write(to: credentialsURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: credentialsURL.path
        )
    }

    // MARK: - Scalar key-value (for LLM keys and misc)

    static func save(key: String, value: String) throws {
        var dict = loadAll()
        dict[key] = value
        try saveAll(dict)
    }

    static func load(key: String) -> String? {
        loadAll()[key] as? String
    }

    @discardableResult
    static func delete(key: String) -> Bool {
        var dict = loadAll()
        guard dict.removeValue(forKey: key) != nil else { return false }
        return (try? saveAll(dict)) != nil
    }

    // MARK: - Selected ASR Provider (UserDefaults)

    private static let selectedProviderKey = "tf_selectedASRProvider"

    static var selectedASRProvider: ASRProvider {
        get {
            guard let raw = UserDefaults.standard.string(forKey: selectedProviderKey),
                  let provider = ASRProvider(rawValue: raw)
            else { return .volcano }
            return provider
        }
        set {
            let previous = selectedASRProvider
            UserDefaults.standard.set(newValue.rawValue, forKey: selectedProviderKey)
            guard previous != newValue else { return }
            NotificationCenter.default.post(name: .asrProviderDidChange, object: newValue)
        }
    }

    // MARK: - ASR Credentials (provider-aware)

    private static func asrStorageKey(for provider: ASRProvider) -> String {
        "tf_asr_\(provider.rawValue)"
    }

    static func saveASRCredentials(for provider: ASRProvider, values: [String: String]) throws {
        var dict = loadAll()
        dict[asrStorageKey(for: provider)] = values
        try saveAll(dict)
    }

    static func loadASRCredentials(for provider: ASRProvider) -> [String: String]? {
        let dict = loadAll()
        return dict[asrStorageKey(for: provider)] as? [String: String]
    }

    static func loadASRConfig(for provider: ASRProvider) -> (any ASRProviderConfig)? {
        guard let configType = ASRProviderRegistry.configType(for: provider) else {
            return nil
        }

        if let values = loadASRCredentials(for: provider) {
            return configType.init(credentials: values)
        }

        let defaultValues: [String: String] = Dictionary(
            uniqueKeysWithValues: configType.credentialFields.compactMap { field in
                guard !field.defaultValue.isEmpty else { return nil }
                return (field.key, field.defaultValue)
            }
        )

        if defaultValues.isEmpty && configType.credentialFields.isEmpty {
            return configType.init(credentials: [:])
        }

        return configType.init(credentials: defaultValues)
    }

    /// Load config for the currently selected provider.
    static func loadSelectedASRConfig() -> (any ASRProviderConfig)? {
        loadASRConfig(for: selectedASRProvider)
    }

    // MARK: - Legacy ASR convenience (volcano-specific, kept for migration)

    static func saveASRCredentials(appKey: String, accessKey: String, resourceId: String) throws {
        try saveASRCredentials(for: .volcano, values: [
            "appKey": appKey,
            "accessKey": accessKey,
            "resourceId": resourceId,
        ])
    }

    static func loadASRConfig() -> VolcanoASRConfig? {
        loadASRConfig(for: .volcano) as? VolcanoASRConfig
    }

    // MARK: - Selected LLM Provider (UserDefaults)

    private static let selectedLLMProviderKey = "tf_selectedLLMProvider"

    static var selectedLLMProvider: LLMProvider {
        get {
            guard let raw = UserDefaults.standard.string(forKey: selectedLLMProviderKey),
                  let provider = LLMProvider(rawValue: raw)
            else { return .doubao }
            return provider
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: selectedLLMProviderKey)
        }
    }

    // MARK: - LLM Credentials (provider-aware)

    private static func llmStorageKey(for provider: LLMProvider) -> String {
        "tf_llm_\(provider.rawValue)"
    }

    static func saveLLMCredentials(for provider: LLMProvider, values: [String: String]) throws {
        var dict = loadAll()
        dict[llmStorageKey(for: provider)] = values
        try saveAll(dict)
    }

    static func loadLLMCredentials(for provider: LLMProvider) -> [String: String]? {
        let dict = loadAll()
        return dict[llmStorageKey(for: provider)] as? [String: String]
    }

    static func loadLLMProviderConfig(for provider: LLMProvider) -> (any LLMProviderConfig)? {
        guard let values = loadLLMCredentials(for: provider),
              let configType = LLMProviderRegistry.configType(for: provider)
        else { return nil }
        return configType.init(credentials: values)
    }

    /// Load config for the currently selected LLM provider.
    static func loadSelectedLLMConfig() -> (any LLMProviderConfig)? {
        loadLLMProviderConfig(for: selectedLLMProvider)
    }

    // MARK: - LLM Config convenience (backward compat)

    static func saveLLMCredentials(apiKey: String, model: String, baseURL: String = "") throws {
        try saveLLMCredentials(for: .doubao, values: [
            "apiKey": apiKey, "model": model, "baseURL": baseURL,
        ])
    }

    /// Load LLMConfig for the currently selected provider.
    static func loadLLMConfig() -> LLMConfig? {
        if selectedLLMProvider == .localQwen {
            // LLM runs on Qwen3-ASR server (shares Metal GPU lock); fall back to primary
            let port = SenseVoiceServerManager.currentQwen3Port ?? SenseVoiceServerManager.currentPort
            guard let port else { return nil }
            return LLMConfig(apiKey: "", model: "qwen3-4b", baseURL: "http://127.0.0.1:\(port)/v1")
        }
        guard let config = loadSelectedLLMConfig() else { return nil }
        return config.toLLMConfig()
    }

    // MARK: - Migration (call once at app launch)

    /// Migrate legacy flat keys to provider-grouped format,
    /// move Application Support directory, and migrate UserDefaults from old bundle ID.
    static func migrateIfNeeded() {
        migrateAppSupportDirectory()
        migrateUserDefaults()
        let dict = loadAll()

        var migrated = false
        var mutableDict = dict

        // Migrate ASR: tf_appKey/tf_accessKey/tf_resourceId → tf_asr_volcano
        if let appKey = dict["tf_appKey"] as? String, !appKey.isEmpty,
           dict[asrStorageKey(for: .volcano)] == nil {
            let accessKey = dict["tf_accessKey"] as? String ?? ""
            let resourceId = dict["tf_resourceId"] as? String ?? "volc.bigasr.sauc.duration"
            mutableDict[asrStorageKey(for: .volcano)] = [
                "appKey": appKey,
                "accessKey": accessKey,
                "resourceId": resourceId,
            ]
            mutableDict.removeValue(forKey: "tf_appKey")
            mutableDict.removeValue(forKey: "tf_accessKey")
            mutableDict.removeValue(forKey: "tf_resourceId")
            migrated = true
            NSLog("[KeychainService] Migrated legacy ASR credentials to tf_asr_volcano")
        }

        // Migrate mistakenly stored Bailian ASR credentials from tf_asr_aliyun → tf_asr_bailian
        if let aliyunValues = dict[asrStorageKey(for: .aliyun)] as? [String: String],
           let apiKey = aliyunValues["apiKey"], !apiKey.isEmpty,
           dict[asrStorageKey(for: .bailian)] == nil {
            mutableDict[asrStorageKey(for: .bailian)] = aliyunValues
            mutableDict.removeValue(forKey: asrStorageKey(for: .aliyun))
            if selectedASRProvider == .aliyun {
                selectedASRProvider = .bailian
            }
            migrated = true
            NSLog("[KeychainService] Migrated Bailian ASR credentials from tf_asr_aliyun → tf_asr_bailian")
        }

        // Migrate LLM: tf_llmEndpointId → tf_llmModel
        if let endpointId = dict["tf_llmEndpointId"] as? String, !endpointId.isEmpty,
           dict["tf_llmModel"] == nil {
            mutableDict["tf_llmModel"] = endpointId
            mutableDict.removeValue(forKey: "tf_llmEndpointId")
            migrated = true
            NSLog("[KeychainService] Migrated tf_llmEndpointId → tf_llmModel")
        }

        // Migrate LLM: flat keys → tf_llm_doubao (provider-grouped)
        if let apiKey = dict["tf_llmApiKey"] as? String, !apiKey.isEmpty,
           dict[llmStorageKey(for: .doubao)] == nil {
            let model = (dict["tf_llmModel"] as? String) ?? ""
            let baseURL = (dict["tf_llmBaseURL"] as? String) ?? ""
            mutableDict[llmStorageKey(for: .doubao)] = [
                "apiKey": apiKey,
                "model": model,
                "baseURL": baseURL.isEmpty ? LLMProvider.doubao.defaultBaseURL : baseURL,
            ]
            mutableDict.removeValue(forKey: "tf_llmApiKey")
            mutableDict.removeValue(forKey: "tf_llmModel")
            mutableDict.removeValue(forKey: "tf_llmBaseURL")
            migrated = true
            NSLog("[KeychainService] Migrated flat LLM keys to tf_llm_doubao")
        }

        // Migrate MiniMax CN: api.minimax.chat → api.minimaxi.com (old domain was incorrect)
        let minimaxCNKey = llmStorageKey(for: .minimaxCN)
        if var minimaxCreds = mutableDict[minimaxCNKey] as? [String: String],
           let baseURL = minimaxCreds["baseURL"],
           baseURL.contains("api.minimax.chat") {
            minimaxCreds["baseURL"] = baseURL.replacingOccurrences(
                of: "api.minimax.chat", with: "api.minimaxi.com"
            )
            mutableDict[minimaxCNKey] = minimaxCreds
            migrated = true
            NSLog("[KeychainService] Migrated MiniMax CN base URL: api.minimax.chat → api.minimaxi.com")
        }

        if migrated {
            try? saveAll(mutableDict)
        }
    }

    // MARK: - Application Support Directory Migration

    /// Merge ~/Library/Application Support/TypeFlow/ files into Type4Me/ (one-time, from old project name).
    /// Uses file-level merge instead of directory rename, because other init code may create
    /// the new directory before this migration runs.
    private static func migrateAppSupportDirectory() {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let oldDir = appSupport.appendingPathComponent("TypeFlow", isDirectory: true)
        let newDir = appSupport.appendingPathComponent("Type4Me", isDirectory: true)

        // Old directory must exist and contain real data (credentials.json is the marker)
        guard fm.fileExists(atPath: oldDir.appendingPathComponent("credentials.json").path) else { return }

        try? fm.createDirectory(at: newDir, withIntermediateDirectories: true)

        // Move each file from old → new, skipping files that already exist in new
        guard let contents = try? fm.contentsOfDirectory(atPath: oldDir.path) else { return }
        var movedCount = 0
        for item in contents {
            let src = oldDir.appendingPathComponent(item)
            let dst = newDir.appendingPathComponent(item)
            if !fm.fileExists(atPath: dst.path) {
                do {
                    try fm.moveItem(at: src, to: dst)
                    movedCount += 1
                } catch {
                    NSLog("[KeychainService] Failed to migrate %@: %@", item, error.localizedDescription)
                }
            }
        }

        if movedCount > 0 {
            NSLog("[KeychainService] Migrated %d files from TypeFlow → Type4Me", movedCount)
        }

        // Clean up old directory if empty
        if let remaining = try? fm.contentsOfDirectory(atPath: oldDir.path), remaining.isEmpty {
            try? fm.removeItem(at: oldDir)
        }
    }

    // MARK: - UserDefaults Migration (old bundle ID)

    /// Copy tf_ keys from old com.typeflow.app UserDefaults to current domain.
    /// One-time: skips if already migrated (marker key present).
    private static func migrateUserDefaults() {
        let marker = "tf_migratedFromTypeFlow"
        guard !UserDefaults.standard.bool(forKey: marker) else { return }

        guard let oldDefaults = UserDefaults(suiteName: "com.typeflow.app") else { return }
        let oldDict = oldDefaults.dictionaryRepresentation()
        let tfKeys = oldDict.keys.filter { $0.hasPrefix("tf_") }

        guard !tfKeys.isEmpty else {
            UserDefaults.standard.set(true, forKey: marker)
            return
        }

        var count = 0
        for key in tfKeys {
            // Don't overwrite if the new domain already has a value
            if UserDefaults.standard.object(forKey: key) == nil {
                UserDefaults.standard.set(oldDict[key], forKey: key)
                count += 1
            }
        }

        UserDefaults.standard.set(true, forKey: marker)
        if count > 0 {
            NSLog("[KeychainService] Migrated %d UserDefaults keys from com.typeflow.app", count)
        }
    }
}

enum KeychainError: Error {
    case saveFailed(OSStatus)
}
