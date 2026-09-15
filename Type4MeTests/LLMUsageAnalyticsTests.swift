import XCTest
@testable import Type4Me

final class LLMUsageAnalyticsTests: XCTestCase {

    private var store: HistoryStore!
    private var testPath: String!

    override func setUp() async throws {
        testPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("type4me-llm-test-\(UUID().uuidString).db").path
        store = HistoryStore(path: testPath)
    }

    override func tearDown() async throws {
        store = nil
        try? FileManager.default.removeItem(atPath: testPath)
    }

    func testPricingRegistryRates() {
        // DeepSeek
        let ds = LLMPricingRegistry.rate(for: "deepseek-chat", provider: "deepseek")
        XCTAssertEqual(ds.inputPricePerMTok, 0.14)
        XCTAssertEqual(ds.outputPricePerMTok, 0.28)
        XCTAssertFalse(ds.isFree)

        let dsR1 = LLMPricingRegistry.rate(for: "deepseek-reasoner", provider: "deepseek")
        XCTAssertEqual(dsR1.inputPricePerMTok, 0.55)
        XCTAssertEqual(dsR1.outputPricePerMTok, 2.19)

        // Claude 3.5 Sonnet
        let sonnet = LLMPricingRegistry.rate(for: "claude-3-5-sonnet-20241022", provider: "claude")
        XCTAssertEqual(sonnet.inputPricePerMTok, 3.00)
        XCTAssertEqual(sonnet.outputPricePerMTok, 15.00)

        // Free / Local
        let ollama = LLMPricingRegistry.rate(for: "qwen2.5:7b", provider: "ollama")
        XCTAssertTrue(ollama.isFree)
        XCTAssertEqual(ollama.inputPricePerMTok, 0)
    }

    func testCostCalculation() {
        // DeepSeek V3: 1M prompt ($0.14) + 1M completion ($0.28) = $0.42
        let cost = LLMPricingRegistry.calculateCostUSD(
            model: "deepseek-chat",
            provider: "deepseek",
            promptTokens: 1_000_000,
            completionTokens: 1_000_000
        )
        XCTAssertEqual(cost, 0.42, accuracy: 0.0001)

        // Free model cost should be 0
        let freeCost = LLMPricingRegistry.calculateCostUSD(
            model: "local-model",
            provider: "ollama",
            promptTokens: 500_000,
            completionTokens: 500_000
        )
        XCTAssertEqual(freeCost, 0.0)
    }

    func testTokenEstimationHeuristics() {
        // Empty
        XCTAssertEqual(LLMUsageRecorder.estimateTokens(for: ""), 0)

        // CJK text: "今天天气不错" (6 chars * 0.7 = 4.2 -> 5 tokens)
        let cjkTokens = LLMUsageRecorder.estimateTokens(for: "今天天气不错")
        XCTAssertGreaterThanOrEqual(cjkTokens, 4)

        // English text: "Hello world"
        let enTokens = LLMUsageRecorder.estimateTokens(for: "Hello world")
        XCTAssertGreaterThanOrEqual(enTokens, 2)
    }

    func testInsertAndFetchLLMUsageReport() async {
        let record1 = LLMUsageRecord(
            id: "usage_1",
            createdAt: Date(),
            featureSource: .dictationPolish,
            provider: "deepseek",
            model: "deepseek-chat",
            promptTokens: 1000,
            completionTokens: 200,
            durationSeconds: 1.2,
            costUSD: 0.000196,
            status: "success",
            isEstimated: false
        )

        let record2 = LLMUsageRecord(
            id: "usage_2",
            createdAt: Date(),
            featureSource: .voiceRevise,
            provider: "claude",
            model: "claude-3-5-sonnet",
            promptTokens: 500,
            completionTokens: 100,
            durationSeconds: 1.5,
            costUSD: 0.003,
            status: "success",
            isEstimated: true
        )

        await store.insertLLMUsage(record1)
        await store.insertLLMUsage(record2)

        let report = await store.getLLMUsageReport()

        // Summary Assertions
        XCTAssertEqual(report.summary.totalRequests, 2)
        XCTAssertEqual(report.summary.successfulRequests, 2)
        XCTAssertEqual(report.summary.totalPromptTokens, 1500)
        XCTAssertEqual(report.summary.totalCompletionTokens, 300)
        XCTAssertEqual(report.summary.totalTokens, 1800)
        XCTAssertEqual(report.summary.totalCostUSD, 0.003196, accuracy: 0.00001)
        XCTAssertTrue(report.summary.hasEstimatedUsage)
        XCTAssertEqual(report.summary.estimatedRequestCount, 1)

        // Model Breakdowns Assertions
        XCTAssertEqual(report.modelBreakdowns.count, 2)
        let deepseekRow = report.modelBreakdowns.first(where: { $0.provider == "deepseek" })
        XCTAssertNotNil(deepseekRow)
        XCTAssertEqual(deepseekRow?.totalTokens, 1200)
        XCTAssertFalse(deepseekRow?.hasEstimatedUsage ?? true)

        let claudeRow = report.modelBreakdowns.first(where: { $0.provider == "claude" })
        XCTAssertNotNil(claudeRow)
        XCTAssertTrue(claudeRow?.hasEstimatedUsage ?? false)

        // Feature Breakdowns Assertions
        XCTAssertEqual(report.featureBreakdowns.count, 2)
        let polish = report.featureBreakdowns.first(where: { $0.feature == .dictationPolish })
        XCTAssertEqual(polish?.requestCount, 1)
        let revise = report.featureBreakdowns.first(where: { $0.feature == .voiceRevise })
        XCTAssertEqual(revise?.requestCount, 1)
    }

    func testHistoricalBackfill() async {
        // Insert a historical recognition record with LLM provider
        let record = HistoryRecord(
            id: "hist_1",
            createdAt: Date(),
            durationSeconds: 3.0,
            rawText: "测试听写原始输入",
            processingMode: "润色",
            processedText: "测试听写润色结果",
            finalText: "测试听写润色结果",
            status: "completed",
            characterCount: 8,
            asrProvider: "volcano",
            asrModel: "volcano_bigmodel",
            llmProvider: "deepseek",
            llmModel: "deepseek-chat",
            llmDurationSeconds: 1.1
        )
        await store.insert(record)

        // Reset the backfill flag for testing
        UserDefaults.standard.removeObject(forKey: "tf_llm_usage_backfill_completed")

        // Trigger backfill
        await store.backfillHistoricalLLMUsageIfNeeded()

        // Verify that llm_usage_history now contains the backfilled record
        let report = await store.getLLMUsageReport()
        XCTAssertEqual(report.summary.totalRequests, 1)
        XCTAssertEqual(report.summary.successfulRequests, 1)
        XCTAssertTrue(report.summary.hasEstimatedUsage)
        XCTAssertEqual(report.modelBreakdowns.first?.modelName, "deepseek-chat")
    }
}
