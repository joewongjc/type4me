import Foundation

struct AWSASRConfig: ASRProviderConfig, Sendable {

    static let provider = ASRProvider.aws
    static let displayName = "AWS Transcribe"

    static var credentialFields: [CredentialField] {[
        CredentialField(key: "accessKeyId", label: L("Access Key ID", "Access Key ID"), placeholder: "AKIA...", isSecure: false, isOptional: false, defaultValue: ""),
        CredentialField(key: "secretAccessKey", label: L("Secret Access Key", "Secret Access Key"), placeholder: L("密钥", "Secret"), isSecure: true, isOptional: false, defaultValue: ""),
        CredentialField(key: "region", label: L("区域", "Region"), placeholder: "us-east-1", isSecure: false, isOptional: false, defaultValue: ""),
        CredentialField(key: "sessionToken", label: L("Session Token", "Session Token"), placeholder: L("可选", "Optional"), isSecure: true, isOptional: true, defaultValue: ""),
    ]}

    let accessKeyId: String
    let secretAccessKey: String
    let region: String
    let sessionToken: String?

    init?(credentials: [String: String]) {
        guard let kid = credentials["accessKeyId"], !kid.isEmpty,
              let secret = credentials["secretAccessKey"], !secret.isEmpty,
              let region = credentials["region"], !region.isEmpty
        else { return nil }
        self.accessKeyId = kid
        self.secretAccessKey = secret
        self.region = region
        self.sessionToken = credentials["sessionToken"]
    }

    func toCredentials() -> [String: String] {
        var result = ["accessKeyId": accessKeyId, "secretAccessKey": secretAccessKey, "region": region]
        if let v = sessionToken, !v.isEmpty { result["sessionToken"] = v }
        return result
    }

    var isValid: Bool { !accessKeyId.isEmpty && !secretAccessKey.isEmpty && !region.isEmpty }
}
