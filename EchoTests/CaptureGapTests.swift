//
//  CaptureGapTests.swift
//  EchoTests
//
//  SP-002 S6: capture-gap clock realignment ("input switch mid-recording").
//  The pipeline advances each channel's clock purely by ingested sample
//  count, so wall time in which a channel captured nothing (a device-switch
//  rebuild, a lost-device episode) would silently lag every later timestamp
//  on that channel — breaking SP-001's 100 ms cross-channel skew budget and
//  ADR-003's 2.5 s dedup timing gate. These tests drive the real public
//  ingest path (no Whisper model — gate-dropped silence never reaches the
//  transcriber) and observe the channel clock through the gate-diagnostics
//  records' chunk start offsets.
//
//  Constructed silence is legitimate here for the same reason it is in
//  GateDiagnosticsTests: the assertions are about clock arithmetic, not
//  audio realism. Constructed audio is never checked in as a fixture.
//

import Foundation
import Testing
@testable import Echo

struct CaptureGapTests {

    // MARK: - Helpers

    /// 100 ms ingest batches — realistic capture-callback cadence, and it
    /// divides every duration these tests use so chunk boundaries land
    /// exactly where the arithmetic says.
    private static let batchSamples = 1600

    private static func makePipeline() async -> (LiveInputMonitor, CollectingGateSink) {
        let sink = CollectingGateSink()
        let pipeline = LiveInputMonitor(gateDiagnostics: sink)
        return (pipeline, sink)
    }

    /// Feeds `seconds` of silence through the public ingest path in
    /// capture-sized batches. Silence endpoints deterministically: each full
    /// second of buffered audio finalizes as exactly one 1.0 s chunk.
    private static func ingestSilence(
        _ seconds: Double,
        into pipeline: LiveInputMonitor,
        on channel: AudioChannel
    ) async {
        let total = Int(seconds * AudioConstants.sampleRate)
        let batch = [Float](repeating: 0, count: batchSamples)
        var sent = 0
        while sent < total {
            let count = min(batchSamples, total - sent)
            await pipeline.ingest(count == batchSamples ? batch : Array(batch.prefix(count)), from: channel)
            sent += count
        }
    }

    private static func close(_ value: Double, _ expected: Double) -> Bool {
        abs(value - expected) < 0.001
    }

    // MARK: - Baseline (pins today's sample-count clock)

    /// With no gap ever declared, consecutive chunk records' start offsets
    /// advance by exactly the ingested durations — the sample-count clock
    /// this slice must leave byte-identical for sessions without device
    /// events.
    @Test func baselineOffsetsAdvanceByExactlyTheIngestedDurations() async {
        let (pipeline, sink) = await Self.makePipeline()

        await Self.ingestSilence(2.0, into: pipeline, on: .microphone)

        let records = sink.records
        #expect(records.count == 2)
        #expect(records.allSatisfy { Self.close($0.chunkDuration, 1.0) })
        let offsets = records.map(\.chunkStartOffset)
        #expect(offsets.count == 2)
        #expect(Self.close(offsets[0], 0.0))
        #expect(Self.close(offsets[1], 1.0))
    }

    // MARK: - Declared gaps

    /// A declared capture gap advances the channel clock: the first chunk
    /// after the gap starts at pre-gap end + gap, exactly where its audio
    /// sits on the wall-clock session timeline next to the other channel.
    @Test func declaredGapAdvancesTheChannelClock() async {
        let (pipeline, sink) = await Self.makePipeline()

        await Self.ingestSilence(1.0, into: pipeline, on: .microphone)
        await pipeline.noteCaptureGap(seconds: 0.7, on: .microphone)
        await Self.ingestSilence(1.0, into: pipeline, on: .microphone)

        let offsets = sink.records.map(\.chunkStartOffset)
        #expect(offsets.count == 2)
        #expect(Self.close(offsets[0], 0.0))
        #expect(Self.close(offsets[1], 1.7))
    }

