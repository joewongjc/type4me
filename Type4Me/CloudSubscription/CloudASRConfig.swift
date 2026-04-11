import Foundation

struct CloudASRConfig: ASRProviderConfig, Sendable {

    static var provider: ASRProvider { .cloud }
    static var displayName: String { "Type4Me Cloud" }

    // No credential fields — auth is handled by CloudAuthManager
    static var credentialFields: [CredentialField] { [] }

    let proxyEndpoint: String

    init?(credentials: [String: String]) {
        proxyEndpoint = CloudConfig.apiEndpoint + "/asr"
    }

    func toCredentials() -> [String: String] { [:] }
    var isValid: Bool { true }
}
