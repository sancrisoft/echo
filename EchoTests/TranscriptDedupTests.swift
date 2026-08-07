//
//  TranscriptDedupTests.swift
//  EchoTests
//
//  ADR-003 v2: asymmetric, overlap-linked, keep-on-doubt transcript
//  deduplication.
//
//  Every row here is SYNTHETIC. The structure is real — drifted starts,
//  containment fractions, mic/system rms ratios and segment lengths all
//  reproduce what was measured on two no-AEC meetings — but never the words:
//  transcript text from real meetings does not enter this repository.
//

import Foundation
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

    // MARK: - Linking (overlap, not start lag)

    @Test func echoOverlappingItsTeamSegmentIsSuppressed() {
        let teamSegment = team("We should ship the new build on Friday", start: 10.0, end: 13.0)
        let candidate = mic("We should ship the new build on Friday", start: 10.8, end: 13.8)

        let verdict = policy.verdict(for: candidate, against: [teamSegment])

        #expect(verdict?.match.id == teamSegment.id)
        #expect(verdict?.tier == .text)
    }

    /// The v1 regression, direction one: independent per-channel cutters put
    /// the mic segment's start 6.1 s after the Team segment's, far outside the
    /// old 0…2.5 s lag gate. The intervals still overlap, so v2 links them.
    @Test func echoWhoseStartDriftedPastTheOldLagGateIsSuppressed() {
        let teamSegment = team(
            "the staging cluster is out of disk so the nightly job never finished",
            start: 100.0, end: 112.0
        )
        let candidate = mic(
            "staging cluster is out of disk so the nightly job never finished",
            start: 106.1, end: 116.0
        )

        #expect(policy.verdict(for: candidate, against: [teamSegment])?.tier == .text)
    }

    /// The v1 regression, direction two: the mic cutter opened its segment
    /// 8.7 s BEFORE the Team segment starts (negative lag — the old gate
    /// required lag ≥ 0 and dropped these on the floor).
    @Test func echoStartingBeforeItsTeamSegmentIsSuppressed() {
        let teamSegment = team(
            "we will need a second reviewer on the payments change",
            start: 200.0, end: 208.0
        )
        let candidate = mic(
            "we will need a second reviewer on the payments change",
            start: 191.3, end: 203.0
        )

        #expect(policy.verdict(for: candidate, against: [teamSegment])?.tier == .text)
    }

    /// Linking is mandatory: a mic segment that ends before the Team segment
    /// begins cannot be its echo — echoes follow their source, never precede
    /// it — however identical the words.
    @Test func micSegmentEndingBeforeTheTeamSegmentStartsIsKept() {
        let teamSegment = team("we will need a second reviewer", start: 300.0, end: 306.0)
        let candidate = mic("we will need a second reviewer", start: 294.0, end: 299.5)

        #expect(policy.verdict(for: candidate, against: [teamSegment]) == nil)
    }

    /// US-9 at the new boundary: past the echo tail, a verbatim repetition is
    /// the user speaking, and the text no longer matters.
    @Test func verbatimRepetitionAfterTheEchoTailIsKept() {
        let teamSegment = team("We should ship the new build on Friday", start: 10.0, end: 13.0)
        let candidate = mic("We should ship the new build on Friday", start: 15.6, end: 18.6)

        #expect(policy.verdict(for: candidate, against: [teamSegment]) == nil)
    }

    /// The documented, accepted exposure: repeating a teammate verbatim while
    /// they speak or within the 2.5 s tail reads as bleed and is suppressed.
    /// v1 had the same exposure over its own 2.5 s window; v2's is the tail,
    /// which is slightly wider. Recorded here so it is a decision, not a
    /// surprise.
    @Test func verbatimRepetitionInsideTheEchoTailIsSuppressed() {
        let teamSegment = team("We should ship the new build on Friday", start: 10.0, end: 13.0)
        let candidate = mic("We should ship the new build on Friday", start: 14.0, end: 17.0)

        #expect(policy.verdict(for: candidate, against: [teamSegment])?.tier == .text)
    }

    // MARK: - Containment

    /// Punctuation and casing differ freely between the channels' independent
    /// transcriptions.
    @Test func punctuationAndCaseDifferencesDoNotDefeatMatching() {
        let teamSegment = team("We'll deploy the release tomorrow morning, okay?", start: 20.0, end: 23.0)
        let candidate = mic("we'll deploy the release tomorrow morning okay", start: 20.9, end: 23.9)

        #expect(policy.verdict(for: candidate, against: [teamSegment])?.tier == .text)
    }

    /// Word endings drift between channels; stems do not. Exact matching alone
    /// scores this 4/7 ≈ 0.57 and keeps it — the 5-character prefix rule
    /// recovers "escalating"/"escalate", "blocking"/"blocked", "ticket"/
    /// "tickets" and takes it to 1.0.
    @Test func sharedStemsAbsorbWordEndingVariance() {
        let teamSegment = team(
            "we should escalate the blocked deployment tickets",
            start: 30.0, end: 34.0
        )
        let candidate = mic(
            "we should escalating the blocking deployment ticket",
            start: 30.7, end: 34.5
        )

        let verdict = policy.verdict(for: candidate, against: [teamSegment])

        #expect(verdict?.tier == .text)
        #expect(verdict?.containment == 1.0)
    }

    /// A four-character difference is not a stem match: "team"/"teams" share
    /// only 4 leading characters, so the rule must not fire on them.
    @Test func prefixesShorterThanFiveCharactersDoNotMatch() {
        let teamSegment = team("plan cost team rate", start: 40.0, end: 42.0)
        let candidate = mic("plans costs teams rates", start: 40.4, end: 42.4)

        #expect(policy.verdict(for: candidate, against: [teamSegment]) == nil)
    }

    /// Keep-on-doubt: overlapping, but the words are the user's own.
    @Test func differentWordsInsideTheEchoWindowAreKept() {
        let teamSegment = team("Let's review the budget numbers after lunch today", start: 40.0, end: 43.0)
        let candidate = mic("I still need to finish the onboarding document", start: 40.9, end: 43.5)

        #expect(policy.verdict(for: candidate, against: [teamSegment]) == nil)
    }

    /// Short acknowledgements carry too little text to distinguish echo from a
    /// genuine reply — keep-on-doubt says never suppress them.
    @Test(arguments: ["yes", "ok", "Sounds good."])
    func shortSegmentsAreNeverSuppressed(text: String) {
        let teamSegment = team(text, start: 50.0, end: 50.6)
        let candidate = mic(text, start: 50.3, end: 50.9)

        #expect(policy.verdict(for: candidate, against: [teamSegment]) == nil)
    }

    /// One utterance's echo routinely lands across two Team segments, because
    /// each channel is cut at its own silences. Scored against either half
    /// alone the candidate reads 0.50 / 0.58 and survives; pooled it is 1.0.
    @Test func linkedTeamSegmentsArePooledSoASplitEchoStillScores() {
        let first = team("we need the vendor contract signed", start: 400.0, end: 403.0)
        let second = team("before the quarterly audit starts on Monday", start: 403.2, end: 406.0)
        let candidate = mic(
            "we need the vendor contract signed before the quarterly audit starts on Monday",
            start: 400.5, end: 406.5
        )

        let verdict = policy.verdict(for: candidate, against: [first, second])

        #expect(verdict?.tier == .text)
        #expect(verdict?.containment == 1.0)
        // Named match: whichever linked segment alone accounts for most of it.
        #expect(verdict?.match.id == second.id)
    }

    @Test func verdictNamesTheStrongestLinkedTeamSegment() {
        let unrelated = team("Can everyone see my screen now", start: 70.0, end: 71.5)
        let echoed = team("The staging environment is down again this morning", start: 70.5, end: 73.0)
        let candidate = mic("The staging environment is down again this morning", start: 71.2, end: 73.7)

        #expect(policy.verdict(for: candidate, against: [unrelated, echoed])?.match.id == echoed.id)
    }

    // MARK: - Asymmetry

    /// ADR-003 asymmetry: Team segments are never suppressed — bleed only ever
    /// flows loudspeakers → mic, so only mic candidates can be echoes.
    @Test func systemChannelCandidateIsNeverSuppressed() {
        let micSegment = mic("Let me walk you through the migration plan", start: 60.0, end: 62.5)
        let earlierTeam = team("Let me walk you through the migration plan", start: 60.0, end: 62.5)
        let candidate = team("Let me walk you through the migration plan", start: 60.8, end: 63.3)

        #expect(policy.verdict(for: candidate, against: [micSegment]) == nil)
        #expect(policy.verdict(for: candidate, against: [earlierTeam]) == nil)
    }
}

