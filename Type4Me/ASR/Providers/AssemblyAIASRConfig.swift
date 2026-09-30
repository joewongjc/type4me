import Foundation

struct AssemblyAIASRConfig: ASRProviderConfig, Sendable {

    static let provider = ASRProvider.assemblyai
    static let displayName = "AssemblyAI"
    static let defaultModel = "universal-3-6-pro"
    static let supportedModels = [
        "universal-3-5-pro",
        "u3-rt-pro",
        "universal-streaming-multilingual",
        "universal-streaming-english",
    ]

    static var credentialFields: [CredentialField] {[
        CredentialField(
            key: "apiKey",
            label: L("API Key", "API Key"),
            placeholder: L("粘贴 API Key", "Paste your API Key"),
            isSecure: true,
            isOptional: false,
            defaultValue: ""
        ),
        CredentialField(
            key: "model",
            label: L("流式模型", "Streaming Model"),
            placeholder: defaultModel,
            isSecure: false,
            isOptional: false,
            defaultValue: defaultModel,
            options: supportedModels.map { FieldOption(value: $0, label: $0) }
        ),
    ]}

    let apiKey: String
    let model: String

    init?(credentials: [String: String]) {
        guard let apiKey = Self.sanitized(credentials["apiKey"]),
              !apiKey.isEmpty
        else {
            return nil
        }

        let rawModel = Self.sanitized(credentials["model"])?.lowercased() ?? ""
        self.apiKey = apiKey
        self.model = Self.supportedModels.contains(rawModel) ? rawModel : Self.defaultModel
    }

    func toCredentials() -> [String: String] {
        [
            "apiKey": apiKey,
            "model": model,
        ]
    }

    var isValid: Bool {
        !apiKey.isEmpty && Self.supportedModels.contains(model)
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
