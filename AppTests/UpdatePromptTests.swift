//
//  UpdatePromptTests.swift
//  AppTests
//
//  The three rules of the launch prompt that are not about AppKit: at most one
//  interruption per launch, never while recording, and a check the user asked
//  for always answers. They are swept here rather than by hand because an
//  `NSAlert` cannot be clicked from a test — the fourth rule, that the alert
//  comes to the front of an agent app with no window, is the one that has to
//  be seen on a real machine.
//
//  Hosted because the type under test belongs to the app target; the rule
//  itself is pure and needs nothing from the host.
//

import Foundation
import Testing
import Updates

@testable import Echo

@Suite("The update prompt's rules")
struct UpdatePromptTests {

    /// The answer every case starts from: a release newer than this build.
    private func newer() throws -> LatestRelease {
        LatestRelease(
            version: try #require(ReleaseVersion("0.0.12")),
            tag: "v0.0.12",
            title: "Echo 0.0.12",
            pageURL: try #require(URL(string: "https://github.com/sancrisoft/echo/releases/tag/v0.0.12")),
            publishedAt: nil
        )
    }

    private func decide(
        _ status: UpdateChecker.Status,
        isRecording: Bool = false,
        alreadyOffered: Bool = false,
        asked: Bool
    ) -> UpdatePromptDecision {
        UpdatePrompt.decide(
            status: status,
            installedVersion: ReleaseVersion("0.0.11"),
            isRecording: isRecording,
            alreadyOffered: alreadyOffered,
            asked: asked
        )
    }

    // Rule 2: at most one per launch, and Later means later.

    @Test("the launch check offers once and then says nothing")
    func atMostOneOfferPerLaunch() throws {
        let release = try newer()
        #expect(decide(.available(release), asked: false) == .offer(release))
        #expect(decide(.available(release), alreadyOffered: true, asked: false) == .sayNothing)
    }

    @Test("a check the user asked for is not the launch's one interruption")
    func askingAgainStillOffers() throws {
        let release = try newer()
        #expect(decide(.available(release), alreadyOffered: true, asked: true) == .offer(release))
    }

    // Rule 3: never while recording.

    @Test("nothing interrupts a recording")
    func silentWhileRecording() throws {
        #expect(decide(.available(try newer()), isRecording: true, asked: false) == .sayNothing)
    }

    @Test("a check asked for during a recording says what it found and why it waits")
    func askingDuringARecordingStillAnswers() throws {
        let decision = decide(.available(try newer()), isRecording: true, asked: true)
        guard case .report(let title, let message) = decision else {
            Issue.record("expected a report, got \(decision)")
            return
        }
        #expect(title.contains("0.0.12"))
        #expect(message.contains("recording stops"))
    }

    // Rule 4: a check you asked for always answers.

    @Test("the automatic check is silent unless there is something new")
    func theAutomaticCheckIsSilent() throws {
        #expect(decide(.upToDate(try newer()), asked: false) == .sayNothing)
        #expect(decide(.failed("Couldn't reach GitHub. Are you online?"), asked: false) == .sayNothing)
        #expect(decide(.idle, asked: false) == .sayNothing)
    }

    @Test("a check the user asked for answers even when the answer is nothing")
    func theAskedCheckAlwaysAnswers() throws {
        let upToDate = decide(.upToDate(try newer()), asked: true)
        guard case .report(let title, _) = upToDate else {
            Issue.record("expected a report, got \(upToDate)")
            return
        }
        #expect(title == "You're up to date.")

        let reason = "Couldn't reach GitHub. Are you online?"
        let failed = decide(.failed(reason), asked: true)
        guard case .report(_, let message) = failed else {
            Issue.record("expected a report, got \(failed)")
            return
        }
        #expect(message == reason)
    }
}
