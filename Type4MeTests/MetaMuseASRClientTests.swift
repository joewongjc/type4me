import XCTest
@testable import Type4Me

final class MetaMuseASRClientTests: XCTestCase {

    func testEndAudio_withoutConnect_doesNotThrow() async throws {
        let client = MetaMuseASRClient()
        try await client.endAudio()
    }

    func testSendAudio_withoutConnect_doesNotThrow() async throws {
        let client = MetaMuseASRClient()
        try await client.sendAudio(Data(repeating: 0, count: 3200))
        try await client.endAudio()
    }

    func testDisconnect_withoutConnect_isSafeAndRepeatable() async {
        let client = MetaMuseASRClient()
        await client.disconnect()
        await client.disconnect()
    }

    func testConnect_rejectsInvalidConfigType() async {
        let client = MetaMuseASRClient()
        struct DummyConfig: ASRProviderConfig {
            static var provider: ASRProvider { .apple }
            static var displayName: String { "Dummy" }
            static var credentialFields: [CredentialField] { [] }
            init?(credentials: [String: String]) {}
            func toCredentials() -> [String: String] { [:] }
            var isValid: Bool { true }
        }

        do {
            try await client.connect(config: DummyConfig(credentials: [:])!)
            XCTFail("Expected invalidConfig error")
        } catch {
            XCTAssertEqual(error as? MetaMuseASRError, .invalidConfig)
        }
    }

    func testCloseTracker_recordsFirstAbnormalCloseOnly() async {
        let tracker = MetaMuseCloseTracker()
        await tracker.recordClose(code: .internalServerError, reason: "first")
        await tracker.recordClose(code: .policyViolation, reason: "second")

        let consumed = await tracker.consumeCloseError()
        guard let museError = consumed as? MetaMuseASRError,
              case .closed(let code, let reason) = museError
        else {
            return XCTFail("Expected .closed error")
        }
        XCTAssertEqual(code, URLSessionWebSocketTask.CloseCode.internalServerError.rawValue)
        XCTAssertEqual(reason, "first")

        let afterConsume = await tracker.consumeCloseError()
        XCTAssertNil(afterConsume)
    }

    func testEvents_createsAsyncStream() async {
        let client = MetaMuseASRClient()
        let events = await client.events
        XCTAssertNotNil(events)
    }
}
