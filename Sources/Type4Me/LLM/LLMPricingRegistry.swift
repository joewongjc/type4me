import Foundation

/// Price rate per 1 Million Tokens in USD, tagged with its source.
public struct ModelPriceRate: Sendable, Equatable {
    public let inputPricePerMTok: Double
    public let outputPricePerMTok: Double
    public let source: ModelPriceSource

    public var isFree: Bool { source == .free }
    public var isUnknown: Bool { source == .unknown }

    public init(inputPricePerMTok: Double, outputPricePerMTok: Double, source: ModelPriceSource) {
        self.inputPricePerMTok = inputPricePerMTok
        self.outputPricePerMTok = outputPricePerMTok
        self.source = source
    }
}

/// Central registry of pricing rates for mainstream LLM providers and models.
///
/// Resolution order (first hit wins):
/// 1. Local free engines (ollama / mlx / local / codex CLI);
/// 2. Exact match against the remote (OpenRouter-synced) index, then the seed catalog;
/// 3. Longest-prefix family fallback against remote, then seed;
/// 4. Unknown — token counting only, no cost attribution.
public enum LLMPricingRegistry {
    /// Fixed reference exchange rate for displaying CNY equivalence.
    public static let usdToCnyRate: Double = 7.20
    private static let lock = NSLock()
    private static var remoteEntries: [String: ModelPriceEntry]?
    private static var remoteFetchedAt: Date?

    private static let seedIndex: [String: ModelPriceEntry] = {
        var index: [String: ModelPriceEntry] = [:]
        for entry in LLMPricingCatalog.seedEntries {
            let key = LLMPricingNormalizer.canonicalDigitSeparators(entry.key)
            if index[key] == nil { index[key] = entry }
        }
        return index
    }()

    /// Minimum key length for prefix-family fallback candidates, to avoid
    /// short keys (e.g. "o1") matching arbitrary models.
    private static let minFallbackKeyLength = 4

    private static let freeProviders: Set<String> = ["ollama", "mlx", "local", "codexcli"]

    // MARK: - Remote snapshot

    /// Installs a remotely synced pricing snapshot (thread-safe).
    public static func applyRemoteSnapshot(_ snapshot: LLMPricingSnapshot) {
        var index: [String: ModelPriceEntry] = [:]
        for entry in snapshot.entries {
            let key = LLMPricingNormalizer.canonicalDigitSeparators(entry.key)
            if index[key] == nil { index[key] = entry }
        }
        lock.lock()
        defer { lock.unlock() }
        remoteEntries = index
        remoteFetchedAt = snapshot.fetchedAt
    }

    /// Timestamp of the last applied remote snapshot, if any.
    public static var remoteSnapshotFetchedAt: Date? {
        lock.lock()
        defer { lock.unlock() }
        return remoteFetchedAt
    }

    // MARK: - Resolution

    /// Matches provider and model string to its corresponding price rate.
    public static func rate(for model: String, provider: String) -> ModelPriceRate {
        let lowerModel = model.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let lowerProvider = provider.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        // 1. Local models / open-source engines / subscription-less CLI are free
        if freeProviders.contains(lowerProvider) ||
            lowerModel.contains("ollama") || lowerModel.contains("mlx") || lowerModel.contains("local") {
            return ModelPriceRate(inputPricePerMTok: 0, outputPricePerMTok: 0, source: .free)
        }

        lock.lock()
        let remote = remoteEntries
        lock.unlock()

        let key = LLMPricingNormalizer.canonicalDigitSeparators(
            LLMPricingNormalizer.normalizeLocalModel(model, provider: provider)
        )

        // 2. Exact match: remote first, then seed
        if let entry = remote?[key] {
            return ModelPriceRate(inputPricePerMTok: entry.inputPricePerMTok, outputPricePerMTok: entry.outputPricePerMTok, source: .remote)
        }
        if let entry = seedIndex[key] {
            return ModelPriceRate(inputPricePerMTok: entry.inputPricePerMTok, outputPricePerMTok: entry.outputPricePerMTok, source: .builtin)
        }

        // 3. Longest-prefix family fallback (e.g. "deepseek-v4-flash" ↔ "deepseek-v4-flash-0731")
        if let entry = longestPrefixMatch(key: key, in: remote) {
            return ModelPriceRate(inputPricePerMTok: entry.inputPricePerMTok, outputPricePerMTok: entry.outputPricePerMTok, source: .remote)
        }
        if let entry = longestPrefixMatch(key: key, in: seedIndex) {
            return ModelPriceRate(inputPricePerMTok: entry.inputPricePerMTok, outputPricePerMTok: entry.outputPricePerMTok, source: .builtin)
        }

        // 4. Unknown: not in catalog; count tokens but attribute no cost
        return ModelPriceRate(inputPricePerMTok: 0, outputPricePerMTok: 0, source: .unknown)
    }

    private static func longestPrefixMatch(key: String, in index: [String: ModelPriceEntry]?) -> ModelPriceEntry? {
        guard let index, !index.isEmpty, !key.isEmpty else { return nil }
        var best: (entry: ModelPriceEntry, keyLength: Int)?
        for (candidateKey, entry) in index {
            guard candidateKey.count >= minFallbackKeyLength else { continue }
            if candidateKey.hasPrefix(key) || key.hasPrefix(candidateKey) {
                if best == nil || candidateKey.count > best!.keyLength {
                    best = (entry, candidateKey.count)
                }
            }
        }
        return best?.entry
    }

    /// Calculates total USD cost for a given model and token count.
    public static func calculateCostUSD(
        model: String,
        provider: String,
        promptTokens: Int,
        completionTokens: Int
    ) -> Double {
        let price = rate(for: model, provider: provider)
        guard !price.isFree, !price.isUnknown else { return 0.0 }
        let inputCost = (Double(max(0, promptTokens)) / 1_000_000.0) * price.inputPricePerMTok
        let outputCost = (Double(max(0, completionTokens)) / 1_000_000.0) * price.outputPricePerMTok
        return inputCost + outputCost
    }
}
