import XCTest
@testable import Type4Me

final class ASRProviderRegistryTests: XCTestCase {

    func testVolcanoSupportsQuickAndPerformanceModes() {
        XCTAssertTrue(ASRProviderRegistry.supports(.direct, for: .volcano))
        XCTAssertTrue(ASRProviderRegistry.supports(.performance, for: .volcano))
        XCTAssertNil(ASRProviderRegistry.unsupportedReason(for: .performance, provider: .volcano))
    }

    func testQuickOnlyProvidersOnlySupportQuickMode() {
        for provider in [ASRProvider.baidu, .bailian, .deepgram, .assemblyai] {
            XCTAssertTrue(ASRProviderRegistry.supports(.direct, for: provider))
            XCTAssertFalse(ASRProviderRegistry.supports(.performance, for: provider))
            XCTAssertEqual(
                ASRProviderRegistry.unsupportedReason(for: .performance, provider: provider),
                L(
                    "当前引擎仅支持实时识别，不支持整段识别。",
                    "This engine only supports real-time recognition, not full-audio recognition."
                )
            )
        }
    }

    func testResolvedModeFallsBackToDirectForUnsupportedPerformanceMode() {
        XCTAssertEqual(
            ASRProviderRegistry.resolvedMode(for: .performance, provider: .baidu).id,
            ProcessingMode.directId
        )
        XCTAssertEqual(
            ASRProviderRegistry.resolvedMode(for: .performance, provider: .bailian).id,
            ProcessingMode.directId
        )
        XCTAssertEqual(
            ASRProviderRegistry.resolvedMode(for: .performance, provider: .deepgram).id,
            ProcessingMode.directId
        )
        XCTAssertEqual(
            ASRProviderRegistry.resolvedMode(for: .performance, provider: .assemblyai).id,
            ProcessingMode.directId
        )
    }

    func testSupportedModesFilterOnlyRemovesPerformanceModeForQuickOnlyProviders() {
        let customMode = ProcessingMode(
            id: UUID(),
            name: "Custom",
            prompt: "Rewrite: {text}",
            isBuiltin: false
        )
        let modes = [ProcessingMode.direct, ProcessingMode.performance, customMode]

        let baiduModes = ASRProviderRegistry.supportedModes(from: modes, for: .baidu)
        XCTAssertEqual(baiduModes.map(\.id), [ProcessingMode.directId, customMode.id])

        let bailianModes = ASRProviderRegistry.supportedModes(from: modes, for: .bailian)
        XCTAssertEqual(bailianModes.map(\.id), [ProcessingMode.directId, customMode.id])

        let assemblyModes = ASRProviderRegistry.supportedModes(from: modes, for: .assemblyai)
        XCTAssertEqual(assemblyModes.map(\.id), [ProcessingMode.directId, customMode.id])

        let volcanoModes = ASRProviderRegistry.supportedModes(from: modes, for: .volcano)
        XCTAssertEqual(volcanoModes.map(\.id), [ProcessingMode.directId, ProcessingMode.performanceId, customMode.id])
    }
}
