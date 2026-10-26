import XCTest
@testable import Type4Me

final class CartesiaProtocolTests: XCTestCase {
    func testConfigDefaultsToInk2English() throws {
        let config = try XCTUnwrap(CartesiaASRConfig(credentials: ["apiKey": "key"]))
        XCTAssertEqual(CartesiaASRConfig.model, "ink-2")
        XCTAssertEqual(CartesiaASRConfig.language, "en")
        XCTAssertTrue(config.isValid)
        XCTAssertTrue(ASRProviderRegistry.configType(for: .cartesia) == CartesiaASRConfig.self)
        XCTAssertTrue(ASRProviderRegistry.entry(for: .cartesia)?.isAvailable == true)
    }

    func testWebSocketURLUsesDocumentedInk2ParametersAndKeyterms() throws {
        let config = try XCTUnwrap(CartesiaASRConfig(credentials: ["apiKey": "key"]))
        let url = try CartesiaProtocol.buildWebSocketURL(
            config: config,
            options: ASRRequestOptions(hotwords: ["Type4Me", "Ink 2"])
        )
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(url.host, "api.cartesia.ai")
        XCTAssertEqual(items.first(where: { $0.name == "model" })?.value, "ink-2")
        XCTAssertEqual(items.first(where: { $0.name == "encoding" })?.value, "pcm_s16le")
        XCTAssertEqual(items.first(where: { $0.name == "sample_rate" })?.value, "16000")
        XCTAssertEqual(items.first(where: { $0.name == "cartesia_version" })?.value, CartesiaProtocol.apiVersion)
        XCTAssertEqual(items.filter { $0.name == "keyterm" }.compactMap(\.value), ["Type4Me", "Ink 2"])
    }

    func testTranscriptDeltasAreConcatenatedOnlyWhenFinal() throws {
        let partial = try CartesiaProtocol.makeTranscriptUpdate(
            from: Data(#"{"type":"transcript","is_final":false,"text":"Hello"}"#.utf8),
            confirmedSegments: []
        )
        XCTAssertEqual(partial?.transcript.partialText, "Hello")
        XCTAssertTrue(partial?.confirmedSegments.isEmpty == true)

        let final = try CartesiaProtocol.makeTranscriptUpdate(
            from: Data(#"{"type":"transcript","is_final":true,"text":"Hello world"}"#.utf8),
            confirmedSegments: []
        )
        XCTAssertEqual(final?.transcript.authoritativeText, "Hello world")
        XCTAssertTrue(final?.transcript.isFinal == true)
    }
}
