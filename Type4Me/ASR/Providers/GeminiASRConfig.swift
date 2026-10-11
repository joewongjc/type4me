import Foundation

enum GeminiTranscriptionMode: String, Sendable, CaseIterable {
    case smart = "SMART"
    case verbatim = "VERBATIM"
}

struct GeminiASRConfig: ASRRecognitionModeConfigurable, Sendable {

    static let provider = ASRProvider.gemini
    static let displayName = "Gemini"

    /// Models exposed under the Gemini provider. Add new entries here as Google
    /// ships more transcription models; the provider itself stays "Gemini".
    static let supportedModels: [(id: String, label: String)] = [
        ("gemini-3.5-transcribe-live", "Gemini 3.5 Transcribe (Live)"),
    ]
    static let defaultModel = "gemini-3.5-transcribe-live"
    static let supportedBatchModels: [(id: String, label: String)] = [
        ("gemini-3.5-transcribe", "Gemini 3.5 Transcribe"),
    ]
    static let defaultBatchModel = "gemini-3.5-transcribe"

    static let webSocketBaseURL = "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"

    static let defaultMode: GeminiTranscriptionMode = .smart
    static let defaultLanguage = "auto"

    static var credentialFields: [CredentialField] {[
        ASRRecognitionMode.credentialField,
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
            label: L("模型", "Model"),
            placeholder: defaultModel,
            isSecure: false,
            isOptional: true,
            defaultValue: defaultModel,
            options: supportedModels.map { FieldOption(value: $0.id, label: $0.label) },
            allowCustomInput: true,
            visibleModes: [.streaming]
        ),
        CredentialField(
            key: "batchModel",
            label: L("模型", "Model"),
            placeholder: defaultBatchModel,
            isSecure: false,
            isOptional: true,
            defaultValue: defaultBatchModel,
            options: supportedBatchModels.map { FieldOption(value: $0.id, label: $0.label) },
            allowCustomInput: true,
            visibleModes: [.batch]
        ),
        CredentialField(
            key: "mode",
            label: L("转写模式", "Transcription Mode"),
            placeholder: "",
            isSecure: false,
            isOptional: true,
            defaultValue: "SMART",
            options: [
                FieldOption(value: "SMART", label: L("智能整理", "Smart")),
                FieldOption(value: "VERBATIM", label: L("逐字转写", "Verbatim")),
            ]
        ),
        CredentialField(
            key: "languageCode",
            label: L("语言提示", "Language Hint"),
            placeholder: L("BCP-47，例如 en-US", "BCP-47, e.g. en-US"),
            isSecure: false,
            isOptional: true,
            defaultValue: "auto",
            options: [
                FieldOption(value: "auto", label: L("自动检测", "Auto Detect")),
                FieldOption(value: "cmn-Hans-CN", label: L("中文（普通话）", "Mandarin Chinese")),
                FieldOption(value: "yue-Hant-HK", label: L("粤语", "Cantonese")),
                FieldOption(value: "en-US", label: "English (US)"),
                FieldOption(value: "ja-JP", label: "日本語"),
                FieldOption(value: "ko-KR", label: "한국어"),
            ],
            allowCustomInput: true
        ),
    ]}

    let recognitionMode: ASRRecognitionMode
    let apiKey: String
    let model: String
    let batchModel: String
    let mode: GeminiTranscriptionMode
    let languageCode: String

    init?(credentials: [String: String]) {
        guard let apiKey = credentials["apiKey"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !apiKey.isEmpty
        else { return nil }

        let rawModel = credentials["model"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let model = rawModel.isEmpty ? Self.defaultModel : rawModel
        let rawBatchModel = credentials["batchModel"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let batchModel = rawBatchModel.isEmpty ? Self.defaultBatchModel : rawBatchModel

        let rawMode = credentials["mode"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let mode = GeminiTranscriptionMode(rawValue: rawMode.uppercased()) ?? Self.defaultMode

        let rawLanguage = credentials["languageCode"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let languageCode = rawLanguage.isEmpty ? Self.defaultLanguage : rawLanguage

        self.recognitionMode = ASRRecognitionMode(credentials: credentials)
        self.apiKey = apiKey
        self.model = model
        self.batchModel = batchModel
        self.mode = mode
        self.languageCode = languageCode
    }

    func toCredentials() -> [String: String] {
        [
            ASRRecognitionMode.credentialKey: recognitionMode.rawValue,
            "apiKey": apiKey,
            "model": model,
            "batchModel": batchModel,
            "mode": mode.rawValue,
            "languageCode": languageCode,
        ]
    }

    var isValid: Bool {
        !apiKey.isEmpty
    }
}
