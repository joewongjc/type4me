import Foundation

struct GrokASRConfig: ASRRecognitionModeConfigurable, Sendable {

    static let provider = ASRProvider.grok
    static let displayName = "Grok"
    static let model = "grok-voice-transcribe-2.0"

    static let supportedLanguages = [
        "",         // auto-detect
        "en", "es", "fr", "de", "it", "pt", "ja", "ko", "zh",
        "ar", "cs", "da", "nl", "hi", "id", "fil", "pl", "ru",
        "sv", "th", "tr", "vi", "fa", "mk", "ms", "ro",
    ]

    static var credentialFields: [CredentialField] {[
        ASRRecognitionMode.credentialField,
        CredentialField(
            key: "apiKey",
            label: "API Key",
            placeholder: "xai-...",
            isSecure: true,
            isOptional: false,
            defaultValue: ""
        ),
        CredentialField(
            key: "language",
            label: L("语言", "Language"),
            placeholder: "auto",
            isSecure: false,
            isOptional: true,
            defaultValue: "",
            options: supportedLanguages.map {
                FieldOption(value: $0, label: $0.isEmpty ? L("自动检测", "auto-detect") : $0)
            }
        ),
    ]}

    let recognitionMode: ASRRecognitionMode
    let apiKey: String
    let language: String

    init?(credentials: [String: String]) {
        guard let apiKey = credentials["apiKey"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !apiKey.isEmpty
        else { return nil }
        self.recognitionMode = ASRRecognitionMode(credentials: credentials)
        self.apiKey = apiKey
        self.language = credentials["language"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    func toCredentials() -> [String: String] {
        [
            ASRRecognitionMode.credentialKey: recognitionMode.rawValue,
            "apiKey": apiKey,
            "language": language,
        ]
    }

    var isValid: Bool { !apiKey.isEmpty }
}
