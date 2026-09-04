//
//  AppUpdatesTests.swift
//  EchoTests
//
//  The GitHub-releases update check: the version arithmetic behind the tags,
//  decoding GitHub's release object, the comparison, the checker's error
//  mapping, and — because a public repo's install command is quoted in three
//  places — that the README, the script and the app all say the same one.
//

import Foundation
import Testing
@testable import Echo

// MARK: - Versions

@Suite("Release versions")
struct ReleaseVersionTests {

    @Test(arguments: [
        ("v0.0.12", [0, 0, 12], nil),
        ("0.0.12", [0, 0, 12], nil),
        ("V1.2", [1, 2], nil),
        ("v0.1.0-rc.1", [0, 1, 0], "rc.1"),
        (" v0.0.12\n", [0, 0, 12], nil),
        ("v0.0.10-hotfix.1", [0, 0, 10], "hotfix.1"),
    ] as [(String, [Int], String?)])
    func parsesTagsAndBareNumbers(input: (String, [Int], String?)) throws {
        let version = try #require(ReleaseVersion(input.0))
        #expect(version.components == input.1)
        #expect(version.preRelease == input.2)
    }

    @Test(arguments: ["", "latest", "1.0.x", "v", "-rc", "1..2", "v1.", "+1.0", "1.0-"])
    func rejectsAnythingThatIsNotAVersion(text: String) {
        #expect(ReleaseVersion(text) == nil)
    }

    @Test func printsTheTagAndTheBareFormBack() throws {
        let version = try #require(ReleaseVersion("v0.0.12"))
        #expect(version.description == "0.0.12")
        #expect(version.tag == "v0.0.12")

        let candidate = try #require(ReleaseVersion("0.1.0-rc.1"))
        #expect(candidate.tag == "v0.1.0-rc.1")
    }

