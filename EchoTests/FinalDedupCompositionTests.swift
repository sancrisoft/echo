//
//  FinalDedupCompositionTests.swift
//  EchoTests
//
//  SP-005 layer 2: ADR-003 dedup re-run as a batch over complete final
//  segment sets. The final pass re-segments both channels (30 s windows, not
//  1–12 s chunks) and hands the policy the whole Team set at once — so the
//  two named composition risks get explicit rows: Jaccard dilution on long
//  merged mic segments (keep-on-doubt SURVIVES, by policy), and the
//  late-arriving Team counterpart live couldn't match (batch IS stronger).
//

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

    /// SP-005 named risk (a): the final pass's coarser segmentation merges an
    /// echo with the user's own surrounding speech into one long mic segment.
    /// The shared tokens dilute Jaccard below the 0.6 threshold, so the policy
    /// keeps it — keep-on-doubt IS the policy (a false deletion would drop the
    /// user's real words around the bleed). This row documents that behavior;
    /// the SP-001 echo fixtures are the real-audio check.
    @Test("a long merged mic segment spanning one short Team segment survives (Jaccard dilution, keep-on-doubt)")
    func longMergedMicSegmentSurvivesDilution() {
        let teamSegment = team(
            "we will ship the new build on friday",
            start: 100.0, end: 102.5
        )
        // Starts 0.5 s after the Team segment — inside the 2.5 s timing gate —
        // and contains the whole echo, diluted by the user's own speech:
        // 8 shared tokens over a 27-token union ≈ 0.30, below 0.6.
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

    /// SP-005 named risk (b), the direction batch dedup wins: live, the Team
    /// counterpart transcribed too late to be in the "recent" set when the mic
    /// echo arrived — in the complete final batch it is present and matchable,
    /// so the in-window high-similarity mic segment IS suppressed.
    @Test("a Team counterpart that live arrived too late suppresses the in-window echo in batch")
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

    /// The timing gate is mandatory in batch exactly as live (US-9): the user
    /// repeating a teammate verbatim outside the lag window is never bleed.
    @Test("a verbatim repeat outside the lag window survives the batch")
    func verbatimRepeatOutsideWindowSurvives() {
        let teamSegment = team(
            "we should freeze the schema before the data migration",
            start: 20.0, end: 23.0
        )
        let repetition = mic(
            "we should freeze the schema before the data migration",
            start: 23.5, end: 26.5   // lag 3.5 s > 2.5 s gate
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

    /// SP-007 composition (ADR-019 before ADR-003): run collapse keeps the
    /// FIRST run member precisely so the collapsed Team run stays a matchable
    /// dedup timing anchor — its mic echo starts within the 2.5 s gate of the
    /// run's first member, not its last.
    @Test("a collapsed Team run's surviving representative still catches its mic echo")
    func collapsedTeamRunStillCatchesItsMicEcho() {
        let teamRun = (0..<3).map { index in
            team(
                "the certificate renewal is blocking the deploy",
                start: 10.0 + Double(index) * 2.0,
                end: 11.5 + Double(index) * 2.0
            )
        }
        let echo = mic(
            "The certificate renewal is blocking the deploy",
            start: 10.8, end: 12.3
        )

        let collapsedTeam = FinalPassDiscipline.collapseRuns(teamRun)
        #expect(collapsedTeam.map(\.id) == [teamRun[0].id])

        let batch = (collapsedTeam + [echo]).sorted { $0.start < $1.start }
        let result = policy.dedupe(final: batch)

        #expect(result.map(\.id) == [teamRun[0].id])
    }

    /// SP-007 composition, mic side: a mic repetition run collapsed to one
    /// candidate is still suppressed when that candidate is bleed of a Team
    /// segment (in-gate, high similarity).
    @Test("a mic run collapsed to one candidate is still suppressed when it is bleed")
    func collapsedMicRunBleedIsSuppressed() {
        let teamSegment = team(
            "we should freeze the schema before the migration",
            start: 10.0, end: 12.5
        )
        let micRun = (0..<3).map { index in
            mic(
                "we should freeze the schema before the migration",
                start: 10.5 + Double(index) * 2.0,
                end: 12.5 + Double(index) * 2.0
            )
        }

        let collapsedMic = FinalPassDiscipline.collapseRuns(micRun)
        #expect(collapsedMic.map(\.id) == [micRun[0].id])

        let result = policy.dedupe(final: [teamSegment] + collapsedMic)

        #expect(result.map(\.id) == [teamSegment.id])
    }

    /// ADR-003 asymmetry holds in batch: Team segments always pass, and the
    /// filter preserves the input's timeline order.
    @Test("Team segments are never suppressed and order is preserved")
    func teamSegmentsPassAndOrderIsPreserved() {
        let first = team("Can everyone see my screen now", start: 1.0, end: 2.5)
        let micReply = mic("Yes I can see it clearly on my side", start: 3.0, end: 5.0)
        let second = team("Yes I can see it clearly on my side", start: 3.2, end: 5.2)

        let result = policy.dedupe(final: [first, micReply, second])

        #expect(result.map(\.id) == [first.id, micReply.id, second.id])
    }
}
