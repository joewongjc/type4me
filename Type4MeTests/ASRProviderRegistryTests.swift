import XCTest
@testable import Type4Me

final class ASRProviderRegistryTests: XCTestCase {

    func testAvailableProvidersSupportDirectMode() {
        for provider in [ASRProvider.volcano, .baidu, .bailian, .deepgram, .assemblyai, .soniox, .openai, .apple] {
            XCTAssertTrue(ASRProviderRegistry.supports(.direct, for: provider))
        }
    }

    func testResolvedModeFallsBackToDirectForUnavailableProvider() {
        let customMode = ProcessingMode(
            id: UUID(),
            name: "Custom",
            prompt: "Rewrite: {text}",
            isBuiltin: false
        )
        // Custom/LLM modes should always be supported
        XCTAssertTrue(ASRProviderRegistry.supports(customMode, for: .bailian))
        XCTAssertTrue(ASRProviderRegistry.supports(customMode, for: .volcano))
    }

    func testSupportedModesFilterKeepsAllForAvailableProviders() {
        let customMode = ProcessingMode(
            id: UUID(),
            name: "Custom",
            prompt: "Rewrite: {text}",
            isBuiltin: false
        )
        let modes = [ProcessingMode.direct, customMode]

        let volcanoModes = ASRProviderRegistry.supportedModes(from: modes, for: .volcano)
        XCTAssertEqual(volcanoModes.map(\.id), [ProcessingMode.directId, customMode.id])

        let bailianModes = ASRProviderRegistry.supportedModes(from: modes, for: .bailian)
        XCTAssertEqual(bailianModes.map(\.id), [ProcessingMode.directId, customMode.id])
    }
}
