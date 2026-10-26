import Foundation

struct ResolvedLLMRuntime: Sendable {
    let providerID: String
    let client: any LLMClient
    let config: LLMConfig
}

struct ResolvedLLMRuntimeCacheEntry: Sendable {
    let runtime: ResolvedLLMRuntime
    let reused: Bool
    let invalidated: (any LLMClient)?
    let invalidationReasons: [String]
}

enum LLMRuntime {
    static func resolve(
        isCloudMode: Bool = false,
        cache: inout LLMClientCache
    ) -> ResolvedLLMRuntimeCacheEntry? {
        let bypassProxy = ProxyBypassMode.current.bypassLLM
        #if HAS_CLOUD_SUBSCRIPTION
        if isCloudMode {
            let config = LLMConfig(apiKey: "", model: "cloud")
            return resolveCached(
                providerID: "cloud",
                config: config,
                bypassProxy: bypassProxy,
                cache: &cache
            ) {
                CloudLLMClient(bypassProxy: bypassProxy)
            }
        }
        #endif

        let provider = KeychainService.selectedLLMProvider
        guard let config = KeychainService.loadLLMProviderConfig(for: provider)?.toLLMConfig() else {
            return nil
        }
        return resolveCached(
            providerID: provider.rawValue,
            config: config,
            bypassProxy: bypassProxy,
            cache: &cache
        ) {
            LLMClientFactory.make(for: provider, bypassProxy: bypassProxy)
        }
    }

    static func resolveCached(
        providerID: String,
        config: LLMConfig,
        bypassProxy: Bool,
        cache: inout LLMClientCache,
        makeClient: () -> any LLMClient
    ) -> ResolvedLLMRuntimeCacheEntry {
        let key = LLMClientCacheKey(
            providerID: providerID,
            apiKey: config.apiKey,
            model: config.model,
            baseURL: config.baseURL,
            bypassProxy: bypassProxy
        )
        let resolution = cache.resolve(key: key, makeClient: makeClient)
        return ResolvedLLMRuntimeCacheEntry(
            runtime: ResolvedLLMRuntime(
                providerID: providerID,
                client: resolution.client,
                config: config
            ),
            reused: resolution.reused,
            invalidated: resolution.invalidated,
            invalidationReasons: resolution.reasons
        )
    }
}