    /// A mic-channel gap never moves the system channel's clock — the Team
    /// channel kept capturing through the mic outage, and realigning the mic
    /// against it only works if the reference itself never shifts.
    @Test func micChannelGapLeavesTheSystemChannelUntouched() async {
        let (pipeline, sink) = await Self.makePipeline()

        await Self.ingestSilence(1.0, into: pipeline, on: .microphone)
        await Self.ingestSilence(1.0, into: pipeline, on: .system)
        await pipeline.noteCaptureGap(seconds: 0.7, on: .microphone)
        await Self.ingestSilence(1.0, into: pipeline, on: .microphone)
        await Self.ingestSilence(1.0, into: pipeline, on: .system)

        let records = sink.records
        let systemOffsets = records.filter { $0.channel == .system }.map(\.chunkStartOffset)
        let micOffsets = records.filter { $0.channel == .microphone }.map(\.chunkStartOffset)
        #expect(systemOffsets.count == 2)
        #expect(Self.close(systemOffsets[0], 0.0))
        #expect(Self.close(systemOffsets[1], 1.0))
        #expect(micOffsets.count == 2)
        #expect(Self.close(micOffsets[1], 1.7))
    }

    /// Zero and negative gaps are ignored: only real dead time may move a
    /// clock, and a clock that never moves backward is what keeps segment
    /// timestamps monotonic (SP-002 "input switch mid-recording").
    @Test func zeroAndNegativeGapsAreNoOps() async {
        let (pipeline, sink) = await Self.makePipeline()

        await Self.ingestSilence(1.0, into: pipeline, on: .microphone)
        await pipeline.noteCaptureGap(seconds: 0, on: .microphone)
        await pipeline.noteCaptureGap(seconds: -0.5, on: .microphone)
        await Self.ingestSilence(1.0, into: pipeline, on: .microphone)

        let offsets = sink.records.map(\.chunkStartOffset)
        #expect(offsets.count == 2)
        #expect(Self.close(offsets[0], 0.0))
        #expect(Self.close(offsets[1], 1.0))
    }

    /// A gap declared while samples are pending (mic died mid-utterance)
    /// force-finalizes the pending audio as its own pre-gap chunk — with its
    /// pre-gap start and its honest sub-second duration — and the next chunk
    /// starts after the gap. Letting the pending buffer merge across the gap
    /// would hand Whisper one splice whose within-chunk timestamps place
    /// every post-gap word up to the full gap too early — exactly the
    /// mis-alignment ADR-003's 2.5 s timing gate cannot survive. The flush
    /// also proves declared gaps never lose pre-gap audio: it goes through
    /// the normal gate path (one record), like the end-of-session flush.
    @Test func midChunkGapFinalizesPendingAudioAtItsPreGapTime() async {
        let (pipeline, sink) = await Self.makePipeline()

        await Self.ingestSilence(0.5, into: pipeline, on: .microphone)
        #expect(sink.records.isEmpty)   // below minSamples: still pending

        await pipeline.noteCaptureGap(seconds: 0.7, on: .microphone)
        await Self.ingestSilence(1.0, into: pipeline, on: .microphone)

        let records = sink.records
        #expect(records.count == 2)
        #expect(Self.close(records[0].chunkStartOffset, 0.0))
        #expect(Self.close(records[0].chunkDuration, 0.5))
        #expect(Self.close(records[1].chunkStartOffset, 1.2))
        #expect(Self.close(records[1].chunkDuration, 1.0))
    }

    /// Gaps accumulate: every declared gap shifts the channel clock by its
    /// own duration, so repeated device switches realign cumulatively —
    /// the skew the sample-count clock would otherwise build up switch
    /// after switch. Covers both interleaved and back-to-back declarations.
    @Test func consecutiveGapsAccumulate() async {
        let (pipeline, sink) = await Self.makePipeline()

        await Self.ingestSilence(1.0, into: pipeline, on: .microphone)
        await pipeline.noteCaptureGap(seconds: 0.3, on: .microphone)
        await Self.ingestSilence(1.0, into: pipeline, on: .microphone)
        await pipeline.noteCaptureGap(seconds: 0.4, on: .microphone)
        await Self.ingestSilence(1.0, into: pipeline, on: .microphone)

        let offsets = sink.records.map(\.chunkStartOffset)
        #expect(offsets.count == 3)
        #expect(Self.close(offsets[0], 0.0))
        #expect(Self.close(offsets[1], 1.3))
        #expect(Self.close(offsets[2], 2.7))

        // Back-to-back declarations (a restart chain that never delivered in
        // between) sum the same way: 0.3 s + 0.4 s → shifted 0.7 s.
        let (backToBack, sink2) = await Self.makePipeline()
        await Self.ingestSilence(1.0, into: backToBack, on: .microphone)
        await backToBack.noteCaptureGap(seconds: 0.3, on: .microphone)
        await backToBack.noteCaptureGap(seconds: 0.4, on: .microphone)
        await Self.ingestSilence(1.0, into: backToBack, on: .microphone)

        let offsets2 = sink2.records.map(\.chunkStartOffset)
        #expect(offsets2.count == 2)
        #expect(Self.close(offsets2[1], 1.7))
    }