/// Tier B: cross-channel level evidence resolving a weak text match — and the
/// safety property that bounds it. Ratios and containments here are the ones
/// measured on the no-AEC fixture: bleed 0.05–0.43, the user's own voice ≳ 1.
struct EchoDedupEvidenceTests {

    private let policy = EchoDedupPolicy()

    private func team(_ text: String, start: Double, end: Double) -> TranscriptSegment {
        TranscriptSegment(channel: .system, speaker: .teammates, text: text, start: start, end: end)
    }

    private func mic(_ text: String, start: Double, end: Double) -> TranscriptSegment {
        TranscriptSegment(channel: .microphone, speaker: .me, text: text, start: start, end: end)
    }

    /// A garbled short echo: 2 of its 5 tokens survive the round trip through
    /// the speakers, so containment is 0.40 — under the text-only bar, over
    /// the assisted one.
    private let teamSegment = TranscriptSegment(
        channel: .system, speaker: .teammates,
        text: "the invoice batch failed again overnight",
        start: 50.0, end: 54.0
    )
    private let garbledEcho = TranscriptSegment(
        channel: .microphone, speaker: .me,
        text: "invoice batch stalled early today",
        start: 50.2, end: 54.4
    )

    /// Levels for the candidate's own window: `own` is the mic there, `other`
    /// the system channel over that same moment.
    private func levels(
        _ segment: TranscriptSegment,
        own: Float,
        other: Float,
        ownVoiceSeconds: TimeInterval = 0
    ) -> [UUID: EchoDedupPolicy.SpanLevels] {
        [segment.id: EchoDedupPolicy.SpanLevels(
            own: own, other: other, ownVoiceSeconds: ownVoiceSeconds
        )]
    }

