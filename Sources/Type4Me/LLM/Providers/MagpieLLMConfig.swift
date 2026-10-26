import Foundation

struct MagpieLLMConfig: LLMProviderConfig, Sendable {

    static let provider = LLMProvider.magpie

    static var credentialFields: [CredentialField] {
        [
            CredentialField(
                key: "model",
                label: L("模型", "Model"),
                placeholder: "",
                isSecure: false,
                isOptional: false,
                defaultValue: "",
                options: [],
                allowCustomInput: true
            ),
        ]
    }

    let model: String
    let baseURL: String
    let apiKey: String

    init?(credentials: [String: String]) {
        let model = credentials["model"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !model.isEmpty else { return nil }
        let baseURL = credentials["baseURL"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let url = URL(string: baseURL), MagpieGateway.isLoopback(url) else { return nil }
        let apiKey = credentials["apiKey"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        self.model = model
        self.baseURL = baseURL
        self.apiKey = apiKey
    }

    func toCredentials() -> [String: String] {
        [
            "model": model,
            "baseURL": baseURL,
            "apiKey": apiKey,
        ]
    }

    func toLLMConfig() -> LLMConfig {
        LLMConfig(apiKey: apiKey, model: model, baseURL: baseURL)
    }
}
