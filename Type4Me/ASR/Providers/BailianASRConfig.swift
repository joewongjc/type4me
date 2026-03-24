import Foundation

struct BailianASRConfig: ASRProviderConfig, Sendable {

    static let provider = ASRProvider.bailian
    static let displayName = L("阿里云百炼", "Alibaba Cloud Bailian")
    static let defaultModel = "fun-asr-realtime"
    static let supportedLanguageHints = ["zh", "en", "ja"]

    static var credentialFields: [CredentialField] {[
        CredentialField(
            key: "apiKey",
            label: "API Key",
            placeholder: "sk-...",
            isSecure: true,
            isOptional: false,
            defaultValue: ""
        ),
        CredentialField(
            key: "model",
            label: "Model",
            placeholder: defaultModel,
            isSecure: false,
            isOptional: false,
            defaultValue: defaultModel
        ),
        CredentialField(
            key: "deviceId",
            label: "Device ID",
            placeholder: L("客户端唯一标识", "Stable client identifier"),
            isSecure: false,
            isOptional: true,
            defaultValue: ASRIdentityStore.loadOrCreateUID()
        ),
        CredentialField(
            key: "languageHint",
            label: "Language Hint",
            placeholder: "zh / en / ja",
            isSecure: false,
            isOptional: true,
            defaultValue: ""
        ),
        CredentialField(
            key: "vocabularyId",
            label: "Vocabulary ID",
            placeholder: L("热词词表 ID", "Hotword vocabulary ID"),
            isSecure: false,
            isOptional: true,
            defaultValue: ""
        ),
    ]}

    let apiKey: String
    let model: String
    let deviceId: String
    let languageHint: String
    let vocabularyId: String

    init?(credentials: [String: String]) {
        guard let apiKey = Self.sanitized(credentials["apiKey"]),
              !apiKey.isEmpty
        else { return nil }

        self.apiKey = apiKey
        self.model = Self.sanitized(credentials["model"]) ?? Self.defaultModel
        self.deviceId = Self.sanitized(credentials["deviceId"]) ?? ASRIdentityStore.loadOrCreateUID()

        let rawLanguageHint = Self.sanitized(credentials["languageHint"])?.lowercased() ?? ""
        self.languageHint = Self.supportedLanguageHints.contains(rawLanguageHint) ? rawLanguageHint : ""
        self.vocabularyId = Self.sanitized(credentials["vocabularyId"]) ?? ""
    }

    func toCredentials() -> [String: String] {
        [
            "apiKey": apiKey,
            "model": model,
            "deviceId": deviceId,
            "languageHint": languageHint,
            "vocabularyId": vocabularyId,
        ]
    }

    var isValid: Bool {
        !apiKey.isEmpty && !model.isEmpty && !deviceId.isEmpty
    }

    private static func sanitized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else {
            return nil
        }
        return trimmed
    }
}
