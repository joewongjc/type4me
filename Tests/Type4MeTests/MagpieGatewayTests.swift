import XCTest
@testable import Type4Me

final class MagpieGatewayTests: XCTestCase {

    func testDirectBaseURLWithoutSettings() {
        let url = MagpieGateway.directBaseURL(settingsData: nil)
        XCTAssertEqual(url.absoluteString, "http://127.0.0.1:3425")
    }

    func testDirectBaseURLWithPortNumber() {
        let json = #"{"port": 4000}"#.data(using: .utf8)
        let url = MagpieGateway.directBaseURL(settingsData: json)
        XCTAssertEqual(url.absoluteString, "http://127.0.0.1:4000")
    }

    func testDirectBaseURLWithPortString() {
        let json = #"{"port": "5000"}"#.data(using: .utf8)
        let url = MagpieGateway.directBaseURL(settingsData: json)
        XCTAssertEqual(url.absoluteString, "http://127.0.0.1:5000")
    }

    func testDirectBaseURLWithInvalidPortFallsBack() {
        let json = #"{"port": 999999}"#.data(using: .utf8)
        let url = MagpieGateway.directBaseURL(settingsData: json)
        XCTAssertEqual(url.absoluteString, "http://127.0.0.1:3425")
    }

    func testLoopbackChecks() {
        XCTAssertTrue(MagpieGateway.isLoopback(URL(string: "http://127.0.0.1:3425")!))
        XCTAssertTrue(MagpieGateway.isLoopback(URL(string: "http://localhost:3425/v1")!))
        XCTAssertTrue(MagpieGateway.isLoopback(URL(string: "http://[::1]:3425")!))
        XCTAssertTrue(MagpieGateway.isLoopback(URL(string: "http://127.0.1.1:8080")!))
        XCTAssertTrue(MagpieGateway.isLoopback(URL(string: "http://127.255.255.254:3425")!))

        // External domain masquerading / bypass attempts
        XCTAssertFalse(MagpieGateway.isLoopback(URL(string: "http://127.example.com/v1")!))
        XCTAssertFalse(MagpieGateway.isLoopback(URL(string: "http://127.0.0.1.nip.io/v1")!))
        XCTAssertFalse(MagpieGateway.isLoopback(URL(string: "http://127foo.bar/v1")!))
        XCTAssertFalse(MagpieGateway.isLoopback(URL(string: "http://128.0.0.1/v1")!))
        XCTAssertFalse(MagpieGateway.isLoopback(URL(string: "https://example.com")!))
        XCTAssertFalse(MagpieGateway.isLoopback(URL(string: "http://192.168.1.1:3425")!))
        XCTAssertFalse(MagpieGateway.isLoopback(URL(string: "ftp://127.0.0.1:3425")!))
    }
    func testDirectIdentity() {
        XCTAssertEqual(
            MagpieGateway.directIdentity(bundleID: AppDataLocation.productionBundleID),
            "magpie-type4me"
        )
        XCTAssertEqual(
            MagpieGateway.directIdentity(bundleID: AppDataLocation.devBundleID),
            "magpie-type4me-dev"
        )
    }
}
