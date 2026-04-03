import XCTest
@testable import Type4Me

final class KeychainServiceTests: XCTestCase {

    private var originalProvider: ASRProvider!
    private let appSupportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        .appendingPathComponent("Type4Me", isDirectory: true)
    private var credentialsURL: URL {
        appSupportDir.appendingPathComponent("credentials.json")
    }

    override func setUp() {
        super.setUp()
        originalProvider = KeychainService.selectedASRProvider
    }

    override func tearDown() {
        KeychainService.delete(key: "test_key")
        try? KeychainService.saveASRCredentials(for: .volcano, values: [:])
        KeychainService.selectedASRProvider = originalProvider
        super.tearDown()
    }

    func testSaveAndLoad() throws {
        try KeychainService.save(key: "test_key", value: "secret123")
        let loaded = KeychainService.load(key: "test_key")
        XCTAssertEqual(loaded, "secret123")
    }

    func testOverwrite() throws {
        try KeychainService.save(key: "test_key", value: "old")
        try KeychainService.save(key: "test_key", value: "new")
        XCTAssertEqual(KeychainService.load(key: "test_key"), "new")
    }

    func testLoadMissing() {
        let result = KeychainService.load(key: "nonexistent_key_xyz")
        XCTAssertNil(result)
    }

    func testDelete() throws {
        try KeychainService.save(key: "test_key", value: "value")
        KeychainService.delete(key: "test_key")
        XCTAssertNil(KeychainService.load(key: "test_key"))
    }

    func testLoadCredentials_fromKeychain() throws {
        let original = KeychainService.loadASRCredentials(for: .volcano)
        defer {
            if let original {
                try? KeychainService.saveASRCredentials(for: .volcano, values: original)
            } else {
                try? KeychainService.saveASRCredentials(for: .volcano, values: [:])
            }
        }

        try KeychainService.saveASRCredentials(for: .volcano, values: [
            "appKey": "myAppKey",
            "accessKey": "myAccessKey",
            "resourceId": "myResource",
        ])

        let config = KeychainService.loadASRConfig()
        XCTAssertNotNil(config)
        XCTAssertEqual(config?.appKey, "myAppKey")
        XCTAssertEqual(config?.accessKey, "myAccessKey")
        XCTAssertEqual(config?.resourceId, "myResource")
    }

    func testSaveASRCredentials_storesSecureFieldsOutsideCredentialsFile() throws {
        try KeychainService.saveASRCredentials(for: .volcano, values: [
            "appKey": "myAppKey",
            "accessKey": "myAccessKey",
            "resourceId": "myResource",
        ])

        let fileData = try Data(contentsOf: credentialsURL)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: fileData) as? [String: Any])
        let stored = try XCTUnwrap(json["tf_asr_volcano"] as? [String: String])

        XCTAssertEqual(stored["appKey"], "myAppKey")
        XCTAssertEqual(stored["resourceId"], "myResource")
        XCTAssertNil(stored["accessKey"])
        XCTAssertEqual(KeychainService.loadASRCredentials(for: .volcano)?["accessKey"], "myAccessKey")
    }

    func testSelectedASRProviderPostsNotificationOnChange() {
        let targetProvider: ASRProvider = originalProvider == .bailian ? .volcano : .bailian
        let expectation = expectation(description: "provider change notification")
        let token = NotificationCenter.default.addObserver(
            forName: .asrProviderDidChange,
            object: nil,
            queue: .main
        ) { note in
            XCTAssertEqual(note.object as? ASRProvider, targetProvider)
            expectation.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(token) }

        KeychainService.selectedASRProvider = targetProvider

        wait(for: [expectation], timeout: 1.0)
    }
}
