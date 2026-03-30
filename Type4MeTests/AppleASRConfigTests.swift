import XCTest
@testable import Type4Me

final class AppleASRConfigTests: XCTestCase {

    func testInit_acceptsEmptyCredentials() throws {
        let config = try XCTUnwrap(AppleASRConfig(credentials: [:]))

        XCTAssertTrue(config.isValid)
        XCTAssertEqual(config.localeIdentifier, AppleASRConfig.defaultLocaleIdentifier)
    }

    func testInit_usesExplicitLocaleIdentifier() throws {
        let config = try XCTUnwrap(AppleASRConfig(credentials: [
            "localeIdentifier": "ja-JP"
        ]))

        XCTAssertEqual(config.localeIdentifier, "ja-JP")
    }

    func testToCredentials_returnsLocaleIdentifier() throws {
        let config = try XCTUnwrap(AppleASRConfig(credentials: [
            "localeIdentifier": "en-US"
        ]))

        XCTAssertEqual(config.toCredentials(), ["localeIdentifier": "en-US"])
    }

    func testCredentialFields_exposeLocalePicker() {
        let fields = AppleASRConfig.credentialFields

        XCTAssertEqual(fields.count, 1)
        XCTAssertEqual(fields.first?.key, "localeIdentifier")
        XCTAssertEqual(fields.first?.defaultValue, AppleASRConfig.defaultLocaleIdentifier)
        XCTAssertEqual(fields.first?.options.map(\.value), ["zh-CN", "en-US", "ja-JP", "ko-KR"])
    }

    func testAppleClientLocale_usesConfigLocaleIdentifier() throws {
        let config = try XCTUnwrap(AppleASRConfig(credentials: [
            "localeIdentifier": "ko-KR"
        ]))

        XCTAssertEqual(
            AppleASRClient.preferredLocale(for: config).identifier,
            "ko-KR"
        )
    }

    func testRegistryRegistersAppleProvider() {
        let entry = ASRProviderRegistry.entry(for: .apple)

        XCTAssertNotNil(entry)
        XCTAssertTrue(ASRProviderRegistry.configType(for: .apple) == AppleASRConfig.self)
        XCTAssertNotNil(ASRProviderRegistry.createClient(for: .apple))
    }

    func testAppleProviderIsNotTreatedAsSherpaLocalProvider() {
        XCTAssertFalse(ASRProvider.apple.isLocal)
    }

    func testAppleProviderUsesPCMBufferInput() {
        XCTAssertEqual(ASRProviderRegistry.capabilities(for: .apple).audioInput, .pcmBuffer)
    }
}
