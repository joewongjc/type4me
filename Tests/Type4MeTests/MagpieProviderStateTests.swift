import XCTest
@testable import Type4Me

final class MagpieProviderStateTests: XCTestCase {

    private let dummyManagedFile = MagpieAgentFile(
        model: "deepseek/deepseek-chat",
        baseURL: URL(string: "http://127.0.0.1:3425/v1")!,
        apiKey: "test-key"
    )

    func testDeriveManagedOnline() {
        let conn = MagpieResolvedConnection(
            mode: .managed,
            model: "m",
            baseURL: URL(string: "http://127.0.0.1:3425/v1")!,
            apiKey: "k",
            agentFileIssue: nil
        )
        let state = MagpieProviderState.derive(
            connection: conn,
            gateway: .online(version: "0.1.1246"),
            installation: .installed
        )
        XCTAssertEqual(state, .managedOnline(version: "0.1.1246"))
    }

    func testDeriveManagedOffline() {
        let conn = MagpieResolvedConnection(
            mode: .managed,
            model: "m",
            baseURL: URL(string: "http://127.0.0.1:3425/v1")!,
            apiKey: "k",
            agentFileIssue: nil
        )
        let stateOffline = MagpieProviderState.derive(
            connection: conn,
            gateway: .offline,
            installation: .installed
        )
        XCTAssertEqual(stateOffline, .managedOffline)

        let stateUnknown = MagpieProviderState.derive(
            connection: conn,
            gateway: .unknown,
            installation: .installed
        )
        XCTAssertEqual(stateUnknown, .managedOffline)
    }

    func testDeriveDirectOnline() {
        let conn = MagpieResolvedConnection(
            mode: .direct,
            model: "m",
            baseURL: URL(string: "http://127.0.0.1:3425/v1")!,
            apiKey: "k",
            agentFileIssue: nil
        )
        let state = MagpieProviderState.derive(
            connection: conn,
            gateway: .online(version: "0.1.1246"),
            installation: .installed
        )
        XCTAssertEqual(state, .directOnline(version: "0.1.1246"))
    }

    func testDeriveInstalledNotRunning() {
        let conn = MagpieResolvedConnection(
            mode: .direct,
            model: "m",
            baseURL: URL(string: "http://127.0.0.1:3425/v1")!,
            apiKey: "k",
            agentFileIssue: nil
        )
        let state = MagpieProviderState.derive(
            connection: conn,
            gateway: .offline,
            installation: .installed
        )
        XCTAssertEqual(state, .installedNotRunning)
    }

    func testDeriveNotInstalled() {
        let conn = MagpieResolvedConnection(
            mode: .direct,
            model: "m",
            baseURL: URL(string: "http://127.0.0.1:3425/v1")!,
            apiKey: "k",
            agentFileIssue: nil
        )
        let state = MagpieProviderState.derive(
            connection: conn,
            gateway: .offline,
            installation: .notInstalled
        )
        XCTAssertEqual(state, .notInstalled)
    }
}
