//
//  FinalDedupCompositionTests.swift
//  EchoTests
//
//  SP-005 layer 2: ADR-003 dedup re-run as a batch over complete final
//  segment sets. The final pass segments each channel independently, so the
//  batch is where v2's two repairs have to hold — overlap linking against the
//  whole Team set, and directional containment that a long mic segment cannot
//  dilute with the user's own words.
//
//  Rows are synthetic (see TranscriptDedupTests' header): measured structure,
//  invented words.
//

import Foundation
import Testing
@testable import Echo

@Suite("EchoDedupPolicy batch composition (final segments)")
struct FinalDedupCompositionTests {

    private let policy = EchoDedupPolicy()

    private func team(_ text: String, start: Double, end: Double) -> TranscriptSegment {
        TranscriptSegment(channel: .system, speaker: .teammates, text: text, start: start, end: end)
    }

    private func mic(_ text: String, start: Double, end: Double) -> TranscriptSegment {
        TranscriptSegment(channel: .microphone, speaker: .me, text: text, start: start, end: end)
    }

    /// The case v2's directionality exists for: the mic cutter merged an echo
    /// into 11 s of the user's own speech. Containment counts only what the
    /// teammates also said — 8 of the mic segment's 27 tokens, 0.30 — so the
    /// user's surrounding words keep it, exactly as they should. (v1 scored
    /// this with symmetric Jaccard and kept it for the same reason; the
    /// difference is that v2 no longer needs the dilution to be an accident.)
    @Test("a long mic segment whose own words dominate survives (directional containment)")
    func longMergedMicSegmentSurvivesOnItsOwnWords() {
        let teamSegment = team(
            "we will ship the new build on friday",
            start: 100.0, end: 102.5
        )
        let mergedMic = mic(
            """
            Let me recap the sprint goals before we wrap up we will ship the \
            new build on Friday and after that I will start drafting the \
            migration plan for the analytics service
            """,
            start: 100.5, end: 112.0
        )

        let result = policy.dedupe(final: [teamSegment, mergedMic])

        #expect(result.map(\.id) == [teamSegment.id, mergedMic.id])
    }

    /// The other side of the same coin: strip the user's own speech away and
    /// what is left is bleed — same Team segment, same overlap, suppressed.
    /// Directionality protects real speech, not echo.
    @Test("the same echo without the user's surrounding speech is suppressed")
    func theBareEchoOfThatTeamSegmentIsSuppressed() {
        let teamSegment = team(
            "we will ship the new build on friday",
            start: 100.0, end: 102.5
        )
        let bareEcho = mic("we will ship the new build on Friday", start: 100.5, end: 103.4)

        #expect(policy.dedupe(final: [teamSegment, bareEcho]).map(\.id) == [teamSegment.id])
    }

    /// SP-005 named risk (b), the direction batch dedup wins: live, the Team
    /// counterpart transcribed too late to be in the "recent" set when the mic
    /// echo arrived — in the complete final batch it is present and matchable,
    /// so the overlapping high-containment mic segment IS suppressed.
    @Test("a Team counterpart that live arrived too late suppresses the echo in batch")
    func lateTeamCounterpartSuppressesEchoInBatch() {
        let lateTeam = team(
            "the deployment pipeline is blocked on the certificate renewal",
            start: 50.0, end: 53.0
        )
        let echo = mic(
            "The deployment pipeline is blocked on the certificate renewal",
            start: 50.9, end: 53.9
        )
        let unrelatedMic = mic(
            "I can pick up the certificate task tomorrow morning if that helps",
            start: 55.0, end: 58.0
        )

        let result = policy.dedupe(final: [lateTeam, echo, unrelatedMic])

        #expect(result.map(\.id) == [lateTeam.id, unrelatedMic.id])
    }

    /// US-9 in batch: past the echo tail the user is speaking, not echoing.
    @Test("a verbatim repeat after the echo tail survives the batch")
    func verbatimRepeatAfterTheTailSurvives() {
        let teamSegment = team(
            "we should freeze the schema before the data migration",
            start: 20.0, end: 23.0
        )
        let repetition = mic(
            "we should freeze the schema before the data migration",
            start: 25.6, end: 28.6   // starts past team.end + 2.5 s
        )

        let result = policy.dedupe(final: [teamSegment, repetition])

        #expect(result.map(\.id) == [teamSegment.id, repetition.id])
    }

