import Foundation

struct AppleASRConfig: ASRProviderConfig, Sendable {

    static let provider = ASRProvider.apple
    static var displayName: String { "Apple Speech" }
    static let defaultLocaleIdentifier = "zh-CN"
    static let supportedLocales: [FieldOption] = [
        FieldOption(value: "zh-CN", label: "简体中文"),
        FieldOption(value: "en-US", label: "English (US)"),
        FieldOption(value: "ja-JP", label: "日本語"),
        FieldOption(value: "ko-KR", label: "한국어"),
    ]
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
