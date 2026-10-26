import XCTest
@testable import Type4Me

final class GitHubIssueReporterTests: XCTestCase {
    func testDeviceAuthorizationRequestsPublicRepositoryScope() {
        let fields = GitHubIssueReporter.deviceAuthorizationFields()

        XCTAssertFalse(fields["client_id", default: ""].isEmpty)
        XCTAssertEqual(fields["scope"], "public_repo")
    }

    func testIssueWriteScopeAcceptsPublicRepoOrRepo() {
        XCTAssertTrue(GitHubIssueReporter.hasIssueWriteScope(["public_repo"]))
        XCTAssertTrue(GitHubIssueReporter.hasIssueWriteScope(["read:user", "repo"]))
        XCTAssertFalse(GitHubIssueReporter.hasIssueWriteScope([]))
        XCTAssertFalse(GitHubIssueReporter.hasIssueWriteScope(["read:user"]))
    }

    func testScopeParsingSupportsGitHubCommaSeparatedResponse() {
        XCTAssertEqual(
            GitHubIssueReporter.parseScopes("read:user,public_repo gist"),
            ["read:user", "public_repo", "gist"]
        )
    }
}
