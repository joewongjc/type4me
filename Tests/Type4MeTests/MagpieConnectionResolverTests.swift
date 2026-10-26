import XCTest
@testable import Type4Me

final class MagpieConnectionResolverTests: XCTestCase {

    func testManagedTakesPrecedenceOverDirect() {
        let managedFile = MagpieAgentFile(
            model: "managed/model-1",
            baseURL: URL(string: "http://127.0.0.1:3425/v1")!,
            apiKey: "managed-key"
        )
        let resolved = MagpieConnectionResolver.resolve(
            agentFile: .managed(managedFile),
            storedDirectModel: "direct/model-2",
            directBaseURL: URL(string: "http://127.0.0.1:3425")!,
            directIdentity: "magpie-type4me"
        )

        XCTAssertEqual(resolved.mode, .managed)
        XCTAssertEqual(resolved.model, "managed/model-1")
        XCTAssertEqual(resolved.baseURL, URL(string: "http://127.0.0.1:3425/v1")!)
        XCTAssertEqual(resolved.apiKey, "managed-key")
        XCTAssertNil(resolved.agentFileIssue)
    }

    func testDirectModeUsesStoredModel() {
        let resolved = MagpieConnectionResolver.resolve(
            agentFile: .absent,
            storedDirectModel: "direct/model-2",
            directBaseURL: URL(string: "http://127.0.0.1:3425")!,
            directIdentity: "magpie-type4me"
        )

        XCTAssertEqual(resolved.mode, .direct)
        XCTAssertEqual(resolved.model, "direct/model-2")
        XCTAssertEqual(resolved.baseURL, URL(string: "http://127.0.0.1:3425/v1")!)
        XCTAssertEqual(resolved.apiKey, "magpie-type4me")
        XCTAssertNil(resolved.agentFileIssue)
    }

    func testInvalidAgentFileFallsBackToDirectWithIssue() {
        let resolved = MagpieConnectionResolver.resolve(
            agentFile: .unreadable,
            storedDirectModel: "direct/model-2",
            directBaseURL: URL(string: "http://127.0.0.1:3425")!,
            directIdentity: "magpie-type4me"
        )

        XCTAssertEqual(resolved.mode, .direct)
        XCTAssertEqual(resolved.model, "direct/model-2")
        XCTAssertEqual(resolved.agentFileIssue, .unreadable)
    }
}
