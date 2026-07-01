import Foundation

enum LLMRuntime {
    static func currentClient(isCloudMode: Bool = false) -> any LLMClient {
        #if HAS_CLOUD_SUBSCRIPTION
        if isCloudMode { return CloudLLMClient() }
        #endif

        let provider = KeychainService.selectedLLMProvider
        if provider == .claude {
            return ClaudeChatClient()
        }
        return DoubaoChatClient(provider: provider)
    }

    static func currentConfig(isCloudMode: Bool = false) -> LLMConfig? {
        #if HAS_CLOUD_SUBSCRIPTION
        if isCloudMode { return LLMConfig(apiKey: "", model: "cloud") }
        #endif

        return KeychainService.loadLLMConfig()
    }
}
