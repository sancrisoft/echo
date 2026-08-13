//
//  CaptureRateGuardTests.swift
//  EchoTests
//
//  BRN-006 defence 1: the declared sample rate, weighed against the wall
//  clock. A Bluetooth headset switching into call mode drops the output
//  device to 24 kHz while macOS keeps reporting 48 kHz, and a resampler built
//  on that claim converts the Team channel to half its real duration — the
//  double-speed recording.
//
//  The guard is the honest no-hardware seam for that measurement: pure
//  arithmetic over injected `ContinuousClock` instants and device sample
//  times, exactly like `CaptureGapTracker`'s tests. The live Bluetooth
//  profile switch stays manual — Core Audio's lie can't be replayed.
//
//  Constructed frame counts are legitimate here for the same reason they are
//  in CaptureGapTests: the assertions are about clock arithmetic, not audio.
//

import Foundation
import Testing
@testable import Echo

struct CaptureRateGuardTests {

    // MARK: - Helpers

    /// A fake capture stream. The wall clock and the device's sample clock
    /// advance together at the rate the hardware is *really* running at,
    /// while the guard is told whatever rate the device *declared* — which is
    /// the whole point: the two can disagree.
    private struct StreamSimulator {
        var rateGuard: CaptureRateGuard
        var now = ContinuousClock.Instant.now
        var deviceSampleTime: Double = 0
        var bufferFrames = 512

        /// Runs `seconds` of audio really clocked at `actualRate`.
        ///
        /// `delivering: false` models a tap that hands nothing over while the
        /// device clock keeps ticking underneath — an idle scoped tap, or an
        /// app that simply isn't playing. `deviceClock: false` models a device
        /// that publishes no valid sample time at all.
        @discardableResult
        mutating func run(
            seconds: TimeInterval,
            at actualRate: Double,
            delivering: Bool = true,
            deviceClock: Bool = true
        ) -> [CaptureRateGuard.Verdict] {
            var verdicts: [CaptureRateGuard.Verdict] = []
            let bufferSeconds = Double(bufferFrames) / actualRate
            var remaining = seconds
            while remaining > 0 {
                now = now.advanced(by: .seconds(bufferSeconds))
                deviceSampleTime += Double(bufferFrames)
                remaining -= bufferSeconds
                guard delivering else { continue }
                verdicts.append(rateGuard.observe(
                    frames: bufferFrames,
                    deviceSampleTime: deviceClock ? deviceSampleTime : nil,
                    at: now
                ))
            }
            return verdicts
        }
    }

    private func firstMismatch(_ verdicts: [CaptureRateGuard.Verdict]) -> Double? {
        for case .mismatch(let measured) in verdicts { return measured }
        return nil
    }

    private func containsMatch(_ verdicts: [CaptureRateGuard.Verdict]) -> Bool {
        verdicts.contains { if case .matches = $0 { return true } else { return false } }
    }

    // MARK: - The AirPods case

    /// The defect itself: the device declares 48 kHz and delivers 24 kHz. The
    /// wall clock sees half the audio it was promised, and the measurement
    /// names the real rate — which is what the resampler must be rebuilt on.
    @Test func halfRateDeliveryAgainstADeclared48kIsCaughtWithTheRealRate() {
        var simulator = StreamSimulator(rateGuard: CaptureRateGuard(declaredRate: 48_000))
        let verdicts = simulator.run(seconds: 3, at: 24_000)

        let measured = firstMismatch(verdicts)
        #expect(measured != nil)
        #expect(abs((measured ?? 0) - 24_000) < 240)          // within 1%
        #expect(CaptureRateGuard.snapped(measured ?? 0) == 24_000)
    }

    /// The classic HFP variant of the same defect — 16 kHz behind a 48 kHz
    /// claim, which plays back at triple speed.
    @Test func thirdRateDeliveryIsCaughtToo() {
        var simulator = StreamSimulator(rateGuard: CaptureRateGuard(declaredRate: 48_000))
        let verdicts = simulator.run(seconds: 3, at: 16_000)

        #expect(CaptureRateGuard.snapped(firstMismatch(verdicts) ?? 0) == 16_000)
    }

    // MARK: - Silence and never crying wolf

    /// The trap this design exists to avoid: a tap that delivers nothing
    /// while nobody is playing audio looks, to a naive frames-per-second
    /// count, exactly like a device running slow. Here two thirds of the
    /// stream is undelivered — a 3× "error" by that naive measure — and the
    /// guard stays silent, because the device clock says the missing audio
    /// was never captured rather than captured at the wrong rate.
    @Test func aTapThatDeliversNothingThroughSilenceIsNeverMistakenForAWrongRate() {
        var simulator = StreamSimulator(rateGuard: CaptureRateGuard(declaredRate: 48_000))
        var verdicts = simulator.run(seconds: 1, at: 48_000)
        verdicts += simulator.run(seconds: 4, at: 48_000, delivering: false)
        verdicts += simulator.run(seconds: 5, at: 48_000)

        #expect(firstMismatch(verdicts) == nil)
        // And the stream is judged again once it runs clean, so one silent
        // stretch doesn't disarm the guard for the rest of the meeting.
        #expect(containsMatch(verdicts))
    }

