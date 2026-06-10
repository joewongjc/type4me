import XCTest
@testable import Type4Me

final class LLMClientCacheTests: XCTestCase {
    func testReusesClientForMatchingConfiguration() {
        var cache = LLMClientCache()
        let key = makeKey()
        let first = cache.resolve(key: key) { StubLLMClient() }
        let second = cache.resolve(key: key) { StubLLMClient() }

        XCTAssertFalse(first.reused)
        XCTAssertTrue(second.reused)
        XCTAssertEqual(
            ObjectIdentifier(first.client),
            ObjectIdentifier(second.client)
        )
        XCTAssertNil(second.invalidated)
    }

    func testInvalidatesClientWhenConfigurationChanges() async {
        var cache = LLMClientCache()
        let first = cache.resolve(key: makeKey()) { StubLLMClient() }
        let updatedKey = LLMClientCacheKey(
            providerID: "doubao",
            apiKey: "new-key",
            model: "new-model",
            baseURL: "https://new.example.com/v1",
            bypassProxy: true
        )
        let second = cache.resolve(key: updatedKey) { StubLLMClient() }

        XCTAssertFalse(second.reused)
        XCTAssertNotEqual(
            ObjectIdentifier(first.client),
            ObjectIdentifier(second.client)
        )
        XCTAssertEqual(
            second.reasons,
            ["apiKey", "model", "baseURL", "proxyBypass"]
        )

        await second.invalidated?.invalidate()
        let oldClient = first.client as? StubLLMClient
        let wasInvalidated = await oldClient?.isInvalidated
        XCTAssertEqual(wasInvalidated, true)
    }

    func testProviderChangeInvalidatesCachedClient() {
        var cache = LLMClientCache()
        _ = cache.resolve(key: makeKey()) { StubLLMClient() }
        let claudeKey = LLMClientCacheKey(
            providerID: "claude",
            apiKey: "key",
            model: "model",
            baseURL: "https://example.com/v1",
            bypassProxy: false
        )

        let resolution = cache.resolve(key: claudeKey) { StubLLMClient() }

        XCTAssertEqual(resolution.reasons, ["provider"])
        XCTAssertNotNil(resolution.invalidated)
    }

    private func makeKey() -> LLMClientCacheKey {
        LLMClientCacheKey(
            providerID: "doubao",
            apiKey: "key",
            model: "model",
            baseURL: "https://example.com/v1",
            bypassProxy: false
        )
    }
}

private actor StubLLMClient: LLMClient {
    private(set) var isInvalidated = false

    func process(text: String, prompt: String, config: LLMConfig) async throws -> String {
        text
    }

    func warmUp(baseURL: String) async {}

    func invalidate() async {
        isInvalidated = true
    }
}