    @Test func weakTextMatchWithoutEvidenceIsKept() {
        let verdict = policy.verdict(for: garbledEcho, against: [teamSegment])

        #expect(verdict == nil)
    }

    @Test func weakTextMatchAtBleedLevelIsSuppressed() {
        let evidence = levels(garbledEcho, own: 0.01, other: 0.04)

        let verdict = policy.verdict(for: garbledEcho, against: [teamSegment], spanLevels: evidence)

        #expect(verdict?.tier == .assisted)
        #expect(verdict?.containment == 0.4)
        #expect(verdict?.rmsRatio == 0.25)
    }

    /// Double-talk: the same weak text match at the user's own speaking level
    /// (ratio ≳ 1) is the user talking over the teammate, and is kept.
    @Test func weakTextMatchAtSpeakingLevelIsKept() {
        let evidence = levels(garbledEcho, own: 0.066, other: 0.060)

        #expect(policy.verdict(for: garbledEcho, against: [teamSegment], spanLevels: evidence) == nil)
    }

    /// THE safety property (bleed-fix §2.3, BRN-005): energy never suppresses
    /// alone. Quiet is not evidence of anything by itself — a segment whose
    /// words are the user's own survives at any level, which is what makes the
    /// gates-erasing-real-speech failure structurally impossible here.
    @Test(arguments: [Float(0.05), 0.001, 0.0])
    func quietSpeechWithItsOwnWordsIsNeverSuppressed(ratio: Float) {
        let ownWords = mic("let me check the dashboard first", start: 50.5, end: 54.5)
        let evidence = levels(ownWords, own: 0.030 * ratio, other: 0.030)

        #expect(policy.verdict(for: ownWords, against: [teamSegment], spanLevels: evidence) == nil)
    }

