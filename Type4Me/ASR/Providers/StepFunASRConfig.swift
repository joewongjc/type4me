import Foundation

enum StepFunASRRegion: String, Sendable, CaseIterable {
    case china
    case global

    static let `default` = StepFunASRRegion.china

    var displayName: String {
        switch self {
        case .china:
            return L("中国站", "China")
        case .global:
            return L("全球站", "Global")
        }
    }

    var webSocketEndpoint: URL {
        switch self {
        case .china:
            return URL(string: "wss://api.stepfun.com/v1/realtime/asr/stream")!
        case .global:
            return URL(string: "wss://api.stepfun.ai/v1/realtime/asr/stream")!
        }
    }

    var healthEndpoint: String {
        switch self {
        case .china:
            return "https://api.stepfun.com"
        case .global:
            return "https://api.stepfun.ai"
        }
    }

    var platformBaseURL: String {
        switch self {
        case .china:
            return "https://platform.stepfun.com"
        case .global:
            return "https://platform.stepfun.ai"
        }
    }
}

struct StepFunASRConfig: ASRProviderConfig, Sendable {

    static let provider = ASRProvider.stepfun
    static let displayName = L("阶跃星辰", "StepFun")
    static let model = "stepaudio-2.5-asr-stream"
    static let defaultRegion = StepFunASRRegion.default

    static var credentialFields: [CredentialField] {[
        CredentialField(
            key: "apiKey",
            label: "API Key",
            placeholder: "sk-...",
            isSecure: true,
            isOptional: false,
            defaultValue: ""
        ),
        CredentialField(
            key: "region",
            label: L("API 站点", "API Site"),
            placeholder: "",
            isSecure: false,
            isOptional: false,
            defaultValue: defaultRegion.rawValue,
            options: StepFunASRRegion.allCases.map {
                FieldOption(value: $0.rawValue, label: $0.displayName)
            }
        ),
    ]}

    let apiKey: String
    let region: StepFunASRRegion

    var endpoint: URL { region.webSocketEndpoint }

    init?(credentials: [String: String]) {
        guard let apiKey = credentials["apiKey"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !apiKey.isEmpty
        else {
            return nil
        }
        self.apiKey = apiKey
        self.region = StepFunASRRegion(rawValue: credentials["region"] ?? "") ?? Self.defaultRegion
    }

    func toCredentials() -> [String: String] {
        [
            "apiKey": apiKey,
            "region": region.rawValue,
        ]
    }

    var isValid: Bool { !apiKey.isEmpty }
}
