import Foundation

struct TencentASRConfig: ASRRecognitionModeConfigurable, Sendable {

    static let provider = ASRProvider.tencent
    static var displayName: String { L("腾讯云", "Tencent Cloud") }

    /// Chinese-English large model 2.0; the only engine offered in the first release.
    static let engineModelType = "16k_zh_en_2.0"

    static var credentialFields: [CredentialField] {[
        ASRRecognitionMode.credentialField,
        CredentialField(
            key: "secretId",
            label: "SecretId",
            placeholder: "AKID...",
            isSecure: false,
            isOptional: false,
            defaultValue: "",
            hint: L("在“访问管理 → API 密钥管理”中创建，建议使用仅授权语音识别的子账号密钥",
                    "Create one under CAM → API Keys. A sub-account key limited to ASR is recommended.")
        ),
        CredentialField(
            key: "secretKey",
            label: "SecretKey",
            placeholder: L("密钥", "Secret"),
            isSecure: true,
            isOptional: false,
            defaultValue: ""
        ),
        CredentialField(
            key: "appId",
            label: "AppID",
            placeholder: "1250000000",
            isSecure: false,
            isOptional: false,
            defaultValue: "",
            hint: L("在“账号信息”页面查看，通常为 125 或 130 开头的 10 位数字（注意不要填成账号 ID / UIN）",
                    "Shown on the Account Info page; usually 10 digits starting with 125 or 130 (do not use Account ID / UIN).")
        ),
    ]}

    let recognitionMode: ASRRecognitionMode
    let secretId: String
    let secretKey: String
    let appId: String

    init?(credentials: [String: String]) {
        let mode = ASRRecognitionMode(credentials: credentials)
        let sid = credentials["secretId"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let key = credentials["secretKey"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let app = credentials["appId"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard !sid.isEmpty, !key.isEmpty, !app.isEmpty else { return nil }
        guard CharacterSet.decimalDigits.isSuperset(of: CharacterSet(charactersIn: app)) else {
            return nil
        }

        self.recognitionMode = mode
        self.secretId = sid
        self.secretKey = key
        self.appId = app
    }

    func toCredentials() -> [String: String] {
        [
            ASRRecognitionMode.credentialKey: recognitionMode.rawValue,
            "secretId": secretId,
            "secretKey": secretKey,
            "appId": appId,
        ]
    }

    var isValid: Bool {
        !secretId.isEmpty && !secretKey.isEmpty && !appId.isEmpty
    }
}
