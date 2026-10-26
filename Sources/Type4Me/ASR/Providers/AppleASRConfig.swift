import Foundation

struct AppleASRConfig: ASRProviderConfig, Sendable {

    static let provider = ASRProvider.apple
    static var displayName: String { L("Apple 语音识别", "Apple Speech") }
    static let defaultLocaleIdentifier = "zh-CN"
    static var supportedLocales: [FieldOption] { [
        FieldOption(value: "zh-CN", label: L("简体中文", "Simplified Chinese")),
        FieldOption(value: "en-US", label: L("英语（美国）", "English (US)")),
        FieldOption(value: "ja-JP", label: L("日语", "Japanese")),
        FieldOption(value: "ko-KR", label: L("韩语", "Korean")),
    ]
    }
    static var credentialFields: [CredentialField] {
        [
            CredentialField(
                key: "localeIdentifier",
                label: L("识别语言", "Recognition Language"),
                placeholder: defaultLocaleIdentifier,
                isSecure: false,
                isOptional: true,
                defaultValue: defaultLocaleIdentifier,
                options: supportedLocales
            )
        ]
    }

    let localeIdentifier: String

    init?(credentials: [String: String]) {
        self.localeIdentifier = credentials["localeIdentifier"]?.isEmpty == false
            ? credentials["localeIdentifier"]!
            : Self.defaultLocaleIdentifier
    }

    func toCredentials() -> [String: String] {
        ["localeIdentifier": localeIdentifier]
    }

    var isValid: Bool { true }
}
