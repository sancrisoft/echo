//
//  UpdateCheckerTests.swift
//  UpdatesTests
//
//  The comparison, the error mapping, and the one request two callers share.
//

import Foundation
import Testing

@testable import Updates

/// Counts calls from any thread; the transport closure is `@Sendable`.
private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

@Suite("Update checker")
@MainActor
struct UpdateCheckerTests {

    private func response(_ status: Int) throws -> URLResponse {
        try #require(
            HTTPURLResponse(
                url: GitHubReleaseFeed.latestReleaseAPIURL,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )
        )
    }

    private func checker(
        installed: String?,
        transport: @escaping UpdateChecker.Transport
    ) -> UpdateChecker {
        UpdateChecker(
            installedVersion: installed.flatMap(ReleaseVersion.init),
            appVersion: "0.0.11",
            transport: transport
        )
    }

    // The pure comparison

    @Test func aNewerTagIsAvailableAndTheSameOrOlderIsUpToDate() throws {
        let latest = try GitHubReleaseFeed.decodeLatest(latestReleaseFixture)
        #expect(UpdateChecker.evaluate(installed: ReleaseVersion("0.0.11"), latest: latest) == .available(latest))
        #expect(UpdateChecker.evaluate(installed: ReleaseVersion("0.0.12"), latest: latest) == .upToDate(latest))
        // A dev build's 1.0 is ahead of every tag: nothing to offer it.
        #expect(UpdateChecker.evaluate(installed: ReleaseVersion("1.0"), latest: latest) == .upToDate(latest))
    }

    @Test func aLeftoverInstallFailureIsKeptForSettings() {
        let checker = checker(installed: "0.0.11") { _ in throw URLError(.notConnectedToInternet) }
        #expect(checker.lastInstallFailure == nil)
        checker.noteInstallFailure("The installer exited with code 1")
        #expect(checker.lastInstallFailure == "The installer exited with code 1")
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
        let http = try response(200)
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

    @Test func reportsUpToDateWhenAlreadyOnTheLatest() async throws {
        let fixture = latestReleaseFixture
        let http = try response(200)
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
        #expect(checker.status == .failed(UpdateCheckFailure.offline.message))
        #expect(checker.lastCheckedAt != nil)
    }

    @Test func rateLimitingAndOtherHTTPErrorsAreToldApart() async throws {
        let body = Data("{\"message\":\"API rate limit exceeded\"}".utf8)
        let limited = try response(403)
        let rateLimited = checker(installed: "0.0.11") { _ in (body, limited) }
        await rateLimited.check()
        #expect(rateLimited.status == .failed(UpdateCheckFailure.rateLimited.message))

        let missing = try response(404)
        let notFound = checker(installed: "0.0.11") { _ in (body, missing) }
        await notFound.check()
        #expect(notFound.status == .failed(UpdateCheckFailure.http(404).message))
        #expect(UpdateCheckFailure.http(404).message.contains("404"))
    }

    @Test func aBodyThatIsNotAReleaseIsMalformed() async throws {
        let http = try response(200)
        let checker = checker(installed: "0.0.11") { _ in (Data("<!doctype html>".utf8), http) }
        await checker.check()
        #expect(checker.status == .failed(UpdateCheckFailure.malformed("").message))
    }

    /// The daily timer and a click on Check for Updates can coincide; GitHub
    /// should see one request, and both callers the same answer.
    @Test func concurrentChecksShareOneRequest() async throws {
        let counter = CallCounter()
        let fixture = latestReleaseFixture
        let http = try response(200)
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

    @Test func aFailedCheckKeepsTheLastGoodAnswerOutOfTheWayButRecordsTheTime() async throws {
        // First answer: an update. Second: offline. The status becomes the
        // failure (the user asked and deserves the truth), and the timestamp
        // moves — nothing pretends the old answer is fresh.
        let fixture = latestReleaseFixture
        let http = try response(200)
        let counter = CallCounter()
        let checker = checker(installed: "0.0.11") { _ in
            counter.increment()
            if counter.value == 1 { return (fixture, http) }
            throw URLError(.timedOut)
        }
        await checker.check()
        let firstStamp = try #require(checker.lastCheckedAt)
        #expect(checker.availableRelease != nil)

        await checker.check()
        #expect(checker.availableRelease == nil)
        #expect(checker.status == .failed(UpdateCheckFailure.offline.message))
        #expect(try #require(checker.lastCheckedAt) >= firstStamp)
    }
}
