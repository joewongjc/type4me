import Foundation

struct SonioxASRConfig: ASRProviderConfig, Sendable {

    static let provider = ASRProvider.soniox
    static let displayName = "Soniox"
    static let defaultModel = "stt-rt-v4"
    static let supportedModels = [
        "stt-rt-v4",
        "stt-rt-v3",
    ]

    static var credentialFields: [CredentialField] {[
        CredentialField(
            key: "apiKey",
            label: "API Key",
            placeholder: "",
            isSecure: true,
            isOptional: false,
            defaultValue: ""
        ),
        CredentialField(
            key: "model",
            label: L("Streaming Model", "Streaming Model"),
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
        guard let apiKey = Self.sanitized(credentials["apiKey"]) else {
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
