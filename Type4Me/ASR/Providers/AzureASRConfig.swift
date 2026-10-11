import Foundation

/// Microsoft MAI-Transcribe models hosted on a Microsoft Foundry resource.
/// Streaming uses MAI-Transcribe-2-Streaming over the Realtime API; batch uses
/// MAI-Transcribe-2 through the Azure Speech fast transcription API.
struct AzureASRConfig: ASRRecognitionModeConfigurable, Sendable {

    static let provider = ASRProvider.azure
    static let displayName = "Microsoft Azure"
    static let streamingModel = "MAI-Transcribe-2-Streaming"
    static let batchModel = "MAI-Transcribe-2"
    static let defaultTranscribeStyle = "clean"

    static let foundryHostSuffix = ".services.ai.azure.com"
    static let speechHostSuffix = ".cognitiveservices.azure.com"
    private static let knownHostSuffixes = [foundryHostSuffix, speechHostSuffix, ".openai.azure.com"]

    static let supportedLanguages = [
        "",         // auto-detect
        "zh", "yue", "en", "ja", "ko", "fr", "de", "es", "it", "pt", "ru",
        "ar", "hi", "id", "ms", "th", "vi", "fil", "tr", "nl", "pl", "sv", "uk",
    ]

    static var credentialFields: [CredentialField] {[
        ASRRecognitionMode.credentialField,
        CredentialField(
            key: "resource",
            label: L("资源名称", "Resource"),
            placeholder: L("my-resource 或 https://my-resource.services.ai.azure.com", "my-resource or https://my-resource.services.ai.azure.com"),
            isSecure: false,
            isOptional: false,
            defaultValue: ""
        ),
        CredentialField(
            key: "apiKey",
            label: "API Key",
            placeholder: L("资源密钥（KEY 1 或 KEY 2）", "Resource key (KEY 1 or KEY 2)"),
            isSecure: true,
            isOptional: false,
            defaultValue: ""
        ),
        CredentialField(
            key: "deployment",
            label: L("部署名称", "Deployment"),
            placeholder: streamingModel,
            isSecure: false,
            isOptional: false,
            defaultValue: streamingModel,
            visibleModes: [.streaming]
        ),
        CredentialField(
            key: "transcribeStyle",
            label: L("转写风格", "Style"),
            placeholder: "",
            isSecure: false,
            isOptional: false,
            defaultValue: defaultTranscribeStyle,
            options: [
                FieldOption(value: "clean", label: L("Clean（去除口头语）", "Clean (no fillers)")),
                FieldOption(value: "verbatim", label: L("Verbatim（逐字）", "Verbatim")),
            ],
            visibleModes: [.batch]
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
    let resource: String
    let apiKey: String
    let deployment: String
    let transcribeStyle: String
    let language: String

    init?(credentials: [String: String]) {
        func value(_ key: String) -> String {
            credentials[key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        let resource = value("resource")
        let apiKey = value("apiKey")
        guard !apiKey.isEmpty, Self.host(forResource: resource, suffix: Self.foundryHostSuffix) != nil else {
            return nil
        }
        self.recognitionMode = ASRRecognitionMode(credentials: credentials)
        self.resource = resource
        self.apiKey = apiKey
        let deployment = value("deployment")
        self.deployment = deployment.isEmpty ? Self.streamingModel : deployment
        let style = value("transcribeStyle")
        self.transcribeStyle = style == "verbatim" ? "verbatim" : Self.defaultTranscribeStyle
        self.language = value("language")
    }

    func toCredentials() -> [String: String] {
        [
            ASRRecognitionMode.credentialKey: recognitionMode.rawValue,
            "resource": resource,
            "apiKey": apiKey,
            "deployment": deployment,
            "transcribeStyle": transcribeStyle,
            "language": language,
        ]
    }

    var isValid: Bool { !apiKey.isEmpty && foundryHost != nil }

    /// `{resource}.services.ai.azure.com`, which serves the Realtime API.
    var foundryHost: String? { Self.host(forResource: resource, suffix: Self.foundryHostSuffix) }

    /// `{resource}.cognitiveservices.azure.com`, which serves the Speech REST API.
    var speechHost: String? { Self.host(forResource: resource, suffix: Self.speechHostSuffix) }

    /// Accepts a bare resource name, a resource hostname, or a full endpoint URL.
    /// Standard Azure hostnames are mapped to the requested service host; any other
    /// hostname (a custom domain) is used as-is for both services.
    static func host(forResource raw: String, suffix: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let host: String
        if trimmed.contains("://") {
            guard let parsed = URL(string: trimmed)?.host else { return nil }
            host = parsed
        } else {
            host = String(trimmed.split(separator: "/", maxSplits: 1).first ?? "")
        }
        let lowered = host.lowercased()

        let name: String
        if !lowered.contains(".") {
            name = lowered
        } else if let known = knownHostSuffixes.first(where: { lowered.hasSuffix($0) }) {
            name = String(lowered.dropLast(known.count))
        } else {
            return isValidHost(lowered) ? lowered : nil
        }

        guard !name.isEmpty, !name.contains("."), isValidHost(name) else { return nil }
        return name + suffix
    }

    private static func isValidHost(_ host: String) -> Bool {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-.")
        return host.unicodeScalars.allSatisfy { allowed.contains($0) }
            && !host.hasPrefix("-") && !host.hasPrefix(".")
    }
}
