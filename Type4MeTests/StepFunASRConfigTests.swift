import XCTest
@testable import Type4Me

final class StepFunASRConfigTests: XCTestCase {

    func testConfigTrimsAPIKey() throws {
        let config = try XCTUnwrap(StepFunASRConfig(credentials: ["apiKey": "  sk-test  "]))
        XCTAssertEqual(config.apiKey, "sk-test")
        XCTAssertEqual(config.region, .china)
        XCTAssertEqual(config.endpoint, StepFunASRRegion.china.webSocketEndpoint)
        XCTAssertEqual(config.recognitionMode, .streaming)
        XCTAssertEqual(config.toCredentials(), [
            "recognitionMode": "streaming",
            "apiKey": "sk-test",
            "region": "china",
            "accessMode": "standard",
        ])
        XCTAssertTrue(config.isValid)
    }

    func testConfigUsesGlobalWebSocketEndpoint() throws {
        let config = try XCTUnwrap(StepFunASRConfig(credentials: [
            "apiKey": "sk-test",
            "region": "global",
        ]))

        XCTAssertEqual(config.region, .global)
        XCTAssertEqual(config.endpoint.absoluteString, "wss://api.stepfun.ai/v1/realtime/asr/stream")
        XCTAssertEqual(config.toCredentials()["region"], "global")
    }

    func testUnknownRegionFallsBackToChina() throws {
        let config = try XCTUnwrap(StepFunASRConfig(credentials: [
            "apiKey": "sk-test",
            "region": "unknown",
        ]))

        XCTAssertEqual(config.region, .china)
    }

    func testConfigRequiresAPIKey() {
        XCTAssertNil(StepFunASRConfig(credentials: [:]))
        XCTAssertNil(StepFunASRConfig(credentials: ["apiKey": "   "]))
    }

    func testRegistryUsesStreamingClient() {
        XCTAssertTrue(ASRProviderRegistry.configType(for: .stepfun) == StepFunASRConfig.self)
        XCTAssertEqual(ASRProviderRegistry.capabilities(for: .stepfun, mode: .streaming), .streaming())
        XCTAssertEqual(ASRProviderRegistry.capabilities(for: .stepfun, mode: .batch), .batch())
        XCTAssertNotNil(ASRProviderRegistry.createClient(for: .stepfun))
    }

    // MARK: - Batch mode (merged from the former stepfunBatch provider)

    func testBatchMode_defaultsToStandardAccessWithSharedKey() throws {
        let config = try XCTUnwrap(StepFunASRConfig(credentials: [
            "recognitionMode": "batch",
            "apiKey": "sk-standard",
        ]))
        XCTAssertEqual(config.recognitionMode, .batch)
        XCTAssertEqual(config.accessMode, .standard)
        XCTAssertEqual(config.batchAPIKey, "sk-standard")
        XCTAssertTrue(config.isValid)
    }

    func testBatchMode_stepPlanRequiresStepPlanKey() throws {
        XCTAssertNil(StepFunASRConfig(credentials: [
            "recognitionMode": "batch",
            "accessMode": "stepPlan",
            "apiKey": "sk-standard",
        ]))

        let config = try XCTUnwrap(StepFunASRConfig(credentials: [
            "recognitionMode": "batch",
            "accessMode": "stepPlan",
            "stepPlanApiKey": " sk-plan ",
        ]))
        XCTAssertEqual(config.batchAPIKey, "sk-plan")
        XCTAssertEqual(config.toCredentials()["stepPlanApiKey"], "sk-plan")
        XCTAssertNil(config.toCredentials()["apiKey"])
    }

    func testDisplayedFields_dependOnModeAndAccessMode() {
        func keys(_ values: [String: String]) -> [String] {
            StepFunASRConfig.displayedCredentialFields(for: values).map(\.key)
        }
        XCTAssertEqual(keys(["recognitionMode": "streaming"]), ["recognitionMode", "apiKey", "region"])
        XCTAssertEqual(
            keys(["recognitionMode": "batch", "accessMode": "standard"]),
            ["recognitionMode", "accessMode", "apiKey"]
        )
        XCTAssertEqual(
            keys(["recognitionMode": "batch", "accessMode": "stepPlan"]),
            ["recognitionMode", "accessMode", "stepPlanApiKey"]
        )
    }
}
