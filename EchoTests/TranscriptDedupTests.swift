//
//  TranscriptDedupTests.swift
//  EchoTests
//
//  ADR-003: asymmetric, timing-gated, keep-on-doubt transcript deduplication.
//

import Testing
@testable import Echo

struct TranscriptDedupTests {

    private let policy = EchoDedupPolicy()

    private func team(_ text: String, start: Double, end: Double) -> TranscriptSegment {
        TranscriptSegment(channel: .system, speaker: .teammates, text: text, start: start, end: end)
    }

    private func mic(_ text: String, start: Double, end: Double) -> TranscriptSegment {
        TranscriptSegment(channel: .microphone, speaker: .me, text: text, start: start, end: end)
    }

    @Test func echoPairInsideLagWindowIsSuppressed() {
        let teamSegment = team("We should ship the new build on Friday", start: 10.0, end: 13.0)
        let candidate = mic("We should ship the new build on Friday", start: 10.8, end: 13.8)

        let match = policy.suppressionMatch(for: candidate, against: [teamSegment])

        #expect(match?.id == teamSegment.id)
    }

    /// US-9: a verbatim user repetition outside the echo lag window is kept,
    /// no matter how similar the text — the timing gate is mandatory.
    @Test func verbatimRepetitionOutsideLagWindowIsKept() {
        let teamSegment = team("We should ship the new build on Friday", start: 10.0, end: 13.0)
        let candidate = mic("We should ship the new build on Friday", start: 16.0, end: 19.0)

        #expect(policy.suppressionMatch(for: candidate, against: [teamSegment]) == nil)
    }

    /// Whisper transcribes the bleed independently, so punctuation and casing
    /// routinely differ between the two channels' text.
    @Test func punctuationAndCaseDifferencesDoNotDefeatMatching() {
        let teamSegment = team("We'll deploy the release tomorrow morning, okay?", start: 20.0, end: 23.0)
        let candidate = mic("we'll deploy the release tomorrow morning okay", start: 20.9, end: 23.9)

        let match = policy.suppressionMatch(for: candidate, against: [teamSegment])

        #expect(match?.id == teamSegment.id)
    }

    /// Keep-on-doubt: inside the lag window but with wording drifted below the
    /// similarity threshold, the segment is kept.
    @Test func lowSimilarityInsideLagWindowIsKept() {
        let teamSegment = team("Let's review the budget numbers after lunch today", start: 40.0, end: 43.0)
        let candidate = mic("I still need to finish the onboarding document", start: 40.9, end: 43.5)

        #expect(policy.suppressionMatch(for: candidate, against: [teamSegment]) == nil)
    }

    /// Short acknowledgements carry too little text to distinguish echo from a
    /// genuine reply — keep-on-doubt says never suppress them.
    @Test(arguments: ["yes", "ok", "Sounds good."])
    func shortSegmentsAreNeverSuppressed(text: String) {
        let teamSegment = team(text, start: 50.0, end: 50.6)
        let candidate = mic(text, start: 50.3, end: 50.9)

        #expect(policy.suppressionMatch(for: candidate, against: [teamSegment]) == nil)
    }

    /// ADR-003 asymmetry: Team segments are never suppressed — bleed only ever
    /// flows loudspeakers → mic, so only mic candidates can be echoes.
    @Test func systemChannelCandidateIsNeverSuppressed() {
        let micSegment = mic("Let me walk you through the migration plan", start: 60.0, end: 62.5)
        let earlierTeam = team("Let me walk you through the migration plan", start: 60.0, end: 62.5)
        let candidate = team("Let me walk you through the migration plan", start: 60.8, end: 63.3)

        #expect(policy.suppressionMatch(for: candidate, against: [micSegment]) == nil)
        #expect(policy.suppressionMatch(for: candidate, against: [earlierTeam]) == nil)
    }

    /// Echo is transcribed independently and often drifts a word or two; high
    /// (not perfect) token overlap inside the window still suppresses.
    @Test func slightlyDriftedEchoInsideLagWindowIsSuppressed() {
        let teamSegment = team("I think we should merge the feature branch before the demo", start: 30.0, end: 33.5)
        let candidate = mic("I think we should merge the future branch before the demo", start: 30.7, end: 34.2)

        let match = policy.suppressionMatch(for: candidate, against: [teamSegment])

        #expect(match?.id == teamSegment.id)
    }

    @Test func matchPointsAtTheRightTeamSegmentAmongSeveral() {
        let unrelated = team("Can everyone see my screen now", start: 70.0, end: 71.5)
        let echoed = team("The staging environment is down again this morning", start: 70.5, end: 73.0)
        let candidate = mic("The staging environment is down again this morning", start: 71.2, end: 73.7)

        let match = policy.suppressionMatch(for: candidate, against: [unrelated, echoed])

        #expect(match?.id == echoed.id)
    }
}

/// Integration: `RecordingState.append` applies the policy to finalized segments.
@MainActor
struct RecordingStateDedupTests {

    @Test func appendDropsEchoSegmentAndKeepsTeamSegment() {
        let state = RecordingState()
        let teamSegment = TranscriptSegment(
            channel: .system, speaker: .teammates,
            text: "We agreed to move the launch to next Tuesday",
            start: 5.0, end: 8.0
        )
        let echo = TranscriptSegment(
            channel: .microphone, speaker: .me,
            text: "we agreed to move the launch to next Tuesday",
            start: 5.8, end: 8.8
        )

        state.append(teamSegment)
        state.append(echo)

        #expect(state.segments.map(\.id) == [teamSegment.id])
    }

    @Test func appendKeepsNonDuplicateMicSegmentsInSortedOrder() {
        let state = RecordingState()
        let teamSegment = TranscriptSegment(
            channel: .system, speaker: .teammates,
            text: "We agreed to move the launch to next Tuesday",
            start: 5.0, end: 8.0
        )
        let laterMic = TranscriptSegment(
            channel: .microphone, speaker: .me,
            text: "I'll update the release checklist after this call",
            start: 9.0, end: 11.0
        )
        let earlierMic = TranscriptSegment(
            channel: .microphone, speaker: .me,
            text: "Before we start, one quick question about the agenda",
            start: 1.0, end: 3.5
        )

        state.append(teamSegment)
        state.append(laterMic)
        state.append(earlierMic)

        #expect(state.segments.map(\.id) == [earlierMic.id, teamSegment.id, laterMic.id])
    }
}
