//
//  SummaryBackfillPolicyTests.swift
//  EchoTests
//
//  The auto-summary gate's pure eligibility rule (§3.6): the newest-first
//  scan runs only while automatic summaries are on; an explicit user request
//  front-runs the scan and survives the toggle being off; the
//  transcript-about-to-change set defers both. Synthetic metas only.
//

import Foundation
import Testing
@testable import Echo

@Suite("Summary backfill policy — auto-summary gate")
struct SummaryBackfillPolicyTests {

    private func meta(_ id: UUID, hasSummary: Bool = false, age: TimeInterval = 0) -> MeetingMeta {
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000 - age)
        return MeetingMeta(
            id: id,
            title: "Meeting",
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(60),
            segmentCount: 1,
            hasSummary: hasSummary
        )
    }

    @Test func theScanPicksTheNewestSummarylessMeetingWhileOn() {
        let newest = UUID(), older = UUID()
        let picked = SummaryBackfillPolicy.nextMeeting(
            metas: [meta(newest, age: 0), meta(older, age: 100)],
            requestedID: nil,
            autoGenerateSummaries: true,
            failedIDs: [],
            ineligibleIDs: []
        )
        #expect(picked?.id == newest)
    }

    @Test func theScanIsSkippedWhileOff() {
        let picked = SummaryBackfillPolicy.nextMeeting(
            metas: [meta(UUID()), meta(UUID(), age: 100)],
            requestedID: nil,
            autoGenerateSummaries: false,
            failedIDs: [],
            ineligibleIDs: []
        )
        #expect(picked == nil)
    }

    /// The §3.6 exception: the manual "Generate summary" button keeps
    /// working with automatic summaries off.
    @Test func aRequestedMeetingIsHonoredWhileOff() {
        let requested = UUID()
        let picked = SummaryBackfillPolicy.nextMeeting(
            metas: [meta(UUID()), meta(requested, age: 100)],
            requestedID: requested,
            autoGenerateSummaries: false,
            failedIDs: [],
            ineligibleIDs: []
        )
        #expect(picked?.id == requested)
    }

    @Test func aRequestedMeetingFrontRunsTheScanWhileOn() {
        let requested = UUID()
        let picked = SummaryBackfillPolicy.nextMeeting(
            metas: [meta(UUID()), meta(requested, age: 100)],
            requestedID: requested,
            autoGenerateSummaries: true,
            failedIDs: [],
            ineligibleIDs: []
        )
        #expect(picked?.id == requested)
    }

    /// A request for a meeting whose transcript is about to change (pending
    /// finalization, or a queued re-transcribe) stays deferred — while ON the
    /// scan may still pick another meeting.
    @Test func anIneligibleRequestedMeetingIsDeferred() {
        let requested = UUID(), other = UUID()
        let picked = SummaryBackfillPolicy.nextMeeting(
            metas: [meta(requested), meta(other, age: 100)],
            requestedID: requested,
            autoGenerateSummaries: true,
            failedIDs: [],
            ineligibleIDs: [requested]
        )
        #expect(picked?.id == other)

        let pickedWhileOff = SummaryBackfillPolicy.nextMeeting(
            metas: [meta(requested)],
            requestedID: requested,
            autoGenerateSummaries: false,
            failedIDs: [],
            ineligibleIDs: [requested]
        )
        #expect(pickedWhileOff == nil)
    }

    @Test func failedThisRunIsSkippedByTheScanButNotByARequest() {
        let failed = UUID()
        let scanned = SummaryBackfillPolicy.nextMeeting(
            metas: [meta(failed)],
            requestedID: nil,
            autoGenerateSummaries: true,
            failedIDs: [failed],
            ineligibleIDs: []
        )
        #expect(scanned == nil)

        // `requestSummary(for:)` clears the failed mark before kicking the
        // backfill, but the policy itself must also never block an explicit
        // request on it.
        let requested = SummaryBackfillPolicy.nextMeeting(
            metas: [meta(failed)],
            requestedID: failed,
            autoGenerateSummaries: true,
            failedIDs: [failed],
            ineligibleIDs: []
        )
        #expect(requested?.id == failed)
    }

    @Test func meetingsWithSummariesAreNeverPicked() {
        let done = UUID()
        let picked = SummaryBackfillPolicy.nextMeeting(
            metas: [meta(done, hasSummary: true)],
            requestedID: done,
            autoGenerateSummaries: true,
            failedIDs: [],
            ineligibleIDs: []
        )
        #expect(picked == nil)
    }
}
