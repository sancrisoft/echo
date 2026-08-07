//
//  EchoCancellationPrePassTests.swift
//  EchoTests
//
//  The probe's verdicts and the pre-pass's orchestration, on signals built
//  here in code: deterministic noise bursts, and delayed attenuated copies of
//  them standing in for echo. No meeting audio and no meeting text ever
//  reaches a test — real-audio validation happens through the env-gated
//  harnesses, which print locally and record nothing.
//
//  These are synthetic SIGNALS, not synthetic fixtures: the project rule
//  forbids passing generated audio off as a recording of anything. Nothing
//  here is written to the fixture set or presented as hardware. What is being
//  tested is arithmetic — a correlation peak lands where a delay was planted,
//  a length survives padding and trimming — and arithmetic is exactly what a
//  constructed signal can answer for.
//
//  The C++ engine is deliberately absent. Whether AEC3 cancels well is a
//  question about rooms and loudspeakers that only real recordings can
//  settle (and did, in AECOfflineSpikeTests); what belongs here is whether
//  the pre-pass feeds it correctly and stays out of the way when it fails.
//

import Foundation
import Testing
@testable import Echo

// MARK: - Signals

/// Deterministic pseudo-random noise. Seeded so a failure reproduces, and
/// hand-rolled so it cannot drift with the platform's generator.
private struct Noise {
    private var state: UInt64

    init(seed: UInt64) { state = seed | 1 }

    mutating func next() -> Float {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Float(Int32(truncatingIfNeeded: state >> 33)) / Float(Int32.max)
    }
}

private nonisolated enum Signal {

    static let rate = AudioConstants.sampleRate

    static func samples(seconds: Double) -> Int { Int(seconds * rate) }

    /// Speech-shaped enough for an envelope correlation to have something to
    /// lock onto: noise under a slow amplitude contour that alternates
    /// loudness the way talking does, rather than a constant hiss whose
    /// envelope is flat and correlates with nothing.
    static func modulatedNoise(seconds: Double, seed: UInt64, amplitude: Float = 0.2) -> [Float] {
        var noise = Noise(seed: seed)
        var contour = Noise(seed: seed &* 31 &+ 7)
        let count = samples(seconds: seconds)
        // A fresh level every 250 ms, held — syllable-rate, well above the
        // probe's 5 ms frames and well below its 10 s windows.
        let hold = samples(seconds: 0.25)
        var out = [Float](repeating: 0, count: count)
        var level: Float = 0
        for i in 0 ..< count {
            if i % hold == 0 { level = abs(contour.next()) }
            out[i] = noise.next() * level * amplitude
        }
        return out
    }

    /// `source` arriving `delaySeconds` later and `gain` quieter — a stand-in
    /// for bleed, with a little independent noise so the mic is never a
    /// mathematically perfect copy of the reference.
    static func echo(
        of source: [Float],
        delaySeconds: Double,
        gain: Float,
        noiseSeed: UInt64,
        noiseAmplitude: Float = 0.0005
    ) -> [Float] {
        var floor = Noise(seed: noiseSeed)
        let shift = samples(seconds: delaySeconds)
        return (0 ..< source.count).map { i in
            let delayed = i - shift >= 0 ? source[i - shift] * gain : 0
            return delayed + floor.next() * noiseAmplitude
        }
    }

    static func silence(seconds: Double) -> [Float] {
        [Float](repeating: 0, count: samples(seconds: seconds))
    }
}

/// Halves whatever it is given, so a test can tell the stage's output from
/// its input, and records what it saw. Stands in for the engine everywhere
/// the question is orchestration rather than cancellation.
private final class HalvingAECStage: AECStage, @unchecked Sendable {
    private(set) var micSamplesSeen = 0
    private(set) var farSamplesSeen = 0
    private(set) var resets = 0

    func processMicSamples(_ samples: [Float]) -> [Float] {
        micSamplesSeen += samples.count
        return samples.map { $0 * 0.5 }
    }

    func feedFarEnd(_ samples: [Float]) { farSamplesSeen += samples.count }

    func reset() { resets += 1 }
}

/// Drops every third chunk on the floor — the shape of a stage that
/// swallowed samples. The pre-pass must notice and keep the raw mic.
private final class SwallowingAECStage: AECStage, @unchecked Sendable {
    private var chunk = 0

    func processMicSamples(_ samples: [Float]) -> [Float] {
        chunk += 1
        return chunk % 3 == 0 ? [] : samples
    }

