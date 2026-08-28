import Foundation

struct StepFunASRConfig: ASRProviderConfig, Sendable {

    static let provider = ASRProvider.stepfun
    static let displayName = L("阶跃星辰", "StepFun")
    static let model = "stepaudio-2.5-asr-stream"
    static let endpoint = URL(string: "wss://api.stepfun.com/v1/realtime/asr/stream")!

    static var credentialFields: [CredentialField] {[
        CredentialField(
            key: "apiKey",
            label: "API Key",
            placeholder: "sk-...",
            isSecure: true,
            isOptional: false,
            defaultValue: ""
        ),
    ]}

    let apiKey: String

    init?(credentials: [String: String]) {
        guard let apiKey = credentials["apiKey"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !apiKey.isEmpty
        else {
            return nil
        }
        self.apiKey = apiKey
    }

    func toCredentials() -> [String: String] {
        ["apiKey": apiKey]
    }

    var isValid: Bool { !apiKey.isEmpty }
}