    @Test func ordersNumericallyNotLexically() throws {
        let chain = try ["0.0.9", "0.0.10", "0.0.12", "0.1.0", "1.0"].map { try #require(ReleaseVersion($0)) }
        for (lower, higher) in zip(chain, chain.dropFirst()) {
            #expect(lower < higher, "\(lower) should sort before \(higher)")
        }
    }

    @Test func trailingZerosDoNotMakeADifferentVersion() throws {
        let short = try #require(ReleaseVersion("1.0"))
        let long = try #require(ReleaseVersion("1.0.0"))
        #expect(short == long)
        #expect(short.hashValue == long.hashValue)
        #expect(!(short < long) && !(long < short))
    }

    @Test func preReleasesSortBeforeTheirRelease() throws {
        let rc = try #require(ReleaseVersion("0.1.0-rc.1"))
        let beta = try #require(ReleaseVersion("0.1.0-beta"))
        let release = try #require(ReleaseVersion("0.1.0"))
        let previous = try #require(ReleaseVersion("0.0.12"))
        #expect(rc < release)
        #expect(beta < rc)
        #expect(previous < beta)
    }
}

// MARK: - The feed

/// GitHub's `/releases/latest` answer for v0.0.12, trimmed to the fields that
/// matter plus a few it also sends, so the decoder is proven tolerant of them.
private let latestReleaseFixture = Data("""
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
""".utf8)

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
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: published)
        #expect(parts.year == 2026 && parts.month == 9 && parts.day == 1)
        #expect(parts.hour == 17 && parts.minute == 3 && parts.second == 5)
    }

    @Test func aMissingPublishedDateIsNotAnError() throws {
        let json = Data(#"{"tag_name":"v0.0.12","html_url":"https://github.com/sancrisoft/echo/releases/tag/v0.0.12","published_at":null}"#.utf8)
        let latest = try GitHubReleaseFeed.decodeLatest(json)
        #expect(latest.publishedAt == nil)
        #expect(latest.title == nil)
    }

    @Test func garbageIsMalformed() {
        #expect(throws: UpdateCheckError.self) {
            try GitHubReleaseFeed.decodeLatest(Data("<html>rate limited</html>".utf8))
        }
        do {
            _ = try GitHubReleaseFeed.decodeLatest(Data("{}".utf8))
            Issue.record("an empty object has no tag and must not decode")
        } catch let error as UpdateCheckError {
            guard case .malformed = error else {
                Issue.record("expected .malformed, got \(error)")
                return
            }
        } catch {
            Issue.record("expected UpdateCheckError, got \(error)")
        }
    }

    @Test func aTagThatIsNotAVersionIsReportedAsSuch() {
        let json = Data(#"{"tag_name":"nightly","html_url":"https://github.com/sancrisoft/echo/releases/tag/nightly"}"#.utf8)
        do {
            _ = try GitHubReleaseFeed.decodeLatest(json)
            Issue.record("should not decode")
        } catch let error as UpdateCheckError {
            #expect(error == .unrecognizedTag("nightly"))
            #expect(error.message.contains("nightly"))
        } catch {
            Issue.record("expected UpdateCheckError, got \(error)")
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
        #expect(GitHubReleaseFeed.latestReleaseAPIURL.absoluteString == "https://api.github.com/repos/sancrisoft/echo/releases/latest")
        #expect(GitHubReleaseFeed.installScriptURL.absoluteString == "https://raw.githubusercontent.com/sancrisoft/echo/main/scripts/install.sh")
        #expect(GitHubReleaseFeed.installCommand == "curl -fsSL https://raw.githubusercontent.com/sancrisoft/echo/main/scripts/install.sh | bash")
    }

    /// The install command is quoted in the README, defaulted in the script
    /// and typed by the app's Update button. One repository constant feeds
    /// them all — this is what keeps a rename or a fork from leaving one
    /// behind.
    @Test func theREADMEAndTheScriptQuoteTheSameInstallCommand() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // EchoTests/
            .deletingLastPathComponent()   // repository root
        let readme = try String(contentsOf: root.appending(path: "README.md"), encoding: .utf8)
        let script = try String(contentsOf: root.appending(path: "scripts/install.sh"), encoding: .utf8)
        let workflow = try String(contentsOf: root.appending(path: ".github/workflows/release.yml"), encoding: .utf8)

        #expect(readme.contains("```sh\n\(GitHubReleaseFeed.installCommand)\n```"))
        #expect(script.contains(GitHubReleaseFeed.installCommand))
        #expect(script.contains("REPO=\"${ECHO_INSTALL_REPO:-\(GitHubReleaseFeed.repository)}\""))
        // The workflow templates the repository in, so check the shape around it.
        #expect(workflow.contains("curl -fsSL https://raw.githubusercontent.com/${GITHUB_REPOSITORY}/\(GitHubReleaseFeed.defaultBranch)/scripts/install.sh | bash"))
        #expect(!workflow.contains("gh api"), "the release notes must not send a public user to the GitHub CLI")
    }

    @Test func theTerminalCommandFileRunsTheInstallCommand() {
        let contents = UpdateActions.installerCommandFileContents(appVersion: "v0.0.12 (87)")
        #expect(contents.hasPrefix("#!/bin/bash\n"))
        #expect(contents.contains("\n\(GitHubReleaseFeed.installCommand)\n"))
        #expect(contents.contains("v0.0.12 (87)"))
    }
}

// MARK: - The checker

/// Counts calls from any thread; the transport closure is `@Sendable`.
nonisolated private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

@Suite("Update checker")
@MainActor
struct UpdateCheckerTests {

