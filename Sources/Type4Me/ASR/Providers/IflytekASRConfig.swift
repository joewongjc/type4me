import Foundation

struct IflytekASRConfig: ASRProviderConfig, Sendable {

    static let provider = ASRProvider.iflytek
    static var displayName: String { L("讯飞", "iFLYTEK") }

    static var credentialFields: [CredentialField] {[
        CredentialField(key: "appId", label: L("App ID", "App ID"), placeholder: L("应用 ID", "App ID"), isSecure: false, isOptional: false, defaultValue: ""),
        CredentialField(key: "apiKey", label: L("API Key", "API Key"), placeholder: L("密钥", "Secret"), isSecure: true, isOptional: false, defaultValue: ""),
        CredentialField(key: "apiSecret", label: L("API Secret", "API Secret"), placeholder: L("密钥", "Secret"), isSecure: true, isOptional: false, defaultValue: ""),
    ]}

    let appId: String
    let apiKey: String
    let apiSecret: String

    init?(credentials: [String: String]) {
        guard let aid = credentials["appId"], !aid.isEmpty,
              let key = credentials["apiKey"], !key.isEmpty,
              let secret = credentials["apiSecret"], !secret.isEmpty
        else { return nil }
        self.appId = aid
        self.apiKey = key
        self.apiSecret = secret
    }

    func toCredentials() -> [String: String] {
        ["appId": appId, "apiKey": apiKey, "apiSecret": apiSecret]
    }

    var isValid: Bool { !appId.isEmpty && !apiKey.isEmpty && !apiSecret.isEmpty }
}