    @Test("a pure-mic set (no Team segments) passes through unchanged")
    func pureMicSetIsUnchanged() {
        let segments = [
            mic("Recording a quick voice memo about the release checklist", start: 0.0, end: 3.0),
            mic("Recording a quick voice memo about the release checklist", start: 4.0, end: 7.0),
            mic("First item is the notarization ticket", start: 8.0, end: 10.0),
        ]

        #expect(policy.dedupe(final: segments).map(\.id) == segments.map(\.id))
    }

    /// ADR-003 asymmetry holds in batch: Team segments always pass, and the
    /// filter preserves the input's timeline order.
    @Test("Team segments are never suppressed and order is preserved")
    func teamSegmentsPassAndOrderIsPreserved() {
        let first = team("Can everyone see my screen now", start: 1.0, end: 2.5)
        let micReply = mic("Yes it looks sharp from here on my laptop", start: 3.0, end: 5.0)
        let second = team("Give me one moment to share the other tab", start: 3.2, end: 5.2)

        let result = policy.dedupe(final: [first, micReply, second])

        #expect(result.map(\.id) == [first.id, micReply.id, second.id])
    }

    /// The exposure v2 widened, written down: linking is direction-free, so a
    /// mic segment that duplicates an overlapping Team segment is suppressed
    /// even when it *starts first* (v1's gate required a non-negative lag and
    /// let these through — which is precisely how drifted-start bleed escaped).
    @Test("a mic segment duplicating an overlapping Team segment goes, whatever the lag sign")
    func duplicatingMicSegmentGoesEvenWithNegativeLag() {
        let micFirst = mic("Yes it looks sharp from here on my laptop", start: 3.0, end: 5.0)
        let teamLater = team("Yes it looks sharp from here on my laptop", start: 3.2, end: 5.2)

        #expect(policy.dedupe(final: [micFirst, teamLater]).map(\.id) == [teamLater.id])
    }

    // MARK: - Evidence in batch

    /// Evidence is keyed by segment id and changes Tier B only: the same batch
    /// keeps the garbled echo without it and drops it with it.
    @Test("supplying span rms enables Tier B and nothing else")
    func spanRmsEnablesTierBOnly() {
        let teamSegment = team("the invoice batch failed again overnight", start: 50.0, end: 54.0)
        let garbledEcho = mic("invoice batch stalled early today", start: 50.2, end: 54.4)
        let ownWords = mic("let me check the dashboard first", start: 50.5, end: 54.5)
        let batch = [teamSegment, garbledEcho, ownWords]
        // Bleed level for both mic rows — only the one that duplicates the
        // teammates' words is eligible.
        let evidence: [UUID: Float] = [
            teamSegment.id: 0.04, garbledEcho.id: 0.01, ownWords.id: 0.01,
        ]

        #expect(policy.dedupe(final: batch).map(\.id) == batch.map(\.id))
        #expect(
            policy.dedupe(final: batch, spanRms: evidence).map(\.id)
                == [teamSegment.id, ownWords.id]
        )
    }

    /// The harness's window into the batch: one verdict per suppressed
    /// segment, in input order, carrying the evidence that decided it.
    @Test("every suppression is reported with its tier and evidence")
    func suppressionsAreReported() {
        let teamSegment = team("the invoice batch failed again overnight", start: 50.0, end: 54.0)
        let bareEcho = mic("the invoice batch failed again overnight", start: 50.2, end: 54.4)
        let garbledEcho = mic("invoice batch stalled early today", start: 60.0, end: 64.0)
        let laterTeam = team("the invoice batch failed again overnight", start: 59.8, end: 63.6)
        // The loud echo is Tier A regardless of its level (2.0), the garbled
        // quiet one needs the 0.25 ratio to go.
        let evidence: [UUID: Float] = [
            teamSegment.id: 0.04, bareEcho.id: 0.08,
            laterTeam.id: 0.04, garbledEcho.id: 0.01,
        ]

        struct Report {
            let segment: TranscriptSegment
            let verdict: EchoDedupPolicy.SuppressionVerdict
        }
        var reported: [Report] = []
        let kept = policy.dedupe(
            final: [teamSegment, bareEcho, garbledEcho, laterTeam],
            spanRms: evidence,
            onSuppression: { reported.append(Report(segment: $0, verdict: $1)) }
        )

        #expect(kept.map(\.id) == [teamSegment.id, laterTeam.id])
        #expect(reported.map(\.segment.id) == [bareEcho.id, garbledEcho.id])
        #expect(reported.map(\.verdict.tier) == [.text, .assisted])
        #expect(reported.map(\.verdict.rmsRatio) == [Float(2.0), Float(0.25)])
    }
}
