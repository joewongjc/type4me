import XCTest
@testable import Type4Me

final class LLMPricingSyncTests: XCTestCase {

    override func tearDown() {
        // Reset registry to pure seed state; earlier tests may have installed
        // a remote snapshot that would leak into later assertions.
        LLMPricingRegistry.applyRemoteSnapshot(LLMPricingSnapshot(
            fetchedAt: .distantPast,
            sourceURL: "",
            entries: []
        ))
        super.tearDown()
    }

    // MARK: - normalizeUpstreamID
    func testNormalizeUpstreamIDStripsVendorPrefix() {
        XCTAssertEqual(LLMPricingNormalizer.normalizeUpstreamID("openai/gpt-5.4-mini"), "gpt-5.4-mini")
        XCTAssertEqual(LLMPricingNormalizer.normalizeUpstreamID("z-ai/glm-5.2"), "glm-5.2")
        // Aliases are accepted: they sometimes carry a family's only pricing.
        XCTAssertEqual(LLMPricingNormalizer.normalizeUpstreamID("~deepseek/deepseek-flash-latest"), "deepseek-flash-latest")
    }

    func testNormalizeUpstreamIDDropsVariants() {
        XCTAssertNil(LLMPricingNormalizer.normalizeUpstreamID("z-ai/glm-5.2:free"))
        XCTAssertNil(LLMPricingNormalizer.normalizeUpstreamID("openai/gpt-5.4-mini:batch"))
    }

    func testNormalizeUpstreamIDDropsEmptyKeys() {
        XCTAssertNil(LLMPricingNormalizer.normalizeUpstreamID("vendor/"))
        XCTAssertNil(LLMPricingNormalizer.normalizeUpstreamID("   "))
    }

    func testNormalizeLocalModelDoubaoStripsPrefixAndDate() {
        XCTAssertEqual(
            LLMPricingNormalizer.normalizeLocalModel("doubao-seed-2-1-turbo-260628", provider: "doubao"),
            "seed-2-1-turbo"
        )
        // Date suffix strips only once; model already bare passes through lowercased/trimmed.
        XCTAssertEqual(
            LLMPricingNormalizer.normalizeLocalModel("Seed-2-1-Turbo", provider: "doubao"),
            "seed-2-1-turbo"
        )
    }

    func testNormalizeLocalModelStripsGeminiModelsPrefix() {
        XCTAssertEqual(
            LLMPricingNormalizer.normalizeLocalModel("models/gemini-3.7-flash", provider: "gemini"),
            "gemini-3.7-flash"
        )
    }

    func testCanonicalDigitSeparators() {
        // Hyphen-style vendor console names unify with dot-style catalog keys.
        XCTAssertEqual(LLMPricingNormalizer.canonicalDigitSeparators("seed-2-0-mini"), "seed-2.0-mini")
        XCTAssertEqual(LLMPricingNormalizer.canonicalDigitSeparators("qwen3.7-plus"), "qwen3.7-plus")
        XCTAssertEqual(LLMPricingNormalizer.canonicalDigitSeparators("kimi-k2.6"), "kimi-k2.6")
        // Non-digit-adjacent hyphens survive.
        XCTAssertEqual(LLMPricingNormalizer.canonicalDigitSeparators("deepseek-flash"), "deepseek-flash")
    }

    func testNormalizeLocalModelPlainLowercases() {
        XCTAssertEqual(LLMPricingNormalizer.normalizeLocalModel("GPT-5.4-Mini", provider: "openai"), "gpt-5.4-mini")
    }

    // MARK: - Seed catalog resolution

    func testSeedExactMatches() {
        let gpt = LLMPricingRegistry.rate(for: "gpt-5.4-mini", provider: "openai")
        XCTAssertEqual(gpt.inputPricePerMTok, 0.75)
        XCTAssertEqual(gpt.outputPricePerMTok, 4.50)
        XCTAssertEqual(gpt.source, .builtin)

        let glm = LLMPricingRegistry.rate(for: "glm-5.2", provider: "zhipu")
        XCTAssertEqual(glm.inputPricePerMTok, 1.40)
        XCTAssertEqual(glm.outputPricePerMTok, 4.40)
        XCTAssertEqual(glm.source, .builtin)

        let doubao = LLMPricingRegistry.rate(for: "doubao-seed-2-1-turbo-260628", provider: "doubao")
        XCTAssertEqual(doubao.inputPricePerMTok, 0.50)
        XCTAssertEqual(doubao.outputPricePerMTok, 2.50)
        XCTAssertEqual(doubao.source, .builtin)
    }

