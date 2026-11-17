import XCTest
@testable import Search

@MainActor
final class AIRepositorySourcesTests: XCTestCase {
    func testSelectionAcceptsOnlyOneExplicitGitHubRepository() throws {
        XCTAssertEqual(try AIRepositorySources.Repository("https://github.com/owner/repo.git").label, "owner/repo")
        for value in ["https://other.invalid/owner/repo", "https://github.com@other.invalid/owner/repo", "../repo", "owner/../repo", "owner/repo?token=secret", "owner/repo/extra"] {
            XCTAssertThrowsError(try AIRepositorySources.Repository(value))
        }
    }
    func testRequestAuthorityAndQueryCannotBeChangedByFileOrRef() throws {
        let repo = try AIRepositorySources.Repository("owner/repo")
        let url = try AIRepositorySources.url(repository: repo, arguments: ["section": "file", "path": "Sources/file.swift", "ref": "branch&token=not-a-query"])
        let parts = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(parts.host, "api.github.com")
        XCTAssertEqual(parts.scheme, "https")
        XCTAssertEqual(parts.queryItems, [URLQueryItem(name: "ref", value: "branch&token=not-a-query")])
        XCTAssertEqual(parts.path, "/repos/owner/repo/contents/Sources/file.swift")
        for path in ["../secret", "/etc/passwd", "folder/../../secret", "folder\\secret", "https://other.invalid/path"] {
            XCTAssertThrowsError(try AIRepositorySources.url(repository: repo, arguments: ["section": "file", "path": path]))
        }
    }
    func testRepositoryListingsHaveBoundedExplicitPages() throws {
        let repo = try AIRepositorySources.Repository("owner/repo")
        let url = try AIRepositorySources.url(repository: repo, arguments: ["section": "issues", "page": 2])
        XCTAssertTrue(url.absoluteString.contains("per_page=20"))
        XCTAssertTrue(url.absoluteString.contains("page=2"))
        XCTAssertThrowsError(try AIRepositorySources.url(repository: repo, arguments: ["section": "issues", "page": 21]))
        XCTAssertThrowsError(try AIRepositorySources.url(repository: repo, arguments: ["section": "arbitrary_endpoint"]))
    }
}
