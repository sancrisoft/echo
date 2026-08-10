//
//  EchoCancellationPrePass.swift
//  Echo
//
//  Subtracts speaker bleed out of the retained mic before the pass decodes
//  it — offline, after the meeting, from the two channels already on disk.
//
//  It exists because the transcript-side defence cannot reach the bleed that
//  is left. Dedup deletes a row that duplicates a teammate's row; the silence
//  cutter splits a row at a pause the audio proves happened. Neither reaches
//  bleed that arrives WHILE the user is talking, with no pause to cut at and
//  no separable row to delete — measured at roughly 60% of what survives. The
//  worst case on record is a word whose reported time precedes the pause it
//  came after, welded to the user's sentence so that keeping the sentence
//  keeps the teammate's words with it. Only subtraction reaches that, and
//  subtraction has to happen before the tokens exist.
//
//  Running it offline rather than live is what makes it safe. There is no
//  live transcript to protect, no real-time deadline, no recording that could
//  be harmed if the engine misbehaves — and it works retroactively, through
//  Retry, on any meeting whose audio was retained. The live capture path, the
//  echo-handling mode machine and the route classifier are untouched.
//
//  The one property this must never violate: it produces cleaned mic audio or
//  the mic audio it was given, and it never fails the pass. Everything that
//  can go wrong — no verdict, a stage with no engine, a stage that returns
//  the wrong number of samples — lands on the input, unmodified. Subordinate
//  to transcription in exactly the way retention is subordinate to recording.
//

import Foundation
import os

