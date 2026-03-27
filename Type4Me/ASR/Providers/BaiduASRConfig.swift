import Foundation

struct BaiduASRConfig: ASRProviderConfig, Sendable {

    static let provider = ASRProvider.baidu
    static let displayName = L("百度智能云", "Baidu AI Cloud")
    static let defaultDevPID = "15372"

    static var credentialFields: [CredentialField] {[
        CredentialField(
            key: "appID",
            label: "App ID",
            placeholder: "123456789",
            isSecure: false,
            isOptional: false,
            defaultValue: ""
        ),
        CredentialField(
            key: "apiKey",
            label: "API Key",
            placeholder: L("百度语音 API Key", "Baidu Speech API key"),
            isSecure: true,
            isOptional: false,
            defaultValue: ""
        ),
        CredentialField(
            key: "devPID",
            label: "Dev PID",
            placeholder: defaultDevPID,
            isSecure: false,
            isOptional: true,
            defaultValue: defaultDevPID
        ),
        CredentialField(
            key: "cuid",
            label: "CUID",
            placeholder: L("客户端唯一标识", "Stable client identifier"),
            isSecure: false,
            isOptional: true,
            defaultValue: ASRIdentityStore.loadOrCreateUID()
        ),
        CredentialField(
            key: "lmId",
            label: "LM ID",
            placeholder: L("自训练语言模型 ID（可选）", "Custom language model ID (optional)"),
            isSecure: false,
            isOptional: true,
            defaultValue: ""
        ),
    ]}

    let appID: Int
    let apiKey: String
    let devPID: Int
    let cuid: String
    let lmID: String

    init?(credentials: [String: String]) {
        guard let appIDText = Self.sanitized(credentials["appID"]),
              let appID = Int(appIDText),
              appID > 0,
              let apiKey = Self.sanitized(credentials["apiKey"]),
              !apiKey.isEmpty
        else {
            return nil
        }

        let devPIDText = Self.sanitized(credentials["devPID"]) ?? Self.defaultDevPID
        guard let devPID = Int(devPIDText), devPID > 0 else {
            return nil
        }

        self.appID = appID
        self.apiKey = apiKey
        self.devPID = devPID
        self.cuid = Self.sanitized(credentials["cuid"]) ?? ASRIdentityStore.loadOrCreateUID()
        self.lmID = Self.sanitized(credentials["lmId"]) ?? ""
    }

    func toCredentials() -> [String: String] {
        [
            "appID": String(appID),
            "apiKey": apiKey,
            "devPID": String(devPID),
            "cuid": cuid,
            "lmId": lmID,
        ]
    }

    var isValid: Bool {
        appID > 0 && !apiKey.isEmpty && devPID > 0 && !cuid.isEmpty
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
