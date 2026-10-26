import Foundation

struct CodexCLILLMConfig: LLMProviderConfig, Sendable {

    static let provider = LLMProvider.codexCLI

    static var credentialFields: [CredentialField] {
        let models = provider.modelOptions
        let defaultModel = models.first?.value ?? "gpt-6-luna"
        return [
            CredentialField(
                key: "model",
                label: L("模型（固定使用低推理）", "Model (Low Reasoning)"),
                placeholder: defaultModel,
                isSecure: false,
                isOptional: false,
                defaultValue: defaultModel,
                options: models,
                allowCustomInput: true
            ),
        ]
    }

    let model: String

    init?(credentials: [String: String]) {
        let rawModel = credentials["model"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !rawModel.isEmpty else { return nil }
        self.model = Self.normalizeModel(rawModel)
    }

    static func normalizeModel(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        switch trimmed.lowercased() {
        case "6-luna", "6luna":
            return "gpt-6-luna"
        case "5.6-luna", "5.6luna":
            return "gpt-5.6-luna"
        case "5.3-codex-spark", "5.3-spark", "spark":
            return "gpt-5.3-codex-spark"
        default:
            return trimmed
        }
    }

    func toCredentials() -> [String: String] {
        ["model": model]
    }

    func toLLMConfig() -> LLMConfig {
        LLMConfig(apiKey: "", model: model, baseURL: "codex-cli")
    }
}
