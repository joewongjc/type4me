import Foundation

struct BaiduASRConfig: ASRProviderConfig, Sendable {

    static let provider = ASRProvider.baidu
    static let displayName = L("百度智能云 (弃用)", "Baidu AI Cloud (Deprecated)")
    static let defaultDevPID = "15372"
    static let devPIDOptions = [
        FieldOption(value: "15372", label: L("15372 中文增强标点", "15372 Chinese enhanced punctuation")),
        FieldOption(value: "1537", label: L("1537 中文弱标点", "1537 Chinese weak punctuation")),
        FieldOption(value: "15376", label: L("15376 中文多方言弱标点", "15376 Chinese multi-dialect weak punctuation")),
        FieldOption(value: "17372", label: L("17372 英文增强标点", "17372 English enhanced punctuation")),
        FieldOption(value: "1737", label: L("1737 英文无标点", "1737 English no punctuation")),
    ]

    static var credentialFields: [CredentialField] {[
        CredentialField(
            key: "appID",
            label: L("App ID", "App ID"),
            placeholder: "123456789",
            isSecure: false,
            isOptional: false,
            defaultValue: ""
        ),
        CredentialField(
            key: "apiKey",
            label: L("API Key", "API Key"),
            placeholder: L("百度语音 API Key", "Baidu Speech API key"),
            isSecure: true,
            isOptional: false,
            defaultValue: ""
        ),
        CredentialField(
            key: "devPID",
            label: L("Dev PID", "Dev PID"),
            placeholder: defaultDevPID,
            isSecure: false,
            isOptional: true,
            defaultValue: defaultDevPID,
            options: devPIDOptions
        ),
        CredentialField(
            key: "cuid",
            label: L("CUID", "CUID"),
            placeholder: L("客户端唯一标识", "Stable client identifier"),
            isSecure: false,
            isOptional: true,
            defaultValue: ASRIdentityStore.loadOrCreateUID()
        ),
        CredentialField(
            key: "lmId",
            label: L("LM ID", "LM ID"),
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
