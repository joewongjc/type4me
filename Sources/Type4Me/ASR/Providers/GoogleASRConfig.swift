import Foundation

struct GoogleASRConfig: ASRProviderConfig, Sendable {

    static let provider = ASRProvider.google
    static let displayName = "Google Cloud STT"

    static var credentialFields: [CredentialField] {[
        CredentialField(key: "serviceAccountJSON", label: L("Service Account JSON", "Service Account JSON"), placeholder: L("粘贴 JSON 内容或文件路径", "Paste JSON content or file path"), isSecure: true, isOptional: false, defaultValue: ""),
    ]}

    let serviceAccountJSON: String

    init?(credentials: [String: String]) {
        guard let json = credentials["serviceAccountJSON"], !json.isEmpty else { return nil }
        self.serviceAccountJSON = json
    }

    func toCredentials() -> [String: String] {
        ["serviceAccountJSON": serviceAccountJSON]
    }

    var isValid: Bool { !serviceAccountJSON.isEmpty }
}