    /// Steady, honest delivery: the zero-correction guarantee that keeps
    /// every session on a well-behaved device byte-identical to today.
    @Test func steadyDeliveryAtTheDeclaredRateNeverReportsAMismatch() {
        var simulator = StreamSimulator(rateGuard: CaptureRateGuard(declaredRate: 48_000))
        let verdicts = simulator.run(seconds: 10, at: 48_000)

        #expect(firstMismatch(verdicts) == nil)
        #expect(containsMatch(verdicts))
    }

    /// The field case, and the one an earlier tolerance deliberately let
    /// through: 44.1 kHz behind a 48 kHz claim. Only 8.8% — no one hears it —
    /// but it costs the Team channel 8% of every meeting and compresses its
    /// whole timeline, which is exactly the damage this guard exists to stop.
    @Test func the44kAgainst48kLieIsCaught() {
        var simulator = StreamSimulator(rateGuard: CaptureRateGuard(declaredRate: 48_000))
        let verdicts = simulator.run(seconds: 6, at: 44_100)

        #expect(CaptureRateGuard.snapped(firstMismatch(verdicts) ?? 0) == 44_100)
    }

    /// The flip side of a tight tolerance: an honest device must never be
    /// "corrected". Real delivery jitters around the declared rate by far
    /// less than the band, so a truthful tap stays untouched.
    @Test func anHonestDeviceIsNeverCorrected() {
        for rate in [16_000.0, 44_100, 48_000, 96_000] {
            var simulator = StreamSimulator(rateGuard: CaptureRateGuard(declaredRate: rate))
            let verdicts = simulator.run(seconds: 8, at: rate)
            #expect(firstMismatch(verdicts) == nil, "\(rate) Hz was corrected against itself")
            #expect(containsMatch(verdicts))
        }
    }

    /// No device clock, no verdict. Losing the second clock costs the guard
    /// its ability to tell silence from slowness, so it declines to judge
    /// rather than risk correcting a rate that was right.
    @Test func withoutADeviceClockTheGuardNeverJudges() {
        var simulator = StreamSimulator(rateGuard: CaptureRateGuard(declaredRate: 48_000))
        let verdicts = simulator.run(seconds: 6, at: 24_000, deviceClock: false)

        #expect(verdicts.allSatisfy { $0 == .measuring })
    }

    /// A backwards jump in the device clock (a device restart, an aggregate
    /// reconfiguration) invalidates the window it lands in, even when the
    /// delivered audio would otherwise have looked like a rate error.
    @Test func aBackwardsDeviceClockJumpDiscardsItsWindow() {
        var rateGuard = CaptureRateGuard(declaredRate: 48_000)
        let t0 = ContinuousClock.Instant.now

        // Anchor, then a jump backwards, then two seconds of half-rate audio.
        _ = rateGuard.observe(frames: 512, deviceSampleTime: 100_000, at: t0)
        _ = rateGuard.observe(frames: 512, deviceSampleTime: 50_000, at: t0 + .seconds(0.02))
        let verdict = rateGuard.observe(frames: 512, deviceSampleTime: 98_000, at: t0 + .seconds(2.1))

        #expect(verdict == .measuring)
    }

    /// A window is judged on wall time, not on buffer count.
    @Test func aWindowShorterThanTheMeasurementWindowIsNeverJudged() {
        var simulator = StreamSimulator(rateGuard: CaptureRateGuard(declaredRate: 48_000))
        let verdicts = simulator.run(seconds: CaptureRateGuard.windowSeconds - 0.2, at: 24_000)

        #expect(verdicts.allSatisfy { $0 == .measuring })
    }

    // MARK: - Corrections

    /// A correction is self-confirming: once the guard is told the truth, the
    /// same stream agrees with it and nothing else is rebuilt.
    @Test func afterACorrectionTheSameStreamMatches() {
        var simulator = StreamSimulator(rateGuard: CaptureRateGuard(declaredRate: 48_000))
        _ = simulator.run(seconds: 3, at: 24_000)
        simulator.rateGuard.noteCorrection(to: 24_000)

        let verdicts = simulator.run(seconds: 6, at: 24_000)
        #expect(firstMismatch(verdicts) == nil)
        #expect(containsMatch(verdicts))
    }

    /// The correction budget is finite, so a device that oscillates can't
    /// have the converter rebuilt every two seconds for the whole meeting.
    @Test func theCorrectionBudgetRunsOut() {
        var rateGuard = CaptureRateGuard(declaredRate: 48_000)
        #expect(rateGuard.canCorrect)

        for _ in 0..<CaptureRateGuard.maxCorrections {
            rateGuard.noteCorrection(to: 24_000)
        }
        #expect(!rateGuard.canCorrect)
    }

    /// Snapping reports the rate the hardware actually runs at instead of one
    /// carrying two seconds of measurement noise — and leaves a measurement
    /// that matches no real rate alone rather than inventing one.
    @Test func snappingResolvesMeasurementNoiseButInventsNothing() {
        #expect(CaptureRateGuard.snapped(23_987.4) == 24_000)
        #expect(CaptureRateGuard.snapped(47_880) == 48_000)
        #expect(CaptureRateGuard.snapped(44_310) == 44_100)
        #expect(CaptureRateGuard.snapped(37_000) == 37_000)
    }
}
