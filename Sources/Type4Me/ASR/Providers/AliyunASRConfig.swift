import Foundation

struct AliyunASRConfig: ASRProviderConfig, Sendable {

    static let provider = ASRProvider.aliyun
    static var displayName: String { L("阿里云", "Alibaba Cloud") }

    static var credentialFields: [CredentialField] {[
        CredentialField(key: "accessKeyId", label: L("Access Key ID", "Access Key ID"), placeholder: L("密钥 ID", "Key ID"), isSecure: false, isOptional: false, defaultValue: ""),
        CredentialField(key: "accessKeySecret", label: L("Access Key Secret", "Access Key Secret"), placeholder: L("密钥", "Secret"), isSecure: true, isOptional: false, defaultValue: ""),
        CredentialField(key: "appKey", label: L("App Key", "App Key"), placeholder: L("项目 AppKey", "Project AppKey"), isSecure: false, isOptional: false, defaultValue: ""),
    ]}

    let accessKeyId: String
    let accessKeySecret: String
    let appKey: String

    init?(credentials: [String: String]) {
        guard let kid = credentials["accessKeyId"], !kid.isEmpty,
              let secret = credentials["accessKeySecret"], !secret.isEmpty,
              let appKey = credentials["appKey"], !appKey.isEmpty
        else { return nil }
        self.accessKeyId = kid
        self.accessKeySecret = secret
        self.appKey = appKey
    }

    func toCredentials() -> [String: String] {
        ["accessKeyId": accessKeyId, "accessKeySecret": accessKeySecret, "appKey": appKey]
    }

    var isValid: Bool { !accessKeyId.isEmpty && !accessKeySecret.isEmpty && !appKey.isEmpty }
}
