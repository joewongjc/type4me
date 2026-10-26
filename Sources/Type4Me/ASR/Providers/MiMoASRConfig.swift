import Foundation

enum MiMoASRLanguage: String, Sendable, CaseIterable {
    case auto
    case zh
    case en

    var displayName: String {
        switch self {
        case .auto: return L("自动检测", "Auto Detect")
        case .zh: return L("中文", "Chinese")
        case .en: return L("英文", "English")
        }
    }
}

struct MiMoASRConfig: ASRProviderConfig, Sendable {

    static let provider = ASRProvider.mimo
    static let displayName = L("小米 MiMo", "Xiaomi MiMo")
    static let defaultModel = "mimo-v2.5-asr"
    static let endpoint = "https://api.xiaomimimo.com/v1/chat/completions"

    static var credentialFields: [CredentialField] {[
        CredentialField(
            key: "apiKey",
            label: "API Key",
            placeholder: "...",
            isSecure: true,
            isOptional: false,
            defaultValue: ""
        ),
        CredentialField(
            key: "language",
            label: L("识别语言", "Language"),
            placeholder: "",
            isSecure: false,
            isOptional: true,
            defaultValue: MiMoASRLanguage.auto.rawValue,
            options: MiMoASRLanguage.allCases.map {
                FieldOption(value: $0.rawValue, label: $0.displayName)
            }
        ),
    ]}

    let apiKey: String
    let language: MiMoASRLanguage

    init?(credentials: [String: String]) {
        guard let apiKey = credentials["apiKey"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !apiKey.isEmpty
        else {
            return nil
        }
        self.apiKey = apiKey
        self.language = MiMoASRLanguage(rawValue: credentials["language"] ?? "") ?? .auto
    }

    func toCredentials() -> [String: String] {
        [
            "apiKey": apiKey,
            "language": language.rawValue,
        ]
    }

    var isValid: Bool { !apiKey.isEmpty }
}
