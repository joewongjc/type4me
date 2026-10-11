import Foundation

struct ElevenLabsASRConfig: ASRRecognitionModeConfigurable, Sendable {

    static let provider = ASRProvider.elevenlabs
    static let displayName = "ElevenLabs"
    static let defaultModel = "scribe_v2_realtime"
    static let supportedModels = [
        "scribe_v2_realtime",
    ]
    static let defaultBatchModel = "scribe_v2"
    static let supportedBatchModels = [
        "scribe_v2",
    ]

    static let supportedLanguages = [
        "",         // auto-detect
        "en", "zh", "zh-TW", "ja", "ko",
        "es", "fr", "de", "it", "pt",
        "ru", "ar", "hi", "nl", "pl",
    ]

    static var credentialFields: [CredentialField] {[
        ASRRecognitionMode.credentialField,
        CredentialField(key: "apiKey", label: L("API Key", "API Key"), placeholder: L("粘贴 API Key", "Paste your API Key"), isSecure: true, isOptional: false, defaultValue: ""),
        CredentialField(key: "model", label: L("模型", "Model"), placeholder: defaultModel, isSecure: false, isOptional: false, defaultValue: defaultModel,
            options: supportedModels.map { FieldOption(value: $0, label: $0) }, visibleModes: [.streaming]),
        CredentialField(key: "batchModel", label: L("模型", "Model"), placeholder: defaultBatchModel, isSecure: false, isOptional: false, defaultValue: defaultBatchModel,
            options: supportedBatchModels.map { FieldOption(value: $0, label: $0) }, visibleModes: [.batch]),
        CredentialField(key: "language", label: L("语言", "Language"), placeholder: "auto", isSecure: false, isOptional: true, defaultValue: "",
            options: supportedLanguages.map { FieldOption(value: $0, label: $0.isEmpty ? L("自动检测", "auto-detect") : $0) }),
    ]}

    let recognitionMode: ASRRecognitionMode
    let apiKey: String
    let model: String
    let batchModel: String
    let language: String

    init?(credentials: [String: String]) {
        guard let apiKey = credentials["apiKey"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !apiKey.isEmpty
        else { return nil }
        self.recognitionMode = ASRRecognitionMode(credentials: credentials)
        self.apiKey = apiKey
        let rawModel = credentials["model"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.model = Self.supportedModels.contains(rawModel) ? rawModel : Self.defaultModel
        let rawBatchModel = credentials["batchModel"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.batchModel = Self.supportedBatchModels.contains(rawBatchModel) ? rawBatchModel : Self.defaultBatchModel
        self.language = credentials["language"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    func toCredentials() -> [String: String] {
        [
            ASRRecognitionMode.credentialKey: recognitionMode.rawValue,
            "apiKey": apiKey,
            "model": model,
            "batchModel": batchModel,
            "language": language,
        ]
    }

    var isValid: Bool {
        guard !apiKey.isEmpty else { return false }
        return recognitionMode == .batch
            ? Self.supportedBatchModels.contains(batchModel)
            : Self.supportedModels.contains(model)
    }
}