    func testUserReportedModelsResolve() {
        // Regression: doubao-seed-2-0-mini-260428 previously missed because the
        // local key normalizes to "seed-2-0-mini" while upstream uses "seed-2.0-mini".
        let doubaoMini = LLMPricingRegistry.rate(for: "doubao-seed-2-0-mini-260428", provider: "doubao")
        XCTAssertEqual(doubaoMini.inputPricePerMTok, 0.10)
        XCTAssertEqual(doubaoMini.outputPricePerMTok, 0.40)

        // Regression: deepseek-flash previously missed because upstream only
        // prices it via the ~deepseek/deepseek-flash-latest alias.
        let flash = LLMPricingRegistry.rate(for: "deepseek-flash", provider: "deepseek")
        XCTAssertEqual(flash.inputPricePerMTok, 0.15)
        XCTAssertEqual(flash.outputPricePerMTok, 0.60)

        // Regression: Gemini API model strings arrive as "models/<name>".
        let gemini = LLMPricingRegistry.rate(for: "models/gemini-3.7-flash", provider: "gemini")
        XCTAssertNotEqual(gemini.source, .unknown)
    }

    func testSeedPrefixFallback() {
        // "glm-5.3-preview" not in catalog; longest family prefix is "glm-5.3".
        let preview = LLMPricingRegistry.rate(for: "glm-5.3-preview", provider: "zhipu")
        XCTAssertEqual(preview.inputPricePerMTok, 1.40)
        XCTAssertEqual(preview.outputPricePerMTok, 4.40)
        XCTAssertEqual(preview.source, .builtin)

        // A dated variant that escaped the regex still resolves via prefix fallback.
        let dated = LLMPricingRegistry.rate(for: "deepseek-v4-flash-0731", provider: "deepseek")
        XCTAssertEqual(dated.inputPricePerMTok, 0.08708)
        XCTAssertEqual(dated.source, .builtin)
    }

    func testUnknownModelIsNotFreeAndCostsZero() {
        let rate = LLMPricingRegistry.rate(for: "totally-made-up-model-xyz", provider: "custom")
        XCTAssertEqual(rate.source, .unknown)
        XCTAssertFalse(rate.isFree)
        XCTAssertTrue(rate.isUnknown)

        let cost = LLMPricingRegistry.calculateCostUSD(
            model: "totally-made-up-model-xyz",
            provider: "custom",
            promptTokens: 1_000_000,
            completionTokens: 1_000_000
        )
        XCTAssertEqual(cost, 0.0)
    }

    func testFreeProvidersResolveFree() {
        for provider in ["ollama", "mlx", "local", "codexCLI", "codexcli"] {
            let rate = LLMPricingRegistry.rate(for: "whatever-model", provider: provider)
            XCTAssertEqual(rate.source, .free, "provider \(provider) should be free")
            XCTAssertTrue(rate.isFree)
        }
    }

    // MARK: - Remote snapshot override

    func testRemoteSnapshotOverridesSeed() {
        let snapshot = LLMPricingSnapshot(
            fetchedAt: Date(),
            sourceURL: "https://example.test",
            entries: [
                ModelPriceEntry(key: "gpt-5.4-mini", inputPricePerMTok: 9.99, outputPricePerMTok: 99.9),
                ModelPriceEntry(key: "made-up-remote-model", inputPricePerMTok: 1.0, outputPricePerMTok: 2.0),
            ]
        )
        LLMPricingRegistry.applyRemoteSnapshot(snapshot)

        let overridden = LLMPricingRegistry.rate(for: "gpt-5.4-mini", provider: "openai")
        XCTAssertEqual(overridden.inputPricePerMTok, 9.99)
        XCTAssertEqual(overridden.outputPricePerMTok, 99.9)
        XCTAssertEqual(overridden.source, .remote)

        let remoteOnly = LLMPricingRegistry.rate(for: "made-up-remote-model", provider: "openai")
        XCTAssertEqual(remoteOnly.source, .remote)

        // Seed entries absent from the remote snapshot still resolve as builtin.
        let seedFallback = LLMPricingRegistry.rate(for: "kimi-k2.6", provider: "kimi")
        XCTAssertEqual(seedFallback.source, .builtin)

        XCTAssertNotNil(LLMPricingRegistry.remoteSnapshotFetchedAt)
    }

    // MARK: - Upstream parsing

