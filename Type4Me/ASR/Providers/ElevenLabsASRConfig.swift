import Foundation

struct ElevenLabsASRConfig: ASRProviderConfig, Sendable {

    static let provider = ASRProvider.elevenlabs
    static let displayName = "ElevenLabs"

    static let supportedLanguages = [
        "",         // auto-detect
        "en", "zh", "zh-TW", "ja", "ko",
        "es", "fr", "de", "it", "pt",
        "ru", "ar", "hi", "nl", "pl",
    ]

    static var credentialFields: [CredentialField] {[
        CredentialField(key: "apiKey", label: "API Key", placeholder: L("粘贴 API Key", "Paste your API Key"), isSecure: true, isOptional: false, defaultValue: ""),
        CredentialField(key: "language", label: L("语言", "Language"), placeholder: "auto", isSecure: false, isOptional: true, defaultValue: "",
            options: supportedLanguages.map { FieldOption(value: $0, label: $0.isEmpty ? L("自动检测", "auto-detect") : $0) }),
    ]}

    let apiKey: String
    let language: String

    init?(credentials: [String: String]) {
        guard let apiKey = credentials["apiKey"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !apiKey.isEmpty
        else { return nil }
        self.apiKey = apiKey
        self.language = credentials["language"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    func toCredentials() -> [String: String] {
        ["apiKey": apiKey, "language": language]
    }

    var isValid: Bool { !apiKey.isEmpty }
}
