import Foundation

struct MetaMuseASRConfig: ASRProviderConfig, Sendable {

    static let provider = ASRProvider.metaMuse
    static let displayName = "Meta Muse"
    static let defaultModel = "muse-voice-transcribe-1.0"
    static let defaultRealtimeURL = "wss://api.meta.ai/v1/asr/realtime"

    static let supportedLanguages: [(code: String, labelZh: String, labelEn: String)] = [
        ("", "自动检测 (无偏置)", "Auto / No Bias"),
        ("Chinese", "中文 (Chinese)", "Chinese"),
        ("English", "英语 (English)", "English"),
        ("Spanish", "西班牙语 (Spanish)", "Spanish"),
        ("French", "法语 (French)", "French"),
        ("German", "德语 (German)", "German"),
        ("Japanese", "日语 (Japanese)", "Japanese"),
        ("Korean", "韩语 (Korean)", "Korean"),
        ("Portuguese", "葡萄牙语 (Portuguese)", "Portuguese"),
        ("Italian", "意大利语 (Italian)", "Italian"),
        ("Russian", "俄语 (Russian)", "Russian"),
        ("Arabic", "阿拉伯语 (Arabic)", "Arabic"),
        ("Hindi", "印地语 (Hindi)", "Hindi"),
        ("Dutch", "荷兰语 (Dutch)", "Dutch"),
        ("Polish", "波兰语 (Polish)", "Polish"),
        ("Turkish", "土耳其语 (Turkish)", "Turkish"),
        ("Vietnamese", "越南语 (Vietnamese)", "Vietnamese"),
        ("Indonesian", "印度尼西亚语 (Indonesian)", "Indonesian"),
        ("Thai", "泰语 (Thai)", "Thai"),
    ]

    static var credentialFields: [CredentialField] {[
        CredentialField(
            key: "apiKey",
            label: L("API Key (Meta Model API)", "API Key (Meta Model API)"),
            placeholder: L("粘贴 Meta Model API Key", "Paste your Meta Model API Key"),
            isSecure: true,
            isOptional: false,
            defaultValue: ""
        ),
        CredentialField(
            key: "languageBias",
            label: L("语言偏置 (提示)", "Language Bias"),
            placeholder: L("自动 (无偏置)", "Auto / No Bias"),
            isSecure: false,
            isOptional: true,
            defaultValue: "",
            options: supportedLanguages.map {
                FieldOption(value: $0.code, label: L($0.labelZh, $0.labelEn))
            }
        ),
    ]}

    let apiKey: String
    let languageBias: String

    init?(credentials: [String: String]) {
        guard let apiKey = Self.sanitized(credentials["apiKey"]) else {
            return nil
        }
        self.apiKey = apiKey
        self.languageBias = Self.sanitized(credentials["languageBias"]) ?? ""
    }

    func toCredentials() -> [String: String] {
        [
            "apiKey": apiKey,
            "languageBias": languageBias,
        ]
    }

    var isValid: Bool {
        !apiKey.isEmpty
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
