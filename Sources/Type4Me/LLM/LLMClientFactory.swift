import Foundation

enum LLMClientFactory {
    static func make(
        for provider: LLMProvider,
        bypassProxy: Bool = ProxyBypassMode.current.bypassLLM
    ) -> any LLMClient {
        switch provider {
        case .claude:
            return ClaudeChatClient(bypassProxy: bypassProxy)
        case .codexCLI:
            // Codex App Server is intentionally long-lived so subsequent
            // transformations can reuse its warm model context.
            return CodexCLIClient.shared
        default:
            return DoubaoChatClient(provider: provider, bypassProxy: bypassProxy)
        }
    }
}