    private func response(_ status: Int) -> URLResponse {
        HTTPURLResponse(
            url: GitHubReleaseFeed.latestReleaseAPIURL,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
    }

    private func checker(
        installed: String?,
        transport: @escaping UpdateChecker.Transport
    ) -> UpdateChecker {
        UpdateChecker(installedVersion: installed.flatMap(ReleaseVersion.init), transport: transport)
    }

    // The pure comparison

    @Test func aNewerTagIsAvailableAndTheSameOrOlderIsUpToDate() throws {
        let latest = try GitHubReleaseFeed.decodeLatest(latestReleaseFixture)
        #expect(UpdateChecker.evaluate(installed: ReleaseVersion("0.0.11"), latest: latest) == .available(latest))
        #expect(UpdateChecker.evaluate(installed: ReleaseVersion("0.0.12"), latest: latest) == .upToDate(latest))
        // A dev build's 1.0 is ahead of every tag: nothing to offer it.
        #expect(UpdateChecker.evaluate(installed: ReleaseVersion("1.0"), latest: latest) == .upToDate(latest))
    }

    @Test func anUnreadableInstalledVersionIsAFailureNotAGuess() throws {
        let latest = try GitHubReleaseFeed.decodeLatest(latestReleaseFixture)
        guard case .failed = UpdateChecker.evaluate(installed: nil, latest: latest) else {
            Issue.record("expected .failed")
            return
        }
    }

    // The check end to end, with a canned network

    @Test func findsTheNewerReleaseAndStampsTheCheck() async throws {
        let fixture = latestReleaseFixture
        let http = response(200)
        let checker = checker(installed: "0.0.11") { _ in (fixture, http) }
        #expect(checker.status == .idle)
        #expect(checker.lastCheckedAt == nil)

        await checker.check()

        let latest = try GitHubReleaseFeed.decodeLatest(fixture)
        #expect(checker.status == .available(latest))
        #expect(checker.availableRelease == latest)
        #expect(checker.lastCheckedAt != nil)
        #expect(!checker.isChecking)
    }

    @Test func reportsUpToDateWhenAlreadyOnTheLatest() async {
        let fixture = latestReleaseFixture
        let http = response(200)
        let checker = checker(installed: "0.0.12") { _ in (fixture, http) }
        await checker.check()
        #expect(checker.availableRelease == nil)
        guard case .upToDate = checker.status else {
            Issue.record("expected .upToDate, got \(checker.status)")
            return
        }
    }

    @Test func aTransportErrorReadsAsOffline() async {
        let checker = checker(installed: "0.0.11") { _ in throw URLError(.notConnectedToInternet) }
        await checker.check()
        #expect(checker.status == .failed(UpdateCheckError.offline.message))
        #expect(checker.lastCheckedAt != nil)
    }

    @Test func rateLimitingAndOtherHTTPErrorsAreToldApart() async {
        let body = Data("{\"message\":\"API rate limit exceeded\"}".utf8)
        let limited = response(403)
        let rateLimited = checker(installed: "0.0.11") { _ in (body, limited) }
        await rateLimited.check()
        #expect(rateLimited.status == .failed(UpdateCheckError.rateLimited.message))

        let missing = response(404)
        let notFound = checker(installed: "0.0.11") { _ in (body, missing) }
        await notFound.check()
        #expect(notFound.status == .failed(UpdateCheckError.http(404).message))
        #expect(UpdateCheckError.http(404).message.contains("404"))
    }

    @Test func aBodyThatIsNotAReleaseIsMalformed() async {
        let http = response(200)
        let checker = checker(installed: "0.0.11") { _ in (Data("<!doctype html>".utf8), http) }
        await checker.check()
        #expect(checker.status == .failed(UpdateCheckError.malformed("").message))
    }

    /// The daily timer and a click on Check for Updates can coincide; GitHub
    /// should see one request, and both callers the same answer.
    @Test func concurrentChecksShareOneRequest() async throws {
        let counter = CallCounter()
        let fixture = latestReleaseFixture
        let http = response(200)
        let checker = checker(installed: "0.0.11") { _ in
            counter.increment()
            try await Task.sleep(for: .milliseconds(50))
            return (fixture, http)
        }

        async let first: Void = checker.check()
        async let second: Void = checker.check()
        _ = await (first, second)

        #expect(counter.value == 1)
        #expect(checker.availableRelease == (try GitHubReleaseFeed.decodeLatest(fixture)))

        // And a later check is a new request, not a stale answer.
        await checker.check()
        #expect(counter.value == 2)
    }

    @Test func aFailedCheckKeepsTheLastGoodAnswerOutOfTheWayButRecordsTheTime() async {
        // First answer: an update. Second: offline. The status becomes the
        // failure (the user asked and deserves the truth), and the timestamp
        // moves — nothing pretends the old answer is fresh.
        let fixture = latestReleaseFixture
        let http = response(200)
        let counter = CallCounter()
        let checker = checker(installed: "0.0.11") { _ in
            counter.increment()
            if counter.value == 1 { return (fixture, http) }
            throw URLError(.timedOut)
        }
        await checker.check()
        let firstStamp = checker.lastCheckedAt
        #expect(checker.availableRelease != nil)

        await checker.check()
        #expect(checker.availableRelease == nil)
        #expect(checker.status == .failed(UpdateCheckError.offline.message))
        #expect(checker.lastCheckedAt != nil && checker.lastCheckedAt! >= firstStamp!)
    }
}