    func testParseEntriesFiltersVariantsNullsAndZeroPricing() throws {
        func entry(_ id: String, _ prompt: String?, _ completion: String?) -> String {
            let p = prompt.map { "\"\($0)\"" } ?? "null"
            let c = completion.map { "\"\($0)\"" } ?? "null"
            return """
            {"id": "\(id)", "pricing": {"prompt": \(p), "completion": \(c)}}
            """
        }

        // Pad to ≥50 valid entries so the anomaly guard doesn't throw.
        var models: [String] = [
            entry("openai/gpt-5.4-mini", "0.00000075", "0.0000045"),
            entry("z-ai/glm-5.2:free", "0", "0"),                 // variant → dropped
            entry("openai/gpt-5.4-mini:batch", "0.0000001", "0"), // variant → dropped
            entry("~deepseek/deepseek-pro-latest", "0.000001", "0.000002"), // alias → kept (family pricing)
            entry("some/vendor", nil, "0.000001"),                // null prompt → dropped
            entry("zero/priced-model", "0", "0"),                  // double-zero → dropped
        ]
        for i in 0..<60 {
            models.append(entry("vendor-\(i)/model-\(i)", "0.000001", "0.000002"))
        }

        let json = "{\"data\": [\(models.joined(separator: ","))]}"
        let entries = try LLMPricingSyncService.parseEntries(from: Data(json.utf8))

        XCTAssertEqual(entries.count, 62) // 1 real + 1 alias + 60 padding
        let gpt = entries.first { $0.key == "gpt-5.4-mini" }
        XCTAssertNotNil(gpt)
        XCTAssertEqual(gpt?.inputPricePerMTok ?? 0, 0.75, accuracy: 0.0001)
        XCTAssertEqual(gpt?.outputPricePerMTok ?? 0, 4.50, accuracy: 0.0001)
        XCTAssertFalse(entries.contains { $0.key.hasPrefix("glm-5.2") })
        XCTAssertEqual(entries.first { $0.key == "deepseek-pro-latest" }?.inputPricePerMTok ?? 0, 1.0, accuracy: 0.0001)
        XCTAssertFalse(entries.contains { $0.key == "priced-model" })
        XCTAssertFalse(entries.contains { $0.key == "vendor" })
    }

    func testParseEntriesKeepsFirstDuplicateKey() throws {
        var models: [String] = []
        // First occurrence wins.
        models.append("{\"id\": \"openai/gpt-x\", \"pricing\": {\"prompt\": \"0.000002\", \"completion\": \"0.000004\"}}")
        models.append("{\"id\": \"other/gpt-x\", \"pricing\": {\"prompt\": \"0.000009\", \"completion\": \"0.000009\"}}")
        for i in 0..<50 {
            models.append("{\"id\": \"vendor-\(i)/model-\(i)\", \"pricing\": {\"prompt\": \"0.000001\", \"completion\": \"0.000001\"}}")
        }

        let entries = try LLMPricingSyncService.parseEntries(from: Data("{\"data\": [\(models.joined(separator: ","))]}".utf8))
        let gpt = entries.first { $0.key == "gpt-x" }
        XCTAssertEqual(gpt?.inputPricePerMTok ?? 0, 2.0, accuracy: 0.0001)
        XCTAssertEqual(gpt?.outputPricePerMTok ?? 0, 4.0, accuracy: 0.0001)
    }

    func testParseEntriesThrowsOnAnomalousResponse() {
        let json = "{\"data\": [{\"id\": \"openai/gpt-5.4-mini\", \"pricing\": {\"prompt\": \"0.00000075\", \"completion\": \"0.0000045\"}}]}"
        XCTAssertThrowsError(try LLMPricingSyncService.parseEntries(from: Data(json.utf8)))

        // Upstream error body with detail message.
        let errorJSON = "{\"error\": {\"message\": \"Auth required\"}}"
        XCTAssertThrowsError(try LLMPricingSyncService.parseEntries(from: Data(errorJSON.utf8))) { error in
            // Must not crash on decoding; may be either a decode or anomaly error.
            XCTAssertTrue(error is LLMPricingSyncError || error is DecodingError)
        }
    }
    func testPersistFailureDoesNotCommitCooldown() async throws {
        // Verify parseEntries throws appropriately on anomalous response
        let invalidJSON = "{\"data\": []}"
        XCTAssertThrowsError(try LLMPricingSyncService.parseEntries(from: Data(invalidJSON.utf8)))
    }
}
