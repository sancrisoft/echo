//
//  CaptureGapTracker.swift
//  Audio
//
//  Wall time in which one channel captured nothing while the other kept
//  running. Recording opens an episode when it takes a channel down (a
//  device-switch rebuild on either side, lost-device degradation, or a
//  session that starts with no input device), and the first delivered batch
//  afterwards closes it; the measured gap is what keeps that channel's clock
//  wall-aligned with the other, and what retention writes as silence so the
//  retained timeline stays faithful.
//
//  An undeclared hole shifts every later timestamp on the channel earlier —
//  which is why the Others tap being deaf for its first seconds of bring-up
//  has to be declared rather than absorbed.
//
//  One instance per channel: the mic's rebuilds and the Others channel's
//  output-device rebuilds are separate outages on separate clocks.
//
//  `ContinuousClock` on purpose: the gap feeds a clock *correction*, so the
//  measurement must be monotonic — wall-clock `Date` drifts and jumps with
//  NTP and user changes.
//

import Foundation
import Synchronization

public final class CaptureGapTracker: Sendable {

    /// `noteDelivery` runs on the capture callback — the AVAudioEngine render
    /// thread for the microphone, the Core Audio IO queue for the system tap
    /// — while `beginEpisode` runs wherever Recording tears a channel down.
    /// A lock rather than an actor because the callback cannot afford a
    /// suspension point: the gap has to be known before the batch it belongs
    /// to is handed on, in the same callback. The per-batch cost is one
    /// uncontended lock acquisition.
    private struct State {
        /// Instant of the most recent delivered batch ≈ the end of the last
        /// audio that actually reached the pipeline (a tap delivers a buffer
        /// as soon as its last sample is captured).
        var lastDeliveryEnd: ContinuousClock.Instant?
        /// Set while the channel is (about to be) down; cleared by the
        /// delivery that closes the episode.
        var episodeStart: ContinuousClock.Instant?
    }

    private let state = Mutex(State())

    public init() {}

    /// Marks the channel as going down (engine or tap teardown, device lost,
    /// or a degraded no-device session start). Idempotent within an episode:
    /// with no delivery in between, chained teardowns (a failed restart
    /// followed by another under device churn) keep the earliest instant, so
    /// one continuous outage measures as one gap.
    public func beginEpisode(now: ContinuousClock.Instant = .now) {
        state.withLock { state in
            guard state.episodeStart == nil else { return }
            state.episodeStart = now
        }
    }

    /// Records one delivered batch (`batchDuration` seconds of audio ending
    /// at `now`). Returns the measured capture gap when this batch is the
    /// first after a pending episode, `nil` on the steady-state path.
    ///
    /// The gap is the ingest-timeline hole: from the end of the last
    /// *delivered* audio (a torn-down tap drops its partially filled buffer,
    /// so captured-but-undelivered audio is honestly part of the hole — and a
    /// device that died before its loss was noticed stopped delivering at
    /// death, not at the notice) to the start of this batch's audio, which
    /// began `batchDuration` before its delivery.
    public func noteDelivery(
        batchDuration: TimeInterval,
        now: ContinuousClock.Instant = .now
    ) -> TimeInterval? {
        state.withLock { state in
            let previousEnd = state.lastDeliveryEnd
            let episode = state.episodeStart
            state.lastDeliveryEnd = now
            state.episodeStart = nil
            guard let episode else { return nil }

            let holeStart = previousEnd ?? episode
            let gap = Self.seconds(holeStart.duration(to: now)) - batchDuration
            // An episode resolved within one batch left no positive hole in
            // the ingest timeline — nothing to declare.
            return gap > 0 ? gap : nil
        }
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        let parts = duration.components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }
}
