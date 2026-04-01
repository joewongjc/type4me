import Foundation

struct CloudASRConfig: ASRProviderConfig, Sendable {

    static let provider = ASRProvider.cloud
    static let displayName = "Type4Me Cloud"
    static var credentialFields: [CredentialField] { [] }

    let proxyEndpoint: String

    init?(credentials: [String: String]) {
        // Convert https:// to wss:// and append /asr path
        let base = CloudConfig.proxyURL
            .replacingOccurrences(of: "https://", with: "wss://")
            .replacingOccurrences(of: "http://", with: "ws://")
        proxyEndpoint = base + "/asr"
    }

    func toCredentials() -> [String: String] { [:] }
    var isValid: Bool { true }
}