    /// Across ingest, declared gaps, mid-chunk flushes, rejected gaps, and
    /// the end-of-session flush, per-channel chunk timelines never move
    /// backward — each chunk starts at or after the previous chunk's end
    /// (SP-002: "keeps segment timestamps monotonic").
    @Test func offsetsNeverDecreaseAcrossGapsFlushesAndStop() async {
        let (pipeline, sink) = await Self.makePipeline()

        await Self.ingestSilence(1.0, into: pipeline, on: .microphone)
        await Self.ingestSilence(1.0, into: pipeline, on: .system)
        await pipeline.noteCaptureGap(seconds: 0.3, on: .microphone)
        await Self.ingestSilence(0.5, into: pipeline, on: .microphone)   // pending
        await pipeline.noteCaptureGap(seconds: 0.7, on: .microphone)     // mid-chunk flush
        await pipeline.noteCaptureGap(seconds: -1, on: .microphone)      // rejected
        await Self.ingestSilence(1.0, into: pipeline, on: .microphone)
        await Self.ingestSilence(1.5, into: pipeline, on: .system)
        await pipeline.stop()                                            // tail flush

        for channel in [AudioChannel.microphone, .system] {
            let records = sink.records.filter { $0.channel == channel }
            #expect(records.count >= 2)
            for (previous, next) in zip(records, records.dropFirst()) {
                #expect(
                    next.chunkStartOffset >= previous.chunkStartOffset + previous.chunkDuration - 0.001,
                    "\(channel) chunk at \(next.chunkStartOffset) overlaps one ending at \(previous.chunkStartOffset + previous.chunkDuration)"
                )
            }
        }
    }

    // MARK: - Permanent diagnostic line (US-12)

    /// The permanent log line carries the chunk's start offset, so a chunk's
    /// position on the session timeline — capture-gap realignment included —
    /// is reconstructable from the log alone. Numbers only (NFR Privacy).
    @Test func logLineCarriesTheChunkStartOffset() {
        let record = GateDecisionRecord(
            channel: .microphone,
            chunkDuration: 1.0,
            chunkStartOffset: 1.7,
            stats: AudioStats.compute(from: [Float](repeating: 0, count: 16_000))
        )

        #expect(OSLogGateDiagnosticsSink.line(for: record).contains("t=1.70s"))
    }

    // MARK: - Controller-side gap measurement (MicCaptureGapTracker)

    // The tracker is the honest no-hardware seam for RecordingController's
    // measurement: pure instant arithmetic, tested with injected
    // ContinuousClock instants (the live hot-plug path stays manual, per
    // SP-002's testing decisions — Core Audio churn can't be replayed).

    /// Steady delivery with no teardown episode never reports a gap — the
    /// zero-call guarantee that keeps sessions without device events
    /// byte-identical to today.
    @Test func trackerReportsNoGapDuringNormalDelivery() {
        let tracker = MicCaptureGapTracker()
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
        let tracker = MicCaptureGapTracker()
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
    /// clock realigns over the whole Team-only stretch.
    @Test func trackerFallsBackToTheEpisodeStartWhenTheMicNeverDelivered() {
        let tracker = MicCaptureGapTracker()
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
        let tracker = MicCaptureGapTracker()
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
        let tracker = MicCaptureGapTracker()
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
        let tracker = MicCaptureGapTracker()
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
