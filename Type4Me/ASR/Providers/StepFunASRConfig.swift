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

enum StepFunBatchAccessMode: String, Sendable, CaseIterable {
    case standard
    case stepPlan

    static let `default` = StepFunBatchAccessMode.standard
    static let standardEndpoint = "https://api.stepfun.com/v1/audio/asr/sse"
    static let stepPlanEndpoint = "https://api.stepfun.com/step_plan/v1/audio/asr/sse"

    var displayName: String {
        switch self {
        case .standard:
            return L("标准按量付费", "Standard pay-as-you-go")
        case .stepPlan:
            return "Step Plan"
        }
    }

    var endpoint: String {
        switch self {
        case .standard: return Self.standardEndpoint
        case .stepPlan: return Self.stepPlanEndpoint
        }
    }
}

struct StepFunASRConfig: ASRRecognitionModeConfigurable, Sendable {

    static let provider = ASRProvider.stepfun
    static let displayName = L("阶跃星辰", "StepFun")
    static let model = "stepaudio-2.5-asr-stream"
    static let batchModel = "stepaudio-2.5-asr"
    static let defaultRegion = StepFunASRRegion.default

    static var credentialFields: [CredentialField] {[
        ASRRecognitionMode.credentialField,
        CredentialField(
            key: "accessMode",
            label: L("接入方式", "Access Mode"),
            placeholder: "",
            isSecure: false,
            isOptional: false,
            defaultValue: StepFunBatchAccessMode.default.rawValue,
            options: StepFunBatchAccessMode.allCases.map {
                FieldOption(value: $0.rawValue, label: $0.displayName)
            },
            visibleModes: [.batch]
        ),
        CredentialField(
            key: "apiKey",
            label: "API Key",
            placeholder: "sk-...",
            isSecure: true,
            isOptional: false,
            defaultValue: ""
        ),
        CredentialField(
            key: "stepPlanApiKey",
            label: "Step Plan API Key",
            placeholder: "sk-...",
            isSecure: true,
            isOptional: false,
            defaultValue: "",
            visibleModes: [.batch]
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
            },
            visibleModes: [.streaming]
        ),
    ]}

    /// Step Plan uses its own key; the standard key covers realtime and standard batch.
    static func displayedCredentialFields(for values: [String: String]) -> [CredentialField] {
        let mode = ASRRecognitionMode(credentials: values)
        let accessMode = StepFunBatchAccessMode(rawValue: values["accessMode"] ?? "") ?? .default
        return credentialFields.filter { field in
            guard field.isVisible(in: mode) else { return false }
            switch field.key {
            case "apiKey":
                return mode == .streaming || accessMode == .standard
            case "stepPlanApiKey":
                return accessMode == .stepPlan
            default:
                return true
            }
        }
    }

    let recognitionMode: ASRRecognitionMode
    let apiKey: String
    let stepPlanApiKey: String
    let region: StepFunASRRegion
    let accessMode: StepFunBatchAccessMode

    var endpoint: URL { region.webSocketEndpoint }

    /// Key sent with batch requests for the selected access mode.
    var batchAPIKey: String {
        accessMode == .stepPlan ? stepPlanApiKey : apiKey
    }

    init?(credentials: [String: String]) {
        let recognitionMode = ASRRecognitionMode(credentials: credentials)
        let accessMode = StepFunBatchAccessMode(rawValue: credentials["accessMode"] ?? "") ?? .default
        let apiKey = credentials["apiKey"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let stepPlanApiKey = credentials["stepPlanApiKey"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let requiredKey = recognitionMode == .batch && accessMode == .stepPlan ? stepPlanApiKey : apiKey
        guard !requiredKey.isEmpty else { return nil }

        self.recognitionMode = recognitionMode
        self.apiKey = apiKey
        self.stepPlanApiKey = stepPlanApiKey
        self.region = StepFunASRRegion(rawValue: credentials["region"] ?? "") ?? Self.defaultRegion
        self.accessMode = accessMode
    }

    func toCredentials() -> [String: String] {
        var values = [
            ASRRecognitionMode.credentialKey: recognitionMode.rawValue,
            "region": region.rawValue,
            "accessMode": accessMode.rawValue,
        ]
        if !apiKey.isEmpty { values["apiKey"] = apiKey }
        if !stepPlanApiKey.isEmpty { values["stepPlanApiKey"] = stepPlanApiKey }
        return values
    }

    var isValid: Bool {
        recognitionMode == .batch ? !batchAPIKey.isEmpty : !apiKey.isEmpty
    }
}
