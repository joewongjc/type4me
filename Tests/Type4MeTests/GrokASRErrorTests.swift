import XCTest
@testable import Type4Me

final class GrokASRErrorTests: XCTestCase {

    func testHTTPRejected401DescribesInvalidAPIKey() {
        let error = GrokASRError.httpRejected(statusCode: 401)
        XCTAssertTrue(error.errorDescription?.contains("401") == true)
        XCTAssertTrue(error.errorDescription?.localizedCaseInsensitiveContains("API") == true)
    }

    func testHTTPRejected403DescribesUnauthorized() {
        let error = GrokASRError.httpRejected(statusCode: 403)
        XCTAssertTrue(error.errorDescription?.contains("403") == true)
    }
}
