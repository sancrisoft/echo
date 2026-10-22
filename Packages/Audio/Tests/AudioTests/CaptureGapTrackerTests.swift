//
//  CaptureGapTrackerTests.swift
//  AudioTests
//
//  Capture-gap measurement: the wall time in which one channel captured
//  nothing while the other kept running. The pipeline advances each channel's
//  clock purely by ingested sample count, so an undeclared hole would
//  silently lag every later timestamp on that channel — breaking the 100 ms
//  cross-channel skew budget and the dedup timing gate.
//
//  The tracker is the honest no-hardware seam for that measurement: pure
//  instant arithmetic over injected `ContinuousClock` instants, never elapsed
//  wall time (the live hot-plug path stays manual — Core Audio churn can't be
//  replayed). `ContinuousClock` and not `Date` because the gap feeds a clock
//  *correction*, so the measurement has to be monotonic.
//

import Audio
import Foundation
import Testing

struct CaptureGapTrackerTests {

    /// Steady delivery with no teardown episode never reports a gap — the
    /// zero-call guarantee that keeps sessions without device events
    /// byte-identical to today.
    @Test func trackerReportsNoGapDuringNormalDelivery() {
        let tracker = CaptureGapTracker()
        let t0 = ContinuousClock.Instant.now

        #expect(tracker.noteDelivery(batchDuration: 0.1, now: t0) == nil)
        #expect(tracker.noteDelivery(batchDuration: 0.1, now: t0 + .seconds(0.1)) == nil)
        #expect(tracker.noteDelivery(batchDuration: 0.1, now: t0 + .seconds(0.2)) == nil)
    }

    /// A quick device switch: teardown begins, the rebuilt engine's first
    /// batch closes the episode. The gap is the ingest-timeline hole — from
    /// the end of the last *delivered* audio (a torn-down tap drops its
    /// partially filled buffer, so undelivered tail audio is part of the
    /// hole) to the start of the first post-gap batch (its delivery instant
    /// minus its own duration).
    @Test func trackerMeasuresTheHoleFromLastDeliveredAudioToFirstNewAudio() {
        let tracker = CaptureGapTracker()
        let t0 = ContinuousClock.Instant.now

        _ = tracker.noteDelivery(batchDuration: 0.1, now: t0)
        _ = tracker.noteDelivery(batchDuration: 0.1, now: t0 + .seconds(0.1))
        tracker.beginEpisode(now: t0 + .seconds(0.15))
        let gap = tracker.noteDelivery(batchDuration: 0.05, now: t0 + .seconds(1.0))

        // Last delivered audio ended at t0+0.1; the new batch's audio began
        // at (t0+1.0) − 0.05: the hole is (1.0 − 0.05) − 0.1 = 0.85 s.
        #expect(gap != nil)
        #expect(abs((gap ?? 0) - 0.85) < 0.000_001)
    }

    /// A lost-device episode on a mic that never delivered — a session that
    /// starts degraded (no input device) and recovers when one appears. With
    /// no delivered audio to anchor on, the hole is measured from the
    /// episode's begin instant (the session's mic-silent start), so the mic
    /// clock realigns over the whole Others-only stretch.
    @Test func trackerFallsBackToTheEpisodeStartWhenTheMicNeverDelivered() {
        let tracker = CaptureGapTracker()
        let t0 = ContinuousClock.Instant.now

        tracker.beginEpisode(now: t0)
        let gap = tracker.noteDelivery(batchDuration: 0.2, now: t0 + .seconds(30.2))

        #expect(gap != nil)
        #expect(abs((gap ?? 0) - 30.0) < 0.000_001)
    }

    /// Overlapping begins with no delivery in between — a restart whose
    /// engine start failed, followed by another restart under device churn —
    /// are one continuous outage: the episode keeps the earliest teardown
    /// instant, so the whole outage measures as a single honest gap.
    @Test func overlappingBeginsMergeIntoOneEpisodeFromTheEarliestTeardown() {
        let tracker = CaptureGapTracker()
        let t0 = ContinuousClock.Instant.now

        tracker.beginEpisode(now: t0)
        tracker.beginEpisode(now: t0 + .seconds(5))
        let gap = tracker.noteDelivery(batchDuration: 0.2, now: t0 + .seconds(30.2))

        #expect(gap != nil)
        #expect(abs((gap ?? 0) - 30.0) < 0.000_001)
    }

    /// The first post-episode delivery closes the episode; every batch after
    /// it is steady state again — one gap declared per outage, never a
    /// trickle of re-declarations (which would over-advance the clock).
    @Test func episodeClosesOnceAndLaterDeliveriesReportNoGap() {
        let tracker = CaptureGapTracker()
        let t0 = ContinuousClock.Instant.now

        _ = tracker.noteDelivery(batchDuration: 0.1, now: t0)
        tracker.beginEpisode(now: t0 + .seconds(0.1))
        #expect(tracker.noteDelivery(batchDuration: 0.1, now: t0 + .seconds(1.0)) != nil)
        #expect(tracker.noteDelivery(batchDuration: 0.1, now: t0 + .seconds(1.1)) == nil)
        #expect(tracker.noteDelivery(batchDuration: 0.1, now: t0 + .seconds(1.2)) == nil)
    }

    /// An episode resolved faster than one batch duration measures no
    /// positive hole — nothing worth declaring. The tracker suppresses it
    /// rather than handing the pipeline a zero/negative gap to reject.
    @Test func nonPositiveMeasuredGapsAreSuppressed() {
        let tracker = CaptureGapTracker()
        let t0 = ContinuousClock.Instant.now

        _ = tracker.noteDelivery(batchDuration: 0.1, now: t0)
        tracker.beginEpisode(now: t0 + .seconds(0.01))
        // Elapsed since the last delivered audio: 0.05 s; this batch itself
        // covers 0.06 s of audio → hole of −0.01 s → suppressed.
        #expect(tracker.noteDelivery(batchDuration: 0.06, now: t0 + .seconds(0.05)) == nil)
        // And the episode is still consumed: steady state after.
        #expect(tracker.noteDelivery(batchDuration: 0.1, now: t0 + .seconds(0.15)) == nil)
    }
}
