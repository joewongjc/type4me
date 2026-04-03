import Foundation

// MARK: - Provider Enum

enum ASRProvider: String, CaseIterable, Codable, Sendable {
    // Local
    case sherpa
    case apple
    // International
    case openai
    case azure
    case google
    case aws
    case deepgram
    case assemblyai
    case elevenlabs
    case soniox
    // China
    case volcano
    case aliyun
    case bailian
    case tencent
    case baidu
    case iflytek
    // Cloud
    case cloud
    // Fallback
    case custom

    var displayName: String {
        switch self {
        case .sherpa:   return L("SenseVoice 流式 + Qwen3 ASR 校准", "SenseVoice Streaming + Qwen3 ASR")
        case .apple:    return "Apple Speech"
        case .openai:   return "OpenAI"
        case .azure:    return "Azure Speech"
        case .google:   return "Google Cloud STT"
        case .aws:      return "AWS Transcribe"
        case .deepgram: return "Deepgram"
        case .assemblyai: return "AssemblyAI"
        case .elevenlabs: return "ElevenLabs"
        case .soniox:   return "Soniox"
        case .volcano:  return L("火山引擎 (Doubao)", "Volcano (Doubao)")
        case .aliyun:   return L("阿里云", "Alibaba Cloud")
        case .bailian:  return L("阿里云百炼", "Alibaba Cloud Bailian")
        case .tencent:  return L("腾讯云", "Tencent Cloud")
        case .baidu:    return L("百度智能云", "Baidu AI Cloud")
        case .iflytek:  return L("讯飞", "iFLYTEK")
        case .cloud:    return "Type4Me Cloud"
        case .custom:   return L("自定义", "Custom")
        }
    }

    /// Whether this provider runs entirely on-device (no network required).
    var isLocal: Bool { self == .sherpa }
}

// MARK: - Credential Field Descriptor

struct FieldOption: Sendable {
    let value: String
    let label: String
}

struct CredentialField: Sendable, Identifiable {
    let key: String
    let label: String
    let placeholder: String
    let isSecure: Bool
    let isOptional: Bool
    let defaultValue: String
    /// When non-empty, the UI renders a Picker instead of a TextField.
    let options: [FieldOption]
    /// When true (and options is non-empty), the picker includes a "Custom" entry
    /// that reveals a text field for free-form input.
    let allowCustomInput: Bool

    /// Sentinel value used in the picker to represent "custom input" mode.
    static let customValue = "_custom"

    var id: String { key }

    init(key: String, label: String, placeholder: String, isSecure: Bool, isOptional: Bool, defaultValue: String, options: [FieldOption] = [], allowCustomInput: Bool = false) {
        self.key = key
        self.label = label
        self.placeholder = placeholder
        self.isSecure = isSecure
        self.isOptional = isOptional
        self.defaultValue = defaultValue
        self.options = options
        self.allowCustomInput = allowCustomInput
    }
}

// MARK: - Provider Config Protocol

protocol ASRProviderConfig: Sendable {
    static var provider: ASRProvider { get }
    static var displayName: String { get }
    static var credentialFields: [CredentialField] { get }

    init?(credentials: [String: String])
    func toCredentials() -> [String: String]
    var isValid: Bool { get }
}