    func feedFarEnd(_ samples: [Float]) {}
    func reset() {}
}

// MARK: - Probe

struct EchoBleedProbeTests {

    @Test func firesOnAPlantedEchoAtThePlantedDelay() {
        let system = Signal.modulatedNoise(seconds: 60, seed: 11)
        let mic = Signal.echo(of: system, delaySeconds: 0.14, gain: 0.1, noiseSeed: 22)

        let verdict = try? #require(EchoBleedProbe.run(mic: mic, system: system))
        #expect(abs((verdict?.delaySeconds ?? 0) - 0.14) <= EchoBleedProbe.agreementSeconds)
        #expect((verdict?.coherence ?? 0) >= EchoBleedProbe.coherenceFloor)
        #expect((verdict?.bleedWindowStarts.count ?? 0) >= EchoBleedProbe.agreementCount)
    }

    @Test func findsTheDelayAcrossTheMeasuredRange() {
        // 125–180 ms is what the real routes measured; the ends of the search
        // range matter too, because an unfamiliar room lands somewhere else.
        for planted in [0.01, 0.125, 0.18, 0.3] {
            let system = Signal.modulatedNoise(seconds: 40, seed: 101)
            let mic = Signal.echo(of: system, delaySeconds: planted, gain: 0.15, noiseSeed: 202)
            let verdict = EchoBleedProbe.run(mic: mic, system: system)
            #expect(
                abs((verdict?.delaySeconds ?? -1) - planted) <= EchoBleedProbe.agreementSeconds,
                "planted \(planted)s, measured \(String(describing: verdict?.delaySeconds))"
            )
        }
    }

    @Test func staysSilentOnTwoUnrelatedChannels() {
        let system = Signal.modulatedNoise(seconds: 60, seed: 31)
        // Quiet enough to be bleed-shaped, but no relation to the reference:
        // the ratio test lets these windows through and the correlation is
        // what has to reject them.
        let mic = Signal.modulatedNoise(seconds: 60, seed: 47, amplitude: 0.01)

        #expect(EchoBleedProbe.run(mic: mic, system: system) == nil)
    }

    @Test func staysSilentWhenTheMicIsTheLoudOne() {
        // The user talking over quiet playback. Nothing here is bleed-shaped,
        // so there is nothing to measure however well the two correlate.
        let system = Signal.modulatedNoise(seconds: 60, seed: 53, amplitude: 0.02)
        let mic = Signal.echo(of: system, delaySeconds: 0.14, gain: 4, noiseSeed: 59)

        #expect(EchoBleedProbe.run(mic: mic, system: system) == nil)
    }

    @Test func staysSilentOnASilentMic() {
        let system = Signal.modulatedNoise(seconds: 60, seed: 61)
        #expect(EchoBleedProbe.run(mic: Signal.silence(seconds: 60), system: system) == nil)
    }

    @Test func staysSilentWhenTheReferenceIsNotPlaying() {
        // Below the reference floor on both sides: a meeting nobody's
        // speakers were part of has no echo path to find.
        let system = Signal.modulatedNoise(seconds: 60, seed: 67, amplitude: 0.002)
        let mic = Signal.echo(of: system, delaySeconds: 0.14, gain: 0.2, noiseSeed: 71)

        #expect(EchoBleedProbe.run(mic: mic, system: system) == nil)
    }

    @Test func staysSilentWhenOnlyOneWindowCouldAgree() {
        // 12 s: one whole window plus a remainder. A single window agreeing
        // with nothing is a coincidence, not an echo path.
        let system = Signal.modulatedNoise(seconds: 12, seed: 73)
        let mic = Signal.echo(of: system, delaySeconds: 0.14, gain: 0.1, noiseSeed: 79)

        #expect(EchoBleedProbe.run(mic: mic, system: system) == nil)
    }

    @Test func staysSilentOnAudioShorterThanOneWindow() {
        let system = Signal.modulatedNoise(seconds: 5, seed: 83)
        let mic = Signal.echo(of: system, delaySeconds: 0.14, gain: 0.1, noiseSeed: 89)

        #expect(EchoBleedProbe.run(mic: mic, system: system) == nil)
    }

    @Test func handlesEmptyChannels() {
        #expect(EchoBleedProbe.run(mic: [], system: []) == nil)
        #expect(EchoBleedProbe.run(mic: [], system: Signal.modulatedNoise(seconds: 30, seed: 97)) == nil)
    }

    // MARK: Pure helpers

    @Test func envelopeReducesEachFrameToItsMeanSquare() {
        let frame = Int(AudioConstants.sampleRate * EchoBleedProbe.frameSeconds)
        let envelope = EchoBleedProbe.envelope([Float](repeating: 0.5, count: frame * 3))
        #expect(envelope.count == 3)
        #expect(envelope.allSatisfy { abs($0 - 0.25) < 1e-9 })
    }

    @Test func envelopeDropsATrailingPartialFrame() {
        let frame = Int(AudioConstants.sampleRate * EchoBleedProbe.frameSeconds)
        #expect(EchoBleedProbe.envelope([Float](repeating: 0.5, count: frame * 2 + 7)).count == 2)
        #expect(EchoBleedProbe.envelope([Float](repeating: 0.5, count: frame - 1)).isEmpty)
    }

    @Test func correlationIsOneForACopyAndZeroForAFlatSlice() {
        let a: [Double] = [1, 4, 2, 8, 3, 9, 5]
        #expect(abs(EchoBleedProbe.correlation(a[...], a[...]) - 1) < 1e-9)
        // Scaling and offsetting leave the shape, which is all this measures.
        let scaled = a.map { $0 * 0.3 + 2 }
        #expect(abs(EchoBleedProbe.correlation(a[...], scaled[...]) - 1) < 1e-9)
        // A shape running the other way: -1, the far end of the scale.
        let ramp: [Double] = [1, 2, 3, 4, 5, 6, 7]
        let falling = Array(ramp.reversed())
        #expect(abs(EchoBleedProbe.correlation(ramp[...], falling[...]) + 1) < 1e-9)
        // No variance to explain — silence is absent evidence, not a match.
        let flat = [Double](repeating: 1, count: a.count)
        #expect(EchoBleedProbe.correlation(a[...], flat[...]) == 0)
    }

    @Test func spreadKeepsBothEndsAndThinsTheMiddle() {
        #expect(EchoBleedProbe.spread([0, 1, 2], to: 6) == [0, 1, 2])
        let picked = EchoBleedProbe.spread(Array(0 ..< 30), to: 6)
        #expect(picked.count == 6)
        #expect(picked.first == 0)
        #expect(picked.last == 29)
        #expect(picked == picked.sorted())
    }

    @Test func medianHandlesBothParities() {
        #expect(EchoBleedProbe.median([3, 1, 2]) == 2)
        #expect(EchoBleedProbe.median([4, 1, 3, 2]) == 2.5)
        #expect(EchoBleedProbe.median([]) == 0)
    }
}

