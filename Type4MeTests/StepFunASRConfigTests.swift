import XCTest
@testable import Type4Me

final class StepFunASRConfigTests: XCTestCase {

    func testConfigTrimsAPIKey() throws {
        let config = try XCTUnwrap(StepFunASRConfig(credentials: ["apiKey": "  sk-test  "]))
        XCTAssertEqual(config.apiKey, "sk-test")
        XCTAssertEqual(config.region, .china)
        XCTAssertEqual(config.endpoint, StepFunASRRegion.china.webSocketEndpoint)
        XCTAssertEqual(config.toCredentials(), ["apiKey": "sk-test", "region": "china"])
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
        XCTAssertEqual(ASRProviderRegistry.capabilities(for: .stepfun), .streaming())
        XCTAssertNotNil(ASRProviderRegistry.createClient(for: .stepfun))
    }
}
