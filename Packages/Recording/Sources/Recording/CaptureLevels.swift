//
//  CaptureLevels.swift
//  Recording
//
//  The live level meter's numbers, and only the numbers: a channel's recent
//  real capture levels, windowed in SECONDS, and the amplitude a surface
//  renders from them. Nothing here simulates, animates or pre-averages —
//  `Audio` hands over one un-averaged reading per capture callback precisely
//  so the windowing can happen once, here, against a clock.
//
//  Ported from the PoC's `RecordingState`, which is where the two constants
//  and their reasons lived; the arithmetic and both measurements are
//  unchanged. What changed is the clock: `ContinuousClock` instead of `Date`,
//  for the reason `CaptureGapTracker` gives — a window is a duration
//  measurement, and wall-clock drifts and jumps would flatline a live meter
//  or freeze one that should have gone quiet. It also makes the cadence
//  drivable from a test without faking `Date`.
//

import Audio
import EchoCore
import Foundation
import Synchronization

/// One real capture level (0...1) and the instant it was measured.
///
/// The timestamp is the whole point. The two taps run at very different
/// cadences: the mic is an `AVAudioEngine` tap whose measured delivery is
/// 4800 frames — 100 ms of audio per callback — while system audio arrives on
/// the Core Audio IO proc at ~512 frames, ~10.67 ms per callback. A window
/// counted in *callbacks* therefore spans about ten times more audio on the
/// mic than on the system stream, which is exactly how the PoC's mic wave
/// ended up rendering an ~800 ms moving average — a line that swims at a
/// constant height no matter who is talking — next to a system wave tracking
/// ~90 ms. Windows over these are always measured in seconds.
struct LevelSample: Sendable, Equatable {
    let value: Double
    let at: ContinuousClock.Instant
}

/// One channel's recent levels, pruned to `levelWindow`, plus the amplitude
/// derived from them. A pure value: no clock of its own, every entry point
/// takes the instant, so the whole cadence is table-testable.
struct LevelWindow: Sendable, Equatable {

    /// How much *audio* the rendered amplitude averages over, per channel.
    ///
    /// Deliberately shorter than the mic tap's measured 100 ms callback
    /// interval, because averaging is pure latency on that channel: with a
    /// window wider than the cadence the mic wave renders the mean of the
    /// current reading and the previous one, i.e. audio up to 200 ms old, on
    /// top of the 100 ms the tap already costs to accumulate. Under the
    /// cadence, the mic falls through to its newest reading — the freshest
    /// thing that exists — while the ~10.67 ms system tap still averages
    /// several callbacks, which is what keeps that wave smooth rather than
    /// twitchy.
    static let levelWindow: TimeInterval = 0.06

    /// How long a channel may go without delivering before its wave drops to
    /// the resting line. Deliberately longer than `levelWindow`: a tap whose
    /// callback interval is itself longer than the window — the mic tap is
    /// ~100 ms at 48 kHz but ~256 ms on a 16 kHz device — must keep rendering
    /// its own newest reading between callbacks instead of flatlining. Only a
    /// channel that has genuinely stopped (the device disappeared) exceeds
    /// this.
    static let levelStaleAfter: TimeInterval = 0.5

    /// Light gain so ordinary speech reads as a visible wave rather than a
    /// tremble near the floor. Applied to the mean, never to a stored sample,
    /// so the recorded levels stay the measurement.
    private static let displayGain = 1.4

    private var samples: [LevelSample] = []

    init() {}

    /// Appends one measured level and drops everything that has aged out of
    /// `levelWindow` — pruning by AGE, never by count, which is what keeps
    /// the two very differently-paced taps comparable (see `LevelSample`).
    /// The buffer stays bounded by the window and the tap's own rate: a
    /// handful of samples on the system stream, exactly one on the mic.
    mutating func append(_ level: Double, at now: ContinuousClock.Instant) {
        samples.append(LevelSample(value: min(max(level, 0), 1), at: now))
        let cutoff = now - .seconds(Self.levelWindow)
        if let firstFresh = samples.firstIndex(where: { $0.at >= cutoff }), firstFresh > 0 {
            samples.removeFirst(firstFresh)
        }
    }

    /// Drops every sample. Called when a session ends, so an idle meter reads
    /// the resting line immediately instead of waiting out `levelStaleAfter`.
    mutating func reset() {
        samples.removeAll()
    }

    /// One display amplitude (0...1) from the channel's recent levels: the
    /// mean of the last `levelWindow` of audio, lightly gained. Entirely real
    /// capture data.
    ///
    /// Freshness is re-checked here rather than trusted from the last prune:
    /// a channel that stops delivering callbacks altogether (the mic device
    /// disappears mid-session) must fall back to the resting line instead of
    /// freezing at whatever it last measured. A channel that is merely slower
    /// than the window keeps rendering its newest reading — see
    /// `levelStaleAfter`.
    func amplitude(at now: ContinuousClock.Instant) -> Double {
        guard let newest = samples.last,
            newest.at.duration(to: now) <= .seconds(Self.levelStaleAfter)
        else { return 0 }
        let cutoff = now - .seconds(Self.levelWindow)
        let window = samples.filter { $0.at >= cutoff }
        let considered = window.isEmpty ? [newest] : window
        let mean = considered.reduce(0.0) { $0 + $1.value } / Double(considered.count)
        return min(1, mean * Self.displayGain)
    }
}

/// What a surface draws: one amplitude per channel, both from real capture.
///
/// `you` is the microphone and `others` is the system stream — speaker
/// attribution is the channel, never diarization, and it stays that way all
/// the way to the meter.
public struct CaptureLevels: Equatable, Sendable {

    public let you: Double
    public let others: Double

    public init(you: Double, others: Double) {
        self.you = you
        self.others = others
    }

    /// The resting line: nothing is being captured.
    public static let silent = CaptureLevels(you: 0, others: 0)
}

/// Counts the audio each channel actually handed to the pipeline, in frames.
/// Paired with `RetainedAudioWriter.Accounting` it answers the one question
/// the Others channel's missing seconds turn on: was the audio never
/// captured, captured but never written, or written after the file had
/// closed.
///
/// A `Mutex` rather than an actor for the reason `CaptureGapTracker` gives:
/// `add` runs on the AVAudioEngine render thread and the Core Audio IO queue,
/// which cannot afford a suspension point. One uncontended acquisition per
/// batch, on a number the callback already has.
final class ChannelFrameCounter: Sendable {

    private let frames = Mutex<[AudioChannel: Int]>([:])

    init() {}

    func add(_ count: Int, to channel: AudioChannel) {
        frames.withLock { $0[channel, default: 0] += count }
    }

    func seconds(_ channel: AudioChannel) -> TimeInterval {
        frames.withLock { Double($0[channel] ?? 0) / AudioConstants.sampleRate }
    }
}