// MARK: - Pre-pass

struct EchoCancellationPrePassTests {

    /// A pair the probe is known to fire on, so the orchestration rows below
    /// exercise the applied path rather than the identity shortcut.
    private static func echoingPair(seconds: Double = 60) -> (mic: [Float], system: [Float]) {
        let system = Signal.modulatedNoise(seconds: seconds, seed: 1_009)
        return (mic: Signal.echo(of: system, delaySeconds: 0.14, gain: 0.1, noiseSeed: 1_013), system: system)
    }

    @Test func returnsTheMicUntouchedWhenThereIsNoEchoPath() throws {
        let system = Signal.modulatedNoise(seconds: 40, seed: 1_019)
        let mic = Signal.modulatedNoise(seconds: 40, seed: 1_021, amplitude: 0.01)
        let stage = HalvingAECStage()

        let outcome = try EchoCancellationPrePass.run(mic: mic, system: system, stage: stage)

        #expect(!outcome.applied)
        #expect(outcome.mic == mic)
        #expect(outcome.erleDB == nil)
        // Nothing was fed: a pre-pass with no verdict must not cost a filter
        // run over the whole meeting either.
        #expect(stage.micSamplesSeen == 0)
    }

    @Test func returnsTheStagesOutputAtTheInputsLength() throws {
        // Deliberately not a multiple of the 160-sample frame: the padding
        // that keeps the two channels in step must not survive into the
        // output, or every timing downstream shifts.
        let pair = Self.echoingPair()
        let mic = Array(pair.mic.prefix(pair.mic.count - 37))
        let stage = HalvingAECStage()

        let outcome = try EchoCancellationPrePass.run(mic: mic, system: pair.system, stage: stage)

        #expect(outcome.applied)
        #expect(outcome.mic.count == mic.count)
        #expect(zip(outcome.mic, mic).allSatisfy { abs($0 - $1 * 0.5) < 1e-6 })
    }

