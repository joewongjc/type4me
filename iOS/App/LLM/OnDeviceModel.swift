import Foundation
import FoundationModels
import Type4MeTransferCore

/// Apple's on-device model (Apple Intelligence) as a text model that needs
/// no account or API key. It is stored like any other text model, with a
/// provider ID the Mac never sends, so `ChatClient` routes it here.
enum OnDeviceModel {
    static let providerID = "appleOnDevice"
    static var displayName: String { L("Apple 设备端模型", "Apple On-Device Model") }

    static var endpoint: Type4MeTransferPayload.Endpoint {
        // `LLMEndpointConfig` needs a base URL and a model; neither is used.
        .init(provider: providerID, fields: ["baseURL": "apple://on-device", "model": "system"])
    }

    static var isAvailable: Bool { SystemLanguageModel.default.isAvailable }

    /// Why the model can't be used on this iPhone, or nil when it can.
    static var unavailableReason: String? {
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(.deviceNotEligible):
            return L("这台 iPhone 不支持 Apple 智能。", "This iPhone doesn't support Apple Intelligence.")
        case .unavailable(.appleIntelligenceNotEnabled):
            return L("请先在「设置 › Apple 智能与 Siri」里打开 Apple 智能。", "Turn on Apple Intelligence in Settings › Apple Intelligence & Siri first.")
        case .unavailable(.modelNotReady):
            return L("Apple 智能模型还在下载，稍后再试。", "The Apple Intelligence model is still downloading. Try again later.")
        case .unavailable:
            return L("Apple 设备端模型暂时不可用。", "The Apple on-device model isn't available right now.")
        }
    }

    static func complete(system: String?, user: String, timeout: TimeInterval) async throws -> String {
        if let unavailableReason { throw OnDeviceModelError.unavailable(unavailableReason) }
        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                let session = LanguageModelSession(instructions: system)
                let response = try await session.respond(to: user)
                let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { throw ChatClientError.emptyResponse }
                return text
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw OnDeviceModelError.timedOut
            }
            let first = try await group.next()!
            group.cancelAll()
            return first
        }
    }
}

enum OnDeviceModelError: LocalizedError {
    case unavailable(String)
    case timedOut

    var errorDescription: String? {
        switch self {
        case .unavailable(let reason): return reason
        case .timedOut: return L("Apple 设备端模型处理超时", "The Apple on-device model timed out")
        }
    }
}