    /// Evidence must be complete to count: a missing or degenerate denominator
    /// leaves the ratio unknown, and an unknown ratio is not a quiet one.
    @Test func missingOrDegenerateEvidenceDoesNotEnableTierB() {
        let otherSegment = levels(teamSegment, own: 0.04, other: 0.01)
        let silentOpposite = levels(garbledEcho, own: 0.01, other: 0.0)

        // Evidence for a different segment is no evidence for this one.
        #expect(policy.verdict(for: garbledEcho, against: [teamSegment], spanLevels: otherSegment) == nil)
        // A silent opposite channel is the opposite of bleed, not a quiet ratio.
        #expect(policy.verdict(for: garbledEcho, against: [teamSegment], spanLevels: silentOpposite) == nil)
    }

    /// Evidence never *rescues* a segment either: a strong text match is
    /// Tier A whatever the level. The exposure is documented in the policy.
    @Test func loudSegmentWithFullContainmentIsStillTierA() {
        let echo = mic("the invoice batch failed again overnight", start: 50.2, end: 54.4)
        let evidence = levels(echo, own: 0.070, other: 0.030)

        #expect(policy.verdict(for: echo, against: [teamSegment], spanLevels: evidence)?.tier == .text)
    }

    // MARK: - Own-voice guard

    /// A mixed segment: the teammates' audio runs underneath, so the levels
    /// average out to bleed and the text is largely theirs — but the user
    /// demonstrably spoke for 3.7 s inside it, and those words exist nowhere
    /// else. Whole-segment suppression would take them with the echo.
    @Test func aSustainedRunOfTheUsersOwnVoiceKeepsAWholeMixedSegment() {
        let mixed = mic("invoice batch stalled early today", start: 50.2, end: 62.2)
        let evidence = levels(mixed, own: 0.017, other: 0.041, ownVoiceSeconds: 3.7)

        #expect(policy.verdict(for: mixed, against: [teamSegment], spanLevels: evidence) == nil)
    }

    /// The guard outranks Tier A too: a strong text match is still only
    /// evidence about words, and this is evidence about who was talking.
    @Test func theGuardKeepsSegmentsTheTextAloneWouldHaveTaken() {
        let mixed = mic("the invoice batch failed again overnight", start: 50.2, end: 62.2)
        let evidence = levels(mixed, own: 0.017, other: 0.041, ownVoiceSeconds: 1.1)

        #expect(policy.verdict(for: mixed, against: [teamSegment], spanLevels: evidence) == nil)
    }

    /// Below the threshold it is the echo's own modulation crossing over, not
    /// speech, and the row is still bleed. 0.8 s was a real measured margin.
    @Test(arguments: [0.0, 0.4, 0.8])
    func briefCrossoversDoNotRescueBleed(ownVoiceSeconds: TimeInterval) {
        let echo = mic("invoice batch stalled early today", start: 50.2, end: 54.4)
        let evidence = levels(
            echo, own: 0.01, other: 0.04, ownVoiceSeconds: ownVoiceSeconds
        )

        let verdict = policy.verdict(for: echo, against: [teamSegment], spanLevels: evidence)

        #expect(verdict?.tier == .assisted)
        #expect(verdict?.ownVoiceSeconds == ownVoiceSeconds)
    }

    /// The ratio is a property of the candidate's own window on both channels,
    /// so which Team segments happen to link — and how loud they were on their
    /// own, different spans — cannot move it. That independence is why the
    /// measured 0.05–0.43 / ≳ 1 separation survives contact with real cutting:
    /// scoring a candidate against another segment's window compares two
    /// different moments, and stops discriminating the instant either channel's
    /// loudness changes between them.
    @Test func ratioIsUnaffectedByWhichTeamSegmentsLink() {
        let quietTeam = team("could you repeat that", start: 49.0, end: 50.1)
        let evidence = levels(garbledEcho, own: 0.01, other: 0.04)

        let alone = policy.verdict(for: garbledEcho, against: [teamSegment], spanLevels: evidence)
        let withNeighbour = policy.verdict(
            for: garbledEcho, against: [quietTeam, teamSegment], spanLevels: evidence
        )

        #expect(alone?.rmsRatio == 0.25)
        #expect(withNeighbour?.rmsRatio == 0.25)
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