    @Test func reportsWhatItMeasuredAndRemoved() throws {
        let pair = Self.echoingPair()
        let outcome = try EchoCancellationPrePass.run(
            mic: pair.mic, system: pair.system, stage: HalvingAECStage()
        )

        #expect(outcome.applied)
        #expect(abs((outcome.delaySeconds ?? 0) - 0.14) <= EchoBleedProbe.agreementSeconds)
        #expect(outcome.coherence >= EchoBleedProbe.coherenceFloor)
        // Halving amplitude removes three quarters of the energy: 6.02 dB.
        #expect(abs((outcome.erleDB ?? 0) - 6.02) < 0.1)
        #expect(outcome.summary.contains("applied"))
    }

    @Test func warmsUpBeforeTheKeptPass() throws {
        let pair = Self.echoingPair()
        let stage = HalvingAECStage()

        _ = try EchoCancellationPrePass.run(mic: pair.mic, system: pair.system, stage: stage)

        // The kept pass plus a 60 s prefix — the prefix capped at the
        // meeting's own length, which this 60 s pair is exactly.
        let frames = pair.mic.count / EchoCancellationPrePass.chunkSamples
        let expected = frames * EchoCancellationPrePass.chunkSamples * 2
        #expect(stage.micSamplesSeen == expected)
        #expect(stage.farSamplesSeen == expected)
    }

    @Test func warmUpNeverOutrunsAShortMeeting() throws {
        // 25 s: shorter than the 60 s warm-up, which must clamp rather than
        // read past the end of the buffers.
        let pair = Self.echoingPair(seconds: 25)
        let stage = HalvingAECStage()

        let outcome = try EchoCancellationPrePass.run(mic: pair.mic, system: pair.system, stage: stage)

        #expect(outcome.applied)
        #expect(outcome.mic.count == pair.mic.count)
        #expect(stage.micSamplesSeen <= pair.mic.count * 2 + EchoCancellationPrePass.chunkSamples * 2)
    }

    @Test func resetsTheStageSoBorrowedHistoryCannotShiftTheChannels() throws {
        let pair = Self.echoingPair()
        let stage = HalvingAECStage()

        _ = try EchoCancellationPrePass.run(mic: pair.mic, system: pair.system, stage: stage)

        #expect(stage.resets == 1)
    }

    @Test func feedsBothChannelsInLockstep() throws {
        let pair = Self.echoingPair()
        let stage = HalvingAECStage()

        _ = try EchoCancellationPrePass.run(mic: pair.mic, system: pair.system, stage: stage)

        #expect(stage.micSamplesSeen == stage.farSamplesSeen)
    }

    @Test func keepsTheRawMicWhenTheStageSwallowsSamples() throws {
        let pair = Self.echoingPair()

        let outcome = try EchoCancellationPrePass.run(
            mic: pair.mic, system: pair.system, stage: SwallowingAECStage()
        )

        #expect(!outcome.applied)
        #expect(outcome.mic == pair.mic)
    }

    @Test func keepsTheRawMicWhenTheEngineNeverCameUp() throws {
        // The real stage in the state a failed engine init leaves it in: it
        // passes mic audio through, so the pre-pass returns what it was given
        // and the pass proceeds exactly as it does today.
        let pair = Self.echoingPair()

        let outcome = try EchoCancellationPrePass.run(
            mic: pair.mic, system: pair.system, stage: WebRTCAECStage(failedEngine: ())
        )

        #expect(outcome.mic == pair.mic)
    }

    @Test func handlesAMissingChannel() throws {
        let system = Signal.modulatedNoise(seconds: 30, seed: 1_031)

        let noMic = try EchoCancellationPrePass.run(mic: [], system: system, stage: HalvingAECStage())
        #expect(!noMic.applied)
        #expect(noMic.mic.isEmpty)

        let noSystem = try EchoCancellationPrePass.run(mic: system, system: [], stage: HalvingAECStage())
        #expect(!noSystem.applied)
        #expect(noSystem.mic == system)
    }

