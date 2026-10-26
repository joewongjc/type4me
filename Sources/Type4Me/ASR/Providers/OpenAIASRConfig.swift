import Foundation

struct OpenAIASRConfig: ASRProviderConfig, Sendable {

    static let provider = ASRProvider.openai
    static let displayName = "OpenAI"
    static let defaultModel = "gpt-4o-transcribe"
    static let defaultBaseURL = "https://api.openai.com/v1"

    static let credentialFields: [CredentialField] = [
        CredentialField(key: "apiKey", label: L("API Key", "API Key"), placeholder: "sk-...", isSecure: true, isOptional: false, defaultValue: ""),
        CredentialField(
            key: "model", label: L("模型", "Model"),
            placeholder: defaultModel,
            isSecure: false, isOptional: true, defaultValue: defaultModel,
            options: [
                FieldOption(value: "gpt-4o-transcribe", label: "GPT-4o Transcribe ($0.36/hr)"),
                FieldOption(value: "gpt-4o-mini-transcribe", label: "GPT-4o Mini Transcribe ($0.18/hr)"),
                FieldOption(value: "whisper-1", label: "Whisper ($0.36/hr)"),
            ]
        ),
        CredentialField(
            key: "baseURL", label: L("Base URL", "Base URL"),
            placeholder: defaultBaseURL,
            isSecure: false, isOptional: true, defaultValue: defaultBaseURL
        ),
    ]

    let apiKey: String
    let model: String
    let baseURL: String

    init?(credentials: [String: String]) {
        guard let key = credentials["apiKey"], !key.isEmpty else { return nil }
        self.apiKey = key
        self.model = credentials["model"]?.isEmpty == false
            ? credentials["model"]!
            : Self.defaultModel
        let configuredBaseURL = credentials["baseURL"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedBaseURL = configuredBaseURL?.isEmpty == false
            ? configuredBaseURL!
            : Self.defaultBaseURL
        self.baseURL = resolvedBaseURL.hasSuffix("/")
            ? String(resolvedBaseURL.dropLast())
            : resolvedBaseURL
    }

    func toCredentials() -> [String: String] {
        ["apiKey": apiKey, "model": model, "baseURL": baseURL]
    }

    var isValid: Bool { !apiKey.isEmpty }
}
