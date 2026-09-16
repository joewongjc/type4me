import Foundation

/// Origin of a model's price rate.
public enum ModelPriceSource: String, Codable, Sendable {
    case remote     // OpenRouter sync
    case builtin    // compile-time seed catalog
    case free       // local engine, definitively free
    case unknown    // not in catalog; token counting only, no pricing
}

/// One normalized pricing entry (USD per 1M tokens).
public struct ModelPriceEntry: Codable, Sendable, Equatable {
    public let key: String
    public let inputPricePerMTok: Double
    public let outputPricePerMTok: Double

    public init(key: String, inputPricePerMTok: Double, outputPricePerMTok: Double) {
        self.key = key
        self.inputPricePerMTok = inputPricePerMTok
        self.outputPricePerMTok = outputPricePerMTok
    }
}

/// A synced pricing table snapshot from the upstream Models API.
public struct LLMPricingSnapshot: Codable, Sendable, Equatable {
    public let fetchedAt: Date
    public let sourceURL: String
    public let entries: [ModelPriceEntry]

    public init(fetchedAt: Date, sourceURL: String, entries: [ModelPriceEntry]) {
        self.fetchedAt = fetchedAt
        self.sourceURL = sourceURL
        self.entries = entries
    }
}

/// Shared normalization entry points for upstream and local model identifiers.
public enum LLMPricingNormalizer {

    /// Normalizes an OpenRouter model ID (e.g. "openai/gpt-5.4-mini") to a lookup key.
    /// Returns nil for `:variant` IDs (`:free`, `:batch`, …) whose zero or
    /// different pricing must not shadow the base model. `~alias` IDs are
    /// accepted (prefix stripped): aliases sometimes carry the only pricing
    /// for a family (e.g. `~deepseek/deepseek-flash-latest` is the sole
    /// upstream entry for the user-facing `deepseek-flash`).
    public static func normalizeUpstreamID(_ id: String) -> String? {
        if id.contains(":") { return nil }
        var value = id
        if value.hasPrefix("~") { value = String(value.dropFirst()) }
        let name = value.contains("/") ? String(value.suffix(from: value.lastIndex(of: "/")!).dropFirst()) : value
        let trimmed = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Normalizes a local model + provider pair to a lookup key.
    /// Doubao strips the `doubao-` prefix and a trailing 6-digit date suffix;
    /// the Gemini API's `models/` prefix is stripped regardless of provider.
    public static func normalizeLocalModel(_ model: String, provider: String) -> String {
        let lowerProvider = provider.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        var key = model.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        // Gemini API convention: model names arrive as "models/<name>".
        if key.hasPrefix("models/") {
            key = String(key.dropFirst("models/".count))
        }

        if lowerProvider == "doubao" || key.hasPrefix("doubao-") {
            if key.hasPrefix("doubao-") {
                key = String(key.dropFirst("doubao-".count))
            }
            if let range = key.range(of: #"-\d{6}$"#, options: .regularExpression) {
                key = String(key[..<range.lowerBound])
            }
        }
        return key
    }

    /// Unifies digit separators (`2-0` vs `2.0`) so hyphen-style vendor console
    /// names (`seed-2-0-mini` on Doubao) match dot-style catalog keys
    /// (`seed-2.0-mini` on OpenRouter). Must be applied symmetrically to both
    /// index keys and lookup keys.
    public static func canonicalDigitSeparators(_ key: String) -> String {
        key.replacingOccurrences(of: #"(\d)[-.](\d)"#, with: "$1.$2", options: .regularExpression)
    }
}