    @Test func throwsPreemptedWhenARecordingStarts() {
        let pair = Self.echoingPair()

        #expect(throws: ParakeetPass.PassError.self) {
            try EchoCancellationPrePass.run(
                mic: pair.mic, system: pair.system,
                stage: HalvingAECStage(),
                shouldYield: { true }
            )
        }
    }

    @Test func doesNotCheckForPreemptionSoOftenThatItCostsMoreThanItSaves() throws {
        // The check is polled, not per-chunk: a whole meeting's worth of
        // 10 ms chunks would otherwise mean tens of thousands of calls.
        let pair = Self.echoingPair()
        let calls = Counter()

        _ = try EchoCancellationPrePass.run(
            mic: pair.mic, system: pair.system,
            stage: HalvingAECStage(),
            shouldYield: { calls.increment(); return false }
        )

        let chunks = pair.mic.count * 2 / EchoCancellationPrePass.chunkSamples
        #expect(calls.value <= chunks / EchoCancellationPrePass.yieldCheckChunks + 2)
    }

    @Test func erleIsNilWhenThereIsNothingToMeasure() {
        #expect(EchoCancellationPrePass.erleDB(input: [], output: [], windowStarts: []) == nil)
        #expect(EchoCancellationPrePass.erleDB(
            input: [0, 0, 0], output: [0, 0, 0], windowStarts: [0]
        ) == nil)
    }

    // MARK: - Near-end protection

    /// The field regression this guard exists for. On a real Discord meeting
    /// the filter took half the user's words out of every span the teammate
    /// was also speaking — AEC3 protects the far end, and suppresses whatever
    /// the near end was saying through double-talk.
    @Test func keepsTheRecordedMicWhereTheUsersOwnVoiceIsInIt() throws {
        let pair = Self.echoingPair()
        var mic = pair.mic
        // The user talking over the bleed for 5 s, at speech level against a
        // reference at 0.2 — a ratio no bleed path produces.
        let own = Signal.modulatedNoise(seconds: 5, seed: 2_027, amplitude: 0.6)
        let offset = Signal.samples(seconds: 30)
        for i in 0 ..< own.count { mic[offset + i] += own[i] }

        let outcome = try EchoCancellationPrePass.run(
            mic: mic, system: pair.system, stage: HalvingAECStage()
        )

        #expect(outcome.applied)
        // Roughly the 5 s in 60 that hold the user's voice, and nothing like
        // the whole meeting — a guard that protects everything cancels nothing.
        #expect(outcome.nearEndProtectedFraction > 0.02)
        #expect(outcome.nearEndProtectedFraction < 0.30)

        // Inside the stretch the recorded mic survives.
        let inside = offset ..< offset + own.count
        let kept = inside.filter { abs(outcome.mic[$0] - mic[$0]) < 1e-9 }.count
        #expect(Double(kept) / Double(own.count) > 0.5)

        // Outside it the filter still reaches every sample.
        let outside = 0 ..< Signal.samples(seconds: 20)
        #expect(outside.allSatisfy { abs(outcome.mic[$0] - mic[$0] * 0.5) < 1e-6 })
    }

    @Test func protectsNothingWhenTheMicCarriesOnlyBleed() throws {
        let pair = Self.echoingPair()

        let outcome = try EchoCancellationPrePass.run(
            mic: pair.mic, system: pair.system, stage: HalvingAECStage()
        )

        #expect(outcome.nearEndProtectedFraction == 0)
        #expect(outcome.summary.contains("near-end-kept=0%"))
    }

    /// An empty frame has no near end to protect, and treating it as one
    /// would hold the filter off the bleed on either side of it.
    @Test func silenceIsNotNearEnd() {
        let quiet = Signal.silence(seconds: 2)

        let result = EchoCancellationPrePass.protectingNearEnd(
            filtered: quiet, mic: quiet, system: quiet
        )

        #expect(result.protectedFraction == 0)
    }

    /// No reference playing means no bleed is possible, so there is nothing
    /// for the filter to be right about and the mic is kept as recorded.
    @Test func keepsTheRecordedMicWhereTheReferenceIsNotPlaying() {
        let mic = Signal.modulatedNoise(seconds: 2, seed: 2_029)
        let filtered = mic.map { $0 * 0.5 }

        let result = EchoCancellationPrePass.protectingNearEnd(
            filtered: filtered, mic: mic, system: Signal.silence(seconds: 2)
        )

        #expect(result.protectedFraction > 0.9)
    }
}

/// Call counter for the preemption row — a class so the escaping closure and
/// the test body see the same one.
private final class Counter: @unchecked Sendable {
    private(set) var value = 0
    func increment() { value += 1 }
}
