import Foundation

struct CartesiaASRConfig: ASRProviderConfig, Sendable {
    static let provider = ASRProvider.cartesia
    static let displayName = "Cartesia"
    static let model = "ink-2"
    static let language = "en"

    static var credentialFields: [CredentialField] { [
        CredentialField(key: "apiKey", label: "API Key", placeholder: "sk_car_...", isSecure: true, isOptional: false, defaultValue: ""),
    ] }

    let apiKey: String

    init?(credentials: [String: String]) {
        guard let apiKey = credentials["apiKey"]?.trimmingCharacters(in: .whitespacesAndNewlines), !apiKey.isEmpty else {
            return nil
        }
        self.apiKey = apiKey
    }

    func toCredentials() -> [String: String] { ["apiKey": apiKey] }
    var isValid: Bool { !apiKey.isEmpty }
}
