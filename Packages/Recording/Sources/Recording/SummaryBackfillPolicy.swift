//
//  SummaryBackfillPolicy.swift
//  Recording
//
//  Which meeting, if any, the summary scheduler works on next. Ported as-is
//  from the PoC, where it was the one part of the auto-summary gate that was
//  already pure and table-tested — and the only part: everything around it
//  lived inside a view.
//
//  All three triggers route through this one function, including the
//  automatic summary that follows a finalization, so the five-way rule has a
//  single implementation and the disk gate cannot disagree with itself.
//

import Foundation
import Meetings

/// The summary backfill's pure eligibility rule: an explicit user request
/// always front-runs — even while automatic summaries are OFF (the manual
/// "Generate summary" button must keep working) — and the newest-first scan
/// over summary-less meetings runs only while they're on. `ineligibleIDs` is
/// the transcript-about-to-change set (pending finalizations plus the
/// driver's queued and running passes); a requested meeting inside it stays
/// deferred exactly like a scanned one.
public enum SummaryBackfillPolicy {

    public static func nextMeeting(
        metas: [MeetingMeta],
        requestedID: UUID?,
        autoGenerateSummaries: Bool,
        failedIDs: Set<UUID>,
        ineligibleIDs: Set<UUID>
    ) -> MeetingMeta? {
        if let requestedID,
            let requested = metas.first(where: {
                $0.id == requestedID && !$0.hasSummary && !ineligibleIDs.contains($0.id)
            })
        {
            return requested
        }
        guard autoGenerateSummaries else { return nil }
        return metas.first {
            !$0.hasSummary && !failedIDs.contains($0.id) && !ineligibleIDs.contains($0.id)
        }
    }
}
