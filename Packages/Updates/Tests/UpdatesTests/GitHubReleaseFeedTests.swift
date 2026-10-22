//
//  GitHubReleaseFeedTests.swift
//  UpdatesTests
//
//  Decoding GitHub's release object, the request a check sends, and — because
//  a public repo's install command is quoted in three places — that the
//  README, the script and the app all say the same one.
//

import Foundation
import Testing

@testable import Updates

/// GitHub's `/releases/latest` answer for v0.0.12, trimmed to the fields that
/// matter plus a few it also sends, so the decoder is proven tolerant of them.
let latestReleaseFixture = Data(
    """
    {
      "url": "https://api.github.com/repos/sancrisoft/echo/releases/123",
      "html_url": "https://github.com/sancrisoft/echo/releases/tag/v0.0.12",
      "id": 123,
      "tag_name": "v0.0.12",
      "target_commitish": "main",
      "name": "Echo 0.0.12",
      "draft": false,
      "prerelease": false,
      "created_at": "2026-09-01T17:02:50Z",
      "published_at": "2026-09-01T17:03:05Z",
      "assets": [
        {
          "name": "Echo-0.0.12.zip",
          "size": 13989240,
          "digest": "sha256:5206886dc626b50bbebfe65a9d8df978f588ac085c57e0faa9961787435382a8",
          "browser_download_url": "https://github.com/sancrisoft/echo/releases/download/v0.0.12/Echo-0.0.12.zip"
        }
      ],
      "body": "Install or update with: ..."
    }
    """.utf8
)

@Suite("GitHub release feed")
struct GitHubReleaseFeedTests {

    @Test func decodesTheLatestReleaseObject() throws {
        let latest = try GitHubReleaseFeed.decodeLatest(latestReleaseFixture)
        #expect(latest.tag == "v0.0.12")
        #expect(latest.version == ReleaseVersion("0.0.12"))
        #expect(latest.title == "Echo 0.0.12")
        #expect(latest.pageURL.absoluteString == "https://github.com/sancrisoft/echo/releases/tag/v0.0.12")

        let published = try #require(latest.publishedAt)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: published)
        #expect(parts.year == 2026 && parts.month == 9 && parts.day == 1)
        #expect(parts.hour == 17 && parts.minute == 3 && parts.second == 5)
    }

    @Test func aMissingPublishedDateIsNotAnError() throws {
        let json = Data(
            #"{"tag_name":"v0.0.12","html_url":"https://github.com/sancrisoft/echo/releases/tag/v0.0.12","published_at":null}"#
                .utf8
        )
        let latest = try GitHubReleaseFeed.decodeLatest(json)
        #expect(latest.publishedAt == nil)
        #expect(latest.title == nil)
    }

    @Test func garbageIsMalformed() {
        #expect(throws: UpdateCheckFailure.self) {
            try GitHubReleaseFeed.decodeLatest(Data("<html>rate limited</html>".utf8))
        }
        do {
            _ = try GitHubReleaseFeed.decodeLatest(Data("{}".utf8))
            Issue.record("an empty object has no tag and must not decode")
        } catch let error as UpdateCheckFailure {
            guard case .malformed = error else {
                Issue.record("expected .malformed, got \(error)")
                return
            }
        } catch {
            Issue.record("expected UpdateCheckFailure, got \(error)")
        }
    }

    @Test func aTagThatIsNotAVersionIsReportedAsSuch() {
        let json = Data(
            #"{"tag_name":"nightly","html_url":"https://github.com/sancrisoft/echo/releases/tag/nightly"}"#.utf8
        )
        do {
            _ = try GitHubReleaseFeed.decodeLatest(json)
            Issue.record("should not decode")
        } catch let error as UpdateCheckFailure {
            #expect(error == .unrecognizedTag("nightly"))
            #expect(error.message.contains("nightly"))
        } catch {
            Issue.record("expected UpdateCheckFailure, got \(error)")
        }
    }

    @Test func theRequestIdentifiesEchoAndAsksForJSON() {
        let request = GitHubReleaseFeed.latestReleaseRequest(appVersion: "0.0.12")
        #expect(request.url == GitHubReleaseFeed.latestReleaseAPIURL)
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
        #expect(request.value(forHTTPHeaderField: "User-Agent")?.contains("Echo/0.0.12") == true)
        #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
    }

    @Test func everyURLDerivesFromTheOneRepository() {
        #expect(GitHubReleaseFeed.repository == "sancrisoft/echo")
        #expect(GitHubReleaseFeed.releasesPageURL.absoluteString == "https://github.com/sancrisoft/echo/releases")
        #expect(
            GitHubReleaseFeed.latestReleaseAPIURL.absoluteString
                == "https://api.github.com/repos/sancrisoft/echo/releases/latest"
        )
        #expect(
            GitHubReleaseFeed.installScriptURL.absoluteString
                == "https://raw.githubusercontent.com/sancrisoft/echo/main/scripts/install.sh"
        )
        #expect(
            GitHubReleaseFeed.installCommand
                == "curl -fsSL https://raw.githubusercontent.com/sancrisoft/echo/main/scripts/install.sh | bash"
        )
    }

    /// The install command is quoted in the README, defaulted in the script
    /// and typed by the app's Update button. One repository constant feeds
    /// them all — this is what keeps a rename or a fork from leaving one
    /// behind.
    @Test func theREADMEAndTheScriptQuoteTheSameInstallCommand() throws {
        let root = URL(filePath: #filePath)
            .deletingLastPathComponent()  // Tests/UpdatesTests/
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // Packages/Updates/
            .deletingLastPathComponent()  // Packages/
            .deletingLastPathComponent()  // repository root
        let readme = try String(contentsOf: root.appending(path: "README.md"), encoding: .utf8)
        let script = try String(contentsOf: root.appending(path: "scripts/install.sh"), encoding: .utf8)
        let workflow = try String(
            contentsOf: root.appending(path: ".github/workflows/release.yml"), encoding: .utf8)

        #expect(readme.contains("```sh\n\(GitHubReleaseFeed.installCommand)\n```"))
        #expect(script.contains(GitHubReleaseFeed.installCommand))
        #expect(script.contains("REPO=\"${ECHO_INSTALL_REPO:-\(GitHubReleaseFeed.repository)}\""))
        // The workflow templates the repository in, so check the shape around it.
        #expect(
            workflow.contains(
                "curl -fsSL https://raw.githubusercontent.com/${GITHUB_REPOSITORY}/"
                    + "\(GitHubReleaseFeed.defaultBranch)/scripts/install.sh | bash"
            )
        )
        #expect(!workflow.contains("gh api"), "the release notes must not send a public user to the GitHub CLI")
    }
}
