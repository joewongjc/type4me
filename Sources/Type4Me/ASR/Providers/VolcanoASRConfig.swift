import Foundation

struct VolcanoASRConfig: ASRProviderConfig, Sendable {

    enum Authentication: Equatable, Sendable {
        case apiKey(String)
        case legacy(appKey: String, accessKey: String)
    }

    static let provider = ASRProvider.volcano
    static var displayName: String { L("火山引擎 (Doubao)", "Volcano (Doubao)") }

    /// 豆包流式语音识别模型 2.0
    static let resourceIdSeedASR = "volc.seedasr.sauc.duration"
    /// 豆包流式语音识别模型 1.0
    static let resourceIdBigASR = "volc.bigasr.sauc.duration"
    /// Auto: prefer 2.0, fall back to 1.0
    static let resourceIdAuto = "auto"

    static let authModeAPIKey = "apiKey"
    static let authModeLegacy = "legacy"

    static var credentialFields: [CredentialField] {[
        CredentialField(
            key: "authMode",
            label: L("鉴权方式", "Authentication"),
            placeholder: "",
            isSecure: false,
            isOptional: false,
            defaultValue: authModeAPIKey,
            options: [
                FieldOption(value: authModeAPIKey, label: L("API Key（新版控制台）", "API Key (new console)")),
                FieldOption(value: authModeLegacy, label: L("App ID + Access Token（旧版控制台）", "App ID + Access Token (legacy console)")),
            ]
        ),
        CredentialField(
            key: "apiKey",
            label: "API Key",
            placeholder: L("粘贴新版控制台 API Key", "Paste the API Key from the new console"),
            isSecure: true,
            isOptional: true,
            defaultValue: ""
        ),
        CredentialField(
            key: "appKey",
            label: "App ID",
            placeholder: L("旧版控制台 App ID", "App ID from the legacy console"),
            isSecure: false,
            isOptional: true,
            defaultValue: ""
        ),
        CredentialField(
            key: "accessKey",
            label: "Access Token",
            placeholder: L("旧版控制台 Access Token", "Access Token from the legacy console"),
            isSecure: true,
            isOptional: true,
            defaultValue: ""
        ),
        CredentialField(
            key: "resourceId",
            label: L("识别模型", "Model"),
            placeholder: "",
            isSecure: false,
            isOptional: false,
            defaultValue: resourceIdAuto,
            options: [
                FieldOption(value: resourceIdAuto, label: L("自动（优先 2.0，额度用完切 1.0）", "Auto (prefer 2.0, fallback to 1.0)")),
                FieldOption(value: resourceIdSeedASR, label: L("流式语音识别模型 2.0", "Streaming ASR Model 2.0")),
                FieldOption(value: resourceIdBigASR, label: L("流式语音识别大模型", "Streaming ASR Large Model")),
            ]
        ),
    ]}

    let authentication: Authentication
    let resourceId: String
    let uid: String

    var authMode: String {
        switch authentication {
        case .apiKey: Self.authModeAPIKey
        case .legacy: Self.authModeLegacy
        }
    }

    var apiKey: String? {
        guard case .apiKey(let value) = authentication else { return nil }
        return value
    }

    var appKey: String? {
        guard case .legacy(let value, _) = authentication else { return nil }
        return value
    }

    var accessKey: String? {
        guard case .legacy(_, let value) = authentication else { return nil }
        return value
    }

    init?(credentials: [String: String]) {
        let apiKey = Self.trimmedCredential("apiKey", in: credentials)
        let appKey = Self.trimmedCredential("appKey", in: credentials)
        let accessKey = Self.trimmedCredential("accessKey", in: credentials)

        switch Self.inferredAuthMode(in: credentials) {
        case Self.authModeLegacy:
            guard let appKey, let accessKey else { return nil }
            self.authentication = .legacy(appKey: appKey, accessKey: accessKey)
        default:
            guard let apiKey else { return nil }
            self.authentication = .apiKey(apiKey)
        }

        let raw = credentials["resourceId"] ?? Self.resourceIdAuto
        if raw == Self.resourceIdAuto || raw.isEmpty {
            // Use resolved value from auto-detect, or default to seed
            self.resourceId = credentials["resolvedResourceId"]?.isEmpty == false
                ? credentials["resolvedResourceId"]!
                : Self.resourceIdSeedASR
        } else {
            self.resourceId = raw
        }
        self.uid = ASRIdentityStore.loadOrCreateUID()
    }

    func toCredentials() -> [String: String] {
        var values = [
            "authMode": authMode,
            "resourceId": resourceId,
        ]
        switch authentication {
        case .apiKey(let apiKey):
            values["apiKey"] = apiKey
        case .legacy(let appKey, let accessKey):
            values["appKey"] = appKey
            values["accessKey"] = accessKey
        }
        return values
    }

    var isValid: Bool {
        true
    }

    static func inferredAuthMode(in credentials: [String: String]) -> String {
        if let explicit = credentials["authMode"],
           explicit == authModeAPIKey || explicit == authModeLegacy {
            return explicit
        }
        if trimmedCredential("apiKey", in: credentials) != nil {
            return authModeAPIKey
        }
        if trimmedCredential("appKey", in: credentials) != nil,
           trimmedCredential("accessKey", in: credentials) != nil {
            return authModeLegacy
        }
        return authModeAPIKey
    }

    private static func trimmedCredential(_ key: String, in credentials: [String: String]) -> String? {
        guard let value = credentials[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty
        else { return nil }
        return value
    }
}
