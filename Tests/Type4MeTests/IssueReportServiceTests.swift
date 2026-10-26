import XCTest
@testable import Type4Me

final class IssueReportServiceTests: XCTestCase {
    private let environment = IssueReportEnvironment(
        appVersion: "1.2.3",
        buildNumber: "123",
        macOSVersion: "macOS 15.5",
        architecture: "arm64",
        variant: "pure",
        asrProvider: "soniox",
        llmProvider: "openai"
    )

    func testSanitizedLogRemovesSecretsAndUserContent() {
        let raw = """
        Authorization: Bearer abc.def.secret
        apiKey=sk-private-value
        request=https://example.com/run?access_token=token-value&mode=fast
        injection detect: value=private dictated text
        macAction: dispatching send_message args={"text":"private message"}
        owner@example.com
        /Users/jonathan/Documents/private.txt
        """

        let result = IssueReportService.sanitizedLog(raw)

        XCTAssertFalse(result.contains("abc.def.secret"))
        XCTAssertFalse(result.contains("sk-private-value"))
        XCTAssertFalse(result.contains("token-value"))
        XCTAssertFalse(result.contains("private dictated text"))
        XCTAssertFalse(result.contains("private message"))
        XCTAssertFalse(result.contains("owner@example.com"))
        XCTAssertFalse(result.contains("/Users/jonathan"))
        XCTAssertTrue(result.contains("<redacted>"))
        XCTAssertTrue(result.contains("<redacted-email>"))
        XCTAssertTrue(result.contains("~/Documents/private.txt"))
    }

    func testFullReportIncludesDescriptionEnvironmentAndRedactedLog() {
        let report = IssueReportService.fullReport(
            description: "Recording stops unexpectedly",
            environment: environment,
            includeLogs: true,
            logText: "token=do-not-publish\naudio capture stopped"
        )

        XCTAssertTrue(report.contains("Recording stops unexpectedly"))
        XCTAssertTrue(report.contains("Type4Me: 1.2.3 (123)"))
        XCTAssertTrue(report.contains("ASR: soniox"))
        XCTAssertTrue(report.contains("audio capture stopped"))
        XCTAssertFalse(report.contains("do-not-publish"))
    }

    func testFullReportCanExcludeLogs() {
        let report = IssueReportService.fullReport(
            description: "A problem",
            environment: environment,
            includeLogs: false,
            logText: "sensitive log"
        )

        XCTAssertFalse(report.contains("Diagnostic log"))
        XCTAssertFalse(report.contains("sensitive log"))
    }

    func testGitHubURLIsBoundedAndContainsPrefilledFields() throws {
        let title = "Bluetooth recording problem"
        let description = String(repeating: "很长的问题描述", count: 2_000)
        let log = String(repeating: "audio callback token=secret-value\n", count: 2_000)

        let url = try XCTUnwrap(IssueReportService.githubIssueURL(
            title: title,
            description: description,
            environment: environment,
            includeLogs: true,
            logText: log
        ))
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let queryItems = try XCTUnwrap(components.queryItems)

        XCTAssertLessThanOrEqual(url.absoluteString.count, IssueReportService.maximumBrowserURLCharacters)
        XCTAssertEqual(queryItems.first(where: { $0.name == "title" })?.value, title)
        let body = try XCTUnwrap(queryItems.first(where: { $0.name == "body" })?.value)
        XCTAssertTrue(body.contains("Type4Me: 1.2.3 (123)"))
        XCTAssertFalse(body.contains("secret-value"))
    }

    func testSuggestedTitleUsesFirstDescriptionLine() {
        let title = IssueReportService.suggestedTitle(
            customTitle: "",
            description: "First line\nMore detail"
        )

        XCTAssertEqual(title, "[Bug] First line")
    }
}
