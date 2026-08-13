//
//  CaptureRateGuard.swift
//  Echo
//
//  The sample rate a capture source declares, checked against the wall clock.
//

import Foundation

/// Measures how much audio a capture source *actually* delivers per second of
/// wall time and compares it against the sample rate that source declared.
///
/// Why this exists: with a Bluetooth headset (AirPods and friends) macOS drops
/// the output device to 24 kHz the moment the headset's microphone engages,
/// but for a while still *reports* 48 kHz — a known Core Audio defect (Apple
/// Developer Forums thread 770232, where the corrected rate only arrives later
/// as a `kAudioDevicePropertyStreamFormat` notification). A capture path that
/// reads the format once and believes it then converts 24 kHz audio as if it
/// were 48 kHz, throwing away half of it: the recording plays back at double
/// speed, an octave high, and the transcript is unusable. The declared rate
/// cannot be trusted. The wall clock can.
///
/// Cost: two additions and a comparison per capture callback, on numbers the
/// callback already holds. No timer, no polling, no thread of its own.
///
/// **Two clocks, not one.** Delivered frames alone would misread an idle tap —
/// a source that hands over nothing while nobody speaks looks exactly like a
/// source running at half rate. So every observation also carries the device's
/// own sample clock, and a window is judged only when both clocks agree that
/// the stream ran continuously through it. Silence, dropouts and clock jumps
/// make a window *inconclusive* rather than wrong: this guard's failure mode
/// is staying quiet, never correcting a rate that was right all along.
nonisolated struct CaptureRateGuard {

    /// What a completed observation window concluded.
    enum Verdict: Equatable {
        /// Window still filling, or it carried no continuous evidence. The
        /// steady-state answer, and the answer to every ambiguity.
        case measuring
        /// Delivery agreed with the declared rate.
        case matches(measured: Double)
        /// The declared rate is wrong by more than `tolerance`; `measured` is
        /// what the wall clock says the source is really running at.
        case mismatch(measured: Double)

        /// What the window measured, `nil` when it reached no conclusion.
        var measuredRate: Double? {
            switch self {
            case .measuring: return nil
            case .matches(let measured), .mismatch(let measured): return measured
            }
        }
    }

    /// Wall time a window must span before it is judged. Long enough that
    /// dispatch jitter is noise (a system tap delivers ~86 buffers in it),
    /// short enough that a bad rate is caught in the meeting's first seconds.
    static let windowSeconds: TimeInterval = 2

    /// How far measured delivery may sit from the declared rate.
    ///
    /// This was 10%, chosen to spare the 44.1-vs-48 kHz case (8.8% apart) on
    /// the assumption that the tap resamples that one itself. Field
    /// measurement killed the assumption: a Meet call delivered 512-frame
    /// cycles every 11.62 ms of wall time while declaring 48 kHz — a cycle
    /// carries 10.67 ms at that rate, so the tap was really running at 44.1
    /// and the Team channel came out 8% short of every meeting, with the
    /// guard watching it happen and calling it a match. The declared rate is
    /// not trustworthy at ANY magnitude of lie.
    ///
    /// 2% is far above what a judged window can drift — continuity is already
    /// enforced to 2% on the frame counts, and a 2 s window holds ~170 cycles
    /// — and far below the smallest real rate confusion (44.1 vs 48).
    static let tolerance = 0.02

    /// How far the two clocks may disagree before the window is thrown away.
    /// Only rounding and one boundary buffer should ever separate them.
    static let continuitySlack = 0.02

    /// Corrections one capture session will apply before leaving the rate
    /// alone. A correction is gapless and self-confirming — the next window
    /// compares against the new rate and should agree — so the only reason to
    /// cap is to stop an oscillating device from rebuilding the converter
    /// every two seconds forever.
    static let maxCorrections = 3

    /// Rates real audio hardware runs at, for snapping a measurement to the
    /// exact ratio the hardware uses instead of one carrying two seconds of
    /// measurement noise.
    static let standardRates: [Double] = [
        8_000, 11_025, 16_000, 22_050, 24_000, 32_000,
        44_100, 48_000, 88_200, 96_000, 176_400, 192_000,
    ]

    /// The rate the source claims — what the resampler is currently believing.
    private(set) var declaredRate: Double
    private(set) var correctionsApplied = 0

    private var windowStart: ContinuousClock.Instant?
    private var deliveredFrames = 0
    /// Frames the device's own clock advanced across this window.
    private var deviceFrames: Double = 0
    /// Device sample time of the previous observation, carried across windows
    /// so every window but the very first has a full set of deltas.
    private var lastDeviceSampleTime: Double?
    /// Cleared by anything that makes this window unjudgeable: a missing
    /// device clock, or a backwards jump in it.
    private var windowIsContinuous = true

    init(declaredRate: Double) {
        self.declaredRate = declaredRate
    }

    /// True while corrections are still allowed; the call site checks this
    /// before acting on a `.mismatch`.
    var canCorrect: Bool { correctionsApplied < Self.maxCorrections }

    /// Records one delivered buffer. `deviceSampleTime` is the capture
    /// timestamp's frame counter (`nil` when the device doesn't publish a
    /// valid one, which makes every window it touches inconclusive).
    mutating func observe(
        frames: Int,
        deviceSampleTime: Double?,
        at now: ContinuousClock.Instant
    ) -> Verdict {
        // Device-clock advance since the previous buffer. A backwards jump is
        // a discontinuity (device restart, aggregate reconfiguration), not a
        // measurement.
        if let deviceSampleTime {
            if let last = lastDeviceSampleTime {
                let advance = deviceSampleTime - last
                if advance >= 0 {
                    deviceFrames += advance
                } else {
                    windowIsContinuous = false
                }
            }
            lastDeviceSampleTime = deviceSampleTime
        } else {
            windowIsContinuous = false
        }

        // The first buffer only anchors the window: its audio was captured
        // before the window opened, so counting it would inflate the rate.
        guard let start = windowStart else {
            startWindow(at: now)
            return .measuring
        }

        deliveredFrames += frames

        let elapsed = Self.seconds(start.duration(to: now))
        guard elapsed >= Self.windowSeconds else { return .measuring }
        defer { startWindow(at: now) }

        // Both clocks must agree the stream ran unbroken. They disagree when
        // the tap delivered nothing through a silence, when buffers were
        // dropped, or when the device clock jumped — none of which say
        // anything about the sample rate.
        guard windowIsContinuous, deviceFrames > 0,
              abs(Double(deliveredFrames) - deviceFrames) <= deviceFrames * Self.continuitySlack
        else { return .measuring }

        let measured = Double(deliveredFrames) / elapsed
        guard declaredRate > 0 else { return .mismatch(measured: measured) }
        let ratio = measured / declaredRate
        return abs(ratio - 1) <= Self.tolerance
            ? .matches(measured: measured)
            : .mismatch(measured: measured)
    }

    /// Adopts `rate` as the new declared truth and starts measuring afresh
    /// against it.
    mutating func noteCorrection(to rate: Double) {
        declaredRate = rate
        correctionsApplied += 1
        windowStart = nil
        deliveredFrames = 0
        deviceFrames = 0
        windowIsContinuous = true
        // `lastDeviceSampleTime` deliberately survives: the device clock kept
        // running through the correction, so the next delta is still real.
    }

    /// The standard rate a measurement is clearly reporting, or the raw
    /// measurement when it matches none of them.
    static func snapped(_ measured: Double) -> Double {
        guard let nearest = standardRates.min(by: {
            abs($0 - measured) < abs($1 - measured)
        }) else { return measured }
        return abs(nearest - measured) <= nearest * 0.04 ? nearest : measured
    }

    private mutating func startWindow(at now: ContinuousClock.Instant) {
        windowStart = now
        deliveredFrames = 0
        deviceFrames = 0
        windowIsContinuous = true
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        let parts = duration.components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }
}