nonisolated enum EchoCancellationPrePass {

    static let log = Logger(subsystem: "com.sancrisoft.Echo", category: "EchoCancellationPrePass")

    /// Off, because it deletes a fifth of the user's words wherever it runs and
    /// what it buys for them is inconsistent.
    ///
    /// Measured 2026-08-10 over every meeting on disk holding a kept pair —
    /// nine — replayed with this stage on and off, everything else equal. The
    /// probe fires on four and correctly skips the five with no speaker path,
    /// which are byte-identical either way. Where it does fire, the share of
    /// the user's own vocabulary that survives it, and the bleed-shaped
    /// seconds left in the mic rows:
    ///
    ///     1CB18219  215 ms   80%   34.1 s → 19.3 s
    ///     583FCA7D  278 ms   75%   29.8 s →  5.0 s
    ///     65B5A4C0  125 ms   84%   12.2 s → 12.1 s
    ///     E656A3F9  140 ms   77%    9.7 s → 15.1 s
    ///
    /// The price is steady — a fifth to a quarter of the user's words, against
    /// the ≥90% the plan set as its gate — while the return runs from most of
    /// the bleed gone to none of it to worse than before. Losing the user's
    /// own words is also the worse of the two failures: the summary is
    /// grounded in the transcript, so a word deleted here is gone from the
    /// notes, while surviving bleed is only misattributed — the words are
    /// still on the teammate's row and the summary still reads them.
    ///
    /// Nothing is deleted with the stage off: the probe, the engine and the
    /// near-end guard all stay, and `ECHO_AEC_PRE_PASS=1` runs them for the
    /// next measurement. Turn it back on when a sweep shows preservation
    /// clearing the gate — the near-end ratio is not the knob for that (see
    /// `nearEndRatioFloor`), the silence floor beneath it is the open lead.
    static var isEnabled: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.environment["ECHO_AEC_PRE_PASS"] == "1"
        #else
        return false
        #endif
    }

    /// 10 ms at 16 kHz (ADR-002) — the stage's own frame, and the cadence the
    /// two channels are interleaved at so the engine sees them the way the
    /// capture path would have.
    static let chunkSamples = 160

    /// How much audio the filter converges on before the kept pass starts.
    ///
    /// The live path accepts a hole at the start of a recording while the
    /// filter adapts; offline there is no reason to, because the same audio
    /// can be run twice. Two options were measured. A whole second pass —
    /// converge on the entire meeting, keep the second run — is worse than no
    /// warm-up at all: the seam hands the engine the end of the meeting
    /// followed by its beginning, and the delay estimator pays for the
    /// discontinuity. A 60 s prefix has no such seam and was the best of the
    /// three on the worst fixture (17.4 dB against 14.9 for no warm-up and
    /// 13.8 for the full pass).
    static let warmUpSeconds: TimeInterval = 60

    /// Preemption is checked this often, in chunks (≈1 s of audio). A
    /// recording that starts mid-pre-pass must not wait for the whole
    /// meeting to be filtered (ADR-014).
    static let yieldCheckChunks = 100

    /// Above this mic-to-system level ratio the frame holds the user's own
    /// voice, and the recorded mic is kept for it instead of the filtered one.
    ///
    /// The same discriminator, and the same measured number, the probe uses to
    /// pick its bleed windows and the dedup uses for Tier B: bleed arrives
    /// through a speaker and a room at 0.05–0.43 of the reference, the user's
    /// own voice at 0.52 and up. Nothing between the two was measured, which
    /// is why one constant serves all three.
    ///
    /// It exists because ERLE cannot tell subtraction from suppression. AEC3
    /// protects the far end, not the near one: through double-talk it gates
    /// whatever the mic is carrying, and on a real Discord meeting that cost
    /// half the user's words in every span the teammate was also speaking.
    /// Bounding the filter to bleed-shaped audio trades the double-talk
    /// residue — which dedup and the cutter still see — for never deleting
    /// speech only this stage can see.
    /// Lowering it protects MORE (the frame only has to clear a smaller share
    /// of the reference), at the cost of leaving more bleed behind — but
    /// measurably it is NOT the lever on word loss. Swept 0.50 → 0.05 over the
    /// E656 and 65B5 replays (2026-08-10), own-word preservation moved
    /// 0.622 → 0.671 and 0.820 → 0.848: a tenfold change in the threshold buys
    /// five points, nowhere near the ≥0.90 the plan asks for. The frames that
    /// carry the lost words fail `near >= EnergyEnvelope.silenceFloor`, not
    /// this ratio — on E656 the user's voice sits under the floor while the
    /// TV's bleed does not, which caps protection at 51% however low this
    /// goes. The floor, or the envelope under it, is where to look next.
    static var nearEndRatioFloor: Float {
        #if DEBUG
        // Measurement hook: sweep the guard against the replay fixtures
        // without a rebuild — TEST_RUNNER_ECHO_AEC_NEAR_END_RATIO=<float>
        // through xcodebuild. Unset everywhere else, including the app.
        if let raw = ProcessInfo.processInfo.environment["ECHO_AEC_NEAR_END_RATIO"],
           let override = Float(raw) {
            return override
        }
        #endif
        return defaultNearEndRatioFloor
    }

    static let defaultNearEndRatioFloor: Float = 0.5

    /// Levels are compared over this much either side of a frame. Raw 100 ms
    /// frames cross constantly inside ordinary speech — a syllable's decay
    /// dips under the other channel and back — so the same ±1 frame smoothing
    /// `EnergyEnvelope.longestDominantRun` uses applies here.
    static let nearEndSmoothingSeconds: TimeInterval = EnergyEnvelope.frameSeconds

    struct Outcome: Sendable {
        /// Cleaned, or the input untouched — always the input's length.
        var mic: [Float]
        /// Whether anything was subtracted at all.
        var applied: Bool
        var delaySeconds: TimeInterval?
        var coherence: Double
        /// Energy removed over the probe's bleed windows, in dB. Nil when
        /// nothing was applied.
        var erleDB: Double?
        /// Share of the meeting handed back as recorded because the user's own
        /// voice was in it. 1.0 would mean the filter reached nothing.
        var nearEndProtectedFraction: Double = 0

        /// Numbers only — a log line about a meeting may not carry its words.
        var summary: String {
            guard applied else { return "aec: skipped (no echo path measured)" }
            return String(
                format: "aec: applied delay=%.0fms coherence=%.2f erle=%.2fdB near-end-kept=%.0f%%",
                (delaySeconds ?? 0) * 1000, coherence, erleDB ?? 0,
                nearEndProtectedFraction * 100
            )
        }
    }

    /// The pre-pass. `stage` is the echo canceller to run the pair through
    /// (`WebRTCAECStage()` in production); it is reset first, so a stage with
    /// history behaves the same as a fresh one.
    ///
    /// Throws only `PassError.preempted`, and only when `shouldYield` asks
    /// for it. Every other failure returns the input unchanged.
    static func run(
        mic: [Float],
        system: [Float],
        stage: any AECStage,
        shouldYield: () -> Bool = { false }
    ) throws -> Outcome {
        let identity = Outcome(mic: mic, applied: false, delaySeconds: nil, coherence: 0, erleDB: nil)
        guard !mic.isEmpty, !system.isEmpty else { return identity }
        guard let verdict = EchoBleedProbe.run(mic: mic, system: system) else { return identity }

        // A caller's stage may carry adaptation state and a partial frame
        // from somewhere else; both would put the two channels out of step.
        stage.reset()

        // Whole frames only, so nothing is left in the stage's carry between
        // the warm-up and the kept pass — a stranded remainder would offset
        // the mic against the reference by up to 10 ms for the rest of the
        // meeting. The padding is trimmed back off the output.
        let padded = ((max(mic.count, system.count) + chunkSamples - 1) / chunkSamples) * chunkSamples
        var near = mic
        near.append(contentsOf: repeatElement(0, count: padded - mic.count))
        var far = system
        far.append(contentsOf: repeatElement(0, count: padded - system.count))

        // The far end is fed exactly as it was recorded. Pre-advancing it by
        // the measured delay — shrinking what the canceller has left to find
        // — sounds obviously right and measured worst of everything tried
        // (7.3 dB against 14.9 for feeding it straight): AEC3 does its own
        // alignment, and re-timing the input underneath it takes away the
        // headroom that alignment wants. The delay is used to decide THAT
        // there is an echo, not to reposition the reference.
        let warmUp = min(padded, (Int(warmUpSeconds * AudioConstants.sampleRate) / chunkSamples) * chunkSamples)
        _ = try feed(near: near, far: far, upTo: warmUp, through: stage, shouldYield: shouldYield)
        let cleaned = try feed(near: near, far: far, upTo: padded, through: stage, shouldYield: shouldYield)

        guard cleaned.count >= mic.count else {
            // A stage that swallowed samples has produced something this
            // can't align to the timeline. The raw mic still can be.
            ErrorTrace.record(
                "Echo pre-pass produced fewer samples than it was given — keeping the raw mic",
                category: "EchoCancellationPrePass",
                metadata: ["in": "\(mic.count)", "out": "\(cleaned.count)"]
            )
            return identity
        }

        let filtered = Array(cleaned.prefix(mic.count))
        let protectedMic = protectingNearEnd(filtered: filtered, mic: mic, system: system)
        let output = protectedMic.samples
        return Outcome(
            mic: output,
            applied: true,
            delaySeconds: verdict.delaySeconds,
            coherence: verdict.coherence,
            // Measured on what the pass will actually decode, so the number
            // reports the subtraction that survived the near-end guard rather
            // than the one the filter proposed.
            erleDB: erleDB(input: mic, output: output, windowStarts: verdict.bleedWindowStarts),
            nearEndProtectedFraction: protectedMic.protectedFraction
        )
    }

    // MARK: - Near-end protection

    /// The filtered mic where the audio is bleed-shaped, the recorded mic
    /// where the user's own voice is in it.
    ///
    /// The decision is per 100 ms frame and the two are crossfaded across a
    /// frame rather than spliced, because a step between two different
    /// versions of the same instant is a click, and a click is a token.
    static func protectingNearEnd(
        filtered: [Float],
        mic: [Float],
        system: [Float]
    ) -> (samples: [Float], protectedFraction: Double) {
        let frameSeconds = EnergyEnvelope.frameSeconds
        let samplesPerFrame = frameSeconds * AudioConstants.sampleRate
        let frames = max(1, Int((Double(mic.count) / samplesPerFrame).rounded(.up)))
        let micEnvelope = EnergyEnvelope(samples: mic)
        let systemEnvelope = EnergyEnvelope(samples: system)

        var keepRecorded = [Float](repeating: 0, count: frames)
        var protectedFrames = 0
        for index in 0 ..< frames {
            let start = Double(index) * frameSeconds
            let from = max(0, start - nearEndSmoothingSeconds)
            let to = start + frameSeconds + nearEndSmoothingSeconds
            let near = micEnvelope.rms(from: from, to: to) ?? 0
            let far = systemEnvelope.rms(from: from, to: to) ?? 0
            // Below the floor there is no near end to protect — an empty
            // frame must not hold the filter off the bleed around it. Above
            // it, no reference playing means no bleed is possible at all.
            let isNearEnd = near >= EnergyEnvelope.silenceFloor
                && (far <= 0 || near > nearEndRatioFloor * far)
            keepRecorded[index] = isNearEnd ? 1 : 0
            if isNearEnd { protectedFrames += 1 }
        }

        let fraction = Double(protectedFrames) / Double(frames)
        guard protectedFrames > 0 else { return (filtered, 0) }

        var output = filtered
        for i in 0 ..< min(output.count, mic.count) {
            // Frame decisions sit at frame centres; between two centres the
            // weight ramps, which is the crossfade.
            let position = Double(i) / samplesPerFrame - 0.5
            let lower = Int(position.rounded(.down))
            let a = keepRecorded[min(max(lower, 0), frames - 1)]
            let b = keepRecorded[min(max(lower + 1, 0), frames - 1)]
            // The flat stretches either side of a ramp stay bit-exact: this
            // stage must be able to hand back exactly what it was given.
            if a == b {
                if a == 1 { output[i] = mic[i] }
                continue
            }
            let weight = Float(position - Double(lower))
            let gain = a + (b - a) * weight
            output[i] = gain * mic[i] + (1 - gain) * filtered[i]
        }
        return (output, fraction)
    }

    // MARK: - Feeding

    /// Interleaves the pair through the stage in 10 ms chunks, far end first
    /// — the order the capture path uses, where the reference is copied from
    /// the system stream before its bleed reaches the mic.
    private static func feed(
        near: [Float],
        far: [Float],
        upTo end: Int,
        through stage: any AECStage,
        shouldYield: () -> Bool
    ) throws -> [Float] {
        var output: [Float] = []
        output.reserveCapacity(end)
        var offset = 0
        var sinceCheck = 0
        while offset < end {
            let upper = min(offset + chunkSamples, end)
            stage.feedFarEnd(Array(far[offset ..< upper]))
            output += stage.processMicSamples(Array(near[offset ..< upper]))
            offset = upper
            sinceCheck += 1
            if sinceCheck >= yieldCheckChunks {
                sinceCheck = 0
                if shouldYield() { throw ParakeetPass.PassError.preempted }
            }
        }
        return output
    }

    // MARK: - Measurement

    /// Energy removed over the given windows, in dB.
    ///
    /// Measured on the bleed windows and nowhere else. Over the whole file
    /// this number would be a fraction of a dB on any healthy result, because
    /// most of a meeting is the user's own voice — which the canceller must
    /// leave exactly where it is.
    static func erleDB(input: [Float], output: [Float], windowStarts: [TimeInterval]) -> Double? {
        let windowSamples = Int(EchoBleedProbe.windowSeconds * AudioConstants.sampleRate)
        var inEnergy = 0.0
        var outEnergy = 0.0
        for startSeconds in windowStarts {
            let first = max(0, Int(startSeconds * AudioConstants.sampleRate))
            let last = min(min(input.count, output.count), first + windowSamples)
            guard first < last else { continue }
            for i in first ..< last {
                inEnergy += Double(input[i]) * Double(input[i])
                outEnergy += Double(output[i]) * Double(output[i])
            }
        }
        guard inEnergy > 0, outEnergy > 0 else { return nil }
        return 10 * log10(inEnergy / outEnergy)
    }
}
