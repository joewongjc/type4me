import Foundation

// MARK: - Provider Enum

enum ASRProvider: String, CaseIterable, Codable, Sendable {
    // Local
    case sherpa
    // International
    case openai
    case azure
    case google
    case aws
    case deepgram
    case assemblyai
    // China
    case volcano
    case aliyun
    case bailian
    case tencent
    case baidu
    case iflytek
    // Fallback
    case custom

    var displayName: String {
        switch self {
        case .sherpa:   return L("本地识别 (Paraformer)", "Local (Paraformer)")
        case .openai:   return "OpenAI Whisper"
        case .azure:    return "Azure Speech"
        case .google:   return "Google Cloud STT"
        case .aws:      return "AWS Transcribe"
        case .deepgram: return "Deepgram"
        case .assemblyai: return "AssemblyAI"
        case .volcano:  return L("火山引擎 (Doubao)", "Volcano (Doubao)")
        case .aliyun:   return L("阿里云", "Alibaba Cloud")
        case .bailian:  return L("阿里云百炼", "Alibaba Cloud Bailian")
        case .tencent:  return L("腾讯云", "Tencent Cloud")
        case .baidu:    return L("百度智能云", "Baidu AI Cloud")
        case .iflytek:  return L("讯飞", "iFLYTEK")
        case .custom:   return L("自定义", "Custom")
        }
    }

    /// Whether this provider runs entirely on-device (no network required).
    var isLocal: Bool { self == .sherpa }
}

// MARK: - Credential Field Descriptor

struct CredentialField: Sendable, Identifiable {
    let key: String
    let label: String
    let placeholder: String
    let isSecure: Bool
    let isOptional: Bool
    let defaultValue: String

    var id: String { key }
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
