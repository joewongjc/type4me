import XCTest
@testable import Type4Me

final class StepFunASRConfigTests: XCTestCase {

    func testConfigTrimsAPIKey() throws {
        let config = try XCTUnwrap(StepFunASRConfig(credentials: ["apiKey": "  sk-test  "]))
        XCTAssertEqual(config.apiKey, "sk-test")
        XCTAssertEqual(config.toCredentials(), ["apiKey": "sk-test"])
        XCTAssertTrue(config.isValid)
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
