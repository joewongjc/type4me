import Foundation

struct SonioxASRConfig: ASRProviderConfig, Sendable {

    static let provider = ASRProvider.soniox
    static let displayName = "Soniox"
    static let defaultModel = "stt-rt-v5"
    static let asyncModel = "stt-async-v5"
    static let defaultEndpointSensitivity = -0.3
    static let supportedModels = [
        "stt-rt-v5",
    ]

    static var credentialFields: [CredentialField] {[
        CredentialField(
            key: "apiKey",
            label: L("API Key (默认 \(defaultModel))", "API Key (uses \(defaultModel))"),
            placeholder: L("粘贴 API Key", "Paste your API Key"),
            isSecure: true,
            isOptional: false,
            defaultValue: ""
        ),
        CredentialField(
            key: "endpointSensitivity",
            label: L("断句灵敏度", "Endpoint sensitivity"),
            placeholder: "-0.3",
            isSecure: false,
            isOptional: false,
            defaultValue: "-0.3",
            options: [
                FieldOption(value: "-0.5", label: L("非常耐心（-0.5）", "Very patient (-0.5)")),
                FieldOption(value: "-0.3", label: L("听写推荐（-0.3）", "Recommended for dictation (-0.3)")),
                FieldOption(value: "0.0", label: L("标准（0.0）", "Standard (0.0)")),
                FieldOption(value: "0.3", label: L("灵敏（0.3）", "Responsive (0.3)")),
                FieldOption(value: "0.5", label: L("非常灵敏（0.5）", "Very responsive (0.5)")),
            ]
        ),
    ]}

    let apiKey: String
    let model: String
    let endpointSensitivity: Double

    init?(credentials: [String: String]) {
        guard let apiKey = Self.sanitized(credentials["apiKey"]) else {
            return nil
        }

        let rawModel = Self.sanitized(credentials["model"])?.lowercased() ?? ""
        self.apiKey = apiKey
        self.model = Self.supportedModels.contains(rawModel) ? rawModel : Self.defaultModel

        let sensitivity = Self.sanitized(credentials["endpointSensitivity"])
            .flatMap(Double.init) ?? Self.defaultEndpointSensitivity
        self.endpointSensitivity = (-1.0...1.0).contains(sensitivity)
            ? sensitivity
            : Self.defaultEndpointSensitivity
    }

    func toCredentials() -> [String: String] {
        [
            "apiKey": apiKey,
            "model": model,
            "endpointSensitivity": String(endpointSensitivity),
        ]
    }

    var isValid: Bool {
        !apiKey.isEmpty
            && Self.supportedModels.contains(model)
            && (-1.0...1.0).contains(endpointSensitivity)
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
