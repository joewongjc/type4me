import XCTest
@testable import Type4Me

final class MagpieAgentFileTests: XCTestCase {

    func testParseCompleteFile() {
        let json = """
        {
            "model": "deepseek/deepseek-chat",
            "baseURL": "http://127.0.0.1:3425/v1/",
            "apiKey": "test-key-123"
        }
        """.data(using: .utf8)!

        let result = MagpieAgentFile.parse(json)
        guard case .managed(let file) = result else {
            XCTFail("Expected .managed, got \(result)")
            return
        }

        XCTAssertEqual(file.model, "deepseek/deepseek-chat")
        XCTAssertEqual(file.baseURL, URL(string: "http://127.0.0.1:3425/v1"))
        XCTAssertEqual(file.apiKey, "test-key-123")
    }

    func testParseEmptyDictionaryIsAbsent() {
        let json = "{}".data(using: .utf8)!
        let result = MagpieAgentFile.parse(json)
        XCTAssertEqual(result, .absent)
    }

    func testParseMissingOneKeyIsIncomplete() {
        let json = """
        {
            "model": "deepseek/deepseek-chat",
            "baseURL": "http://127.0.0.1:3425/v1"
        }
        """.data(using: .utf8)!
        let result = MagpieAgentFile.parse(json)
        XCTAssertEqual(result, .incomplete)
    }

    func testParseEmptyStringKeyIsIncomplete() {
        let json = """
        {
            "model": "deepseek/deepseek-chat",
            "baseURL": "   ",
            "apiKey": "test-key"
        }
        """.data(using: .utf8)!
        let result = MagpieAgentFile.parse(json)
        XCTAssertEqual(result, .incomplete)
    }

    func testParseInvalidJSONIsUnreadable() {
        let data = "not-json".data(using: .utf8)!
        XCTAssertEqual(MagpieAgentFile.parse(data), .unreadable)

        let arrayData = "[]".data(using: .utf8)!
        XCTAssertEqual(MagpieAgentFile.parse(arrayData), .unreadable)
    }

    func testParseNonLoopbackReturnsNonLoopback() {
        let json = """
        {
            "model": "deepseek/deepseek-chat",
            "baseURL": "https://api.openai.com/v1",
            "apiKey": "key"
        }
        """.data(using: .utf8)!
        let result = MagpieAgentFile.parse(json)
        XCTAssertEqual(result, .nonLoopback("https://api.openai.com/v1"))
    }

    func testParseLocalhostAndIPv6Loopback() {
        let jsonLocalhost = """
        {
            "model": "model-a",
            "baseURL": "http://localhost:3425",
            "apiKey": "key-a"
        }
        """.data(using: .utf8)!
        if case .managed(let file) = MagpieAgentFile.parse(jsonLocalhost) {
            XCTAssertEqual(file.baseURL, URL(string: "http://localhost:3425"))
        } else {
            XCTFail("localhost should be valid loopback")
        }

        let jsonIPv6 = """
        {
            "model": "model-b",
            "baseURL": "http://[::1]:3425",
            "apiKey": "key-b"
        }
        """.data(using: .utf8)!
        if case .managed(let file) = MagpieAgentFile.parse(jsonIPv6) {
            XCTAssertEqual(file.model, "model-b")
        } else {
            XCTFail("[::1] should be valid loopback")
        }
    }

    func testUnknownKeysAreIgnored() {
        let json = """
        {
            "model": "deepseek/deepseek-chat",
            "baseURL": "http://127.0.0.1:3425/v1",
            "apiKey": "test-key-123",
            "futureField": "some-value",
            "extra": 123
        }
        """.data(using: .utf8)!

        guard case .managed(let file) = MagpieAgentFile.parse(json) else {
            XCTFail("Expected .managed")
            return
        }
        XCTAssertEqual(file.model, "deepseek/deepseek-chat")
    }

    func testLoadFromNonExistentFile() {
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("non-existent-\(UUID().uuidString).json")
        XCTAssertEqual(MagpieAgentFile.load(from: tempURL), .absent)
    }
}
