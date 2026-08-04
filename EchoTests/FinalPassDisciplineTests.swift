//
//  FinalPassDisciplineTests.swift
//  EchoTests
//
//  SP-007 S2: the final pass's decode discipline (ADR-019) and the per-window
//  language machinery's pure parts (ADR-020) as tables. The 2026-08-04
//  real-meeting failure geometry appears as explicit rows: the tail-pad
//  `end < start` construction, the exhausted-fallback repetition window, and
//  the hallucination train over in-window silence.
//

import Testing
import WhisperKit
@testable import Echo

/// Raw Whisper segment factory: window-relative times, healthy metrics by
/// default so each row varies only the dimension under test.
private func rawSegment(
    _ text: String = "some real words here",
    start: Float,
    end: Float,
    avgLogprob: Float = -0.2,
    compressionRatio: Float = 1.3
) -> TranscriptionSegment {
    TranscriptionSegment(
        start: start,
        end: end,
        text: text,
        avgLogprob: avgLogprob,
        compressionRatio: compressionRatio
    )
}

@Suite("FinalPassDiscipline (SP-007 S2)")
struct FinalPassDisciplineTests {

    // MARK: - Tail-pad hygiene (ADR-019 rule 4)

    @Suite("FinalPassDiscipline — tail-pad hygiene")
    struct TailPadHygieneTests {

        @Test("a segment fully inside the real audio passes unchanged")
        func insideRealAudioPasses() {
            let segment = rawSegment(start: 2.0, end: 6.0)
            let result = FinalPassDiscipline.tailPadHygiene([segment], windowDuration: 30.0)
            #expect(result.count == 1)
            #expect(result[0].start == 2.0)
            #expect(result[0].end == 6.0)
        }

        @Test("a segment starting exactly at the window's real-audio end is dropped")
        func startAtBoundaryDrops() {
            let segment = rawSegment(start: 30.0, end: 31.2)
            #expect(FinalPassDiscipline.tailPadHygiene([segment], windowDuration: 30.0).isEmpty)
        }

        /// The real-meeting construction (2026-08-04): window real audio ended at
        /// 264.68 s absolute (24.68 s window-relative); Whisper emitted segments
        /// starting at 272.66+ absolute — inside the pad, extrapolated. The old
        /// end-only clamp persisted them with `end < start`. They must drop.
        @Test("a segment born in the tail pad is dropped, never end-clamped into end < start")
        func padBornSegmentDrops() {
            let padBorn = rawSegment(start: 32.66, end: 33.5)
            let result = FinalPassDiscipline.tailPadHygiene([padBorn], windowDuration: 24.68)
            #expect(result.isEmpty)
        }

        @Test("a segment bleeding into the pad keeps its end clamped to the window boundary")
        func padBleedClampsEnd() {
            let bleeding = rawSegment(start: 28.0, end: 31.2)
            let result = FinalPassDiscipline.tailPadHygiene([bleeding], windowDuration: 30.0)
            #expect(result.count == 1)
            #expect(result[0].start == 28.0)
            #expect(result[0].end == 30.0)
        }

        @Test("a zero-duration segment is dropped even inside the real audio")
        func zeroDurationDrops() {
            let zero = rawSegment(start: 5.0, end: 5.0)
            #expect(FinalPassDiscipline.tailPadHygiene([zero], windowDuration: 30.0).isEmpty)
        }

        @Test("a raw negative-duration segment is dropped")
        func negativeDurationDrops() {
            let negative = rawSegment(start: 6.0, end: 4.0)
            #expect(FinalPassDiscipline.tailPadHygiene([negative], windowDuration: 30.0).isEmpty)
        }

        @Test("no output segment can violate end > start, whatever the input geometry")
        func noMalformedOutput() {
            let inputs = [
                rawSegment(start: 0.0, end: 3.0),
                rawSegment(start: 24.5, end: 26.1),   // clamps to 24.68
                rawSegment(start: 24.68, end: 25.0),  // born at the boundary
                rawSegment(start: 29.9, end: 29.9),   // zero duration in the pad
                rawSegment(start: 32.66, end: 33.5),  // pad-born
            ]
            let result = FinalPassDiscipline.tailPadHygiene(inputs, windowDuration: 24.68)
            #expect(result.allSatisfy { $0.end > $0.start })
            #expect(result.allSatisfy { $0.start < 24.68 })
            #expect(result.count == 2)
        }
    }

    // MARK: - Rejection after exhausted fallback (ADR-019 rule 1)

    @Suite("FinalPassDiscipline — rejection over acceptance")
    struct QualityRejectionTests {

        @Test("the thresholds are the live decode options' calibrated numbers, not new constants")
        func thresholdsMirrorLiveOptions() {
            #expect(FinalPassDiscipline.compressionRatioThreshold
                == TranscriptionPipeline.liveDecodeOptions.compressionRatioThreshold)
            #expect(FinalPassDiscipline.logProbThreshold
                == TranscriptionPipeline.liveDecodeOptions.logProbThreshold)
            #expect(FinalPassDiscipline.compressionRatioThreshold == 2.2)
            #expect(FinalPassDiscipline.logProbThreshold == -0.75)
        }

        @Test("a segment with healthy final-attempt metrics passes")
        func healthyMetricsPass() {
            #expect(FinalPassDiscipline.passesQualityThresholds(
                rawSegment(start: 0, end: 2, avgLogprob: -0.2, compressionRatio: 1.4)))
        }

        @Test("a segment whose avgLogprob still fails after fallback is rejected")
        func lowLogprobFails() {
            #expect(!FinalPassDiscipline.passesQualityThresholds(
                rawSegment(start: 0, end: 2, avgLogprob: -0.9, compressionRatio: 1.4)))
        }

        @Test("a repetition loop's compression ratio fails the segment")
        func highCompressionRatioFails() {
            #expect(!FinalPassDiscipline.passesQualityThresholds(
                rawSegment(start: 0, end: 2, avgLogprob: -0.2, compressionRatio: 2.5)))
        }

        @Test("threshold boundaries pass — WhisperKit flags strictly beyond them")
        func boundariesPass() {
            #expect(FinalPassDiscipline.passesQualityThresholds(
                rawSegment(start: 0, end: 2, avgLogprob: -0.75, compressionRatio: 2.2)))
        }

        /// The "eh, eh, eh…" window: every retry still failed, so the window
        /// contributes NO text — an honest gap, never the last (worst) attempt.
        @Test("a window whose every segment fails contributes nothing")
        func allFailingWindowIsEmpty() {
            let exhausted = [
                rawSegment("eh, eh, eh, eh", start: 0, end: 8, avgLogprob: -1.4, compressionRatio: 3.1),
                rawSegment("eh, eh, eh, eh", start: 8, end: 16, avgLogprob: -1.2, compressionRatio: 2.8),
            ]
            #expect(FinalPassDiscipline.rejectFailingSegments(exhausted).isEmpty)
        }

        @Test("a mixed window keeps only the passing segments")
        func mixedWindowKeepsPassing() {
            let good = rawSegment("we agreed on the rollout", start: 0, end: 3)
            let bad = rawSegment("el, ah, el, ah", start: 3, end: 6, avgLogprob: -1.5, compressionRatio: 3.0)
            let result = FinalPassDiscipline.rejectFailingSegments([good, bad])
            #expect(result.map(\.text) == [good.text])
        }

        @Test("quality flagging: any failing segment flags the window; a clean window is unflagged")
        func flaggingRows() {
            let good = rawSegment(start: 0, end: 3)
            let bad = rawSegment(start: 3, end: 6, avgLogprob: -1.5)
            #expect(FinalPassDiscipline.isQualityFlagged([good, bad]))
            #expect(!FinalPassDiscipline.isQualityFlagged([good]))
            #expect(!FinalPassDiscipline.isQualityFlagged([]))
        }
    }

    // MARK: - Run collapse (ADR-019 rule 3)

    @Suite("FinalPassDiscipline — run collapse")
    struct RunCollapseTests {

        private func segment(
            _ text: String,
            start: Double,
            channel: AudioChannel = .system
        ) -> TranscriptSegment {
            TranscriptSegment(
                channel: channel,
                speaker: channel == .microphone ? .me : .teammates,
                text: text,
                start: start,
                end: start + 0.4
            )
        }

        @Test("the run-length constant is three")
        func runLengthIsThree() {
            #expect(FinalPassDiscipline.runCollapseLength == 3)
        }

        /// The 40-fold "el, ah, el, ah…" loop from the real meeting: one survivor,
        /// carrying the FIRST run member's timestamps (the dedup timing anchor).
        @Test("a 40-fold near-identical run collapses to its first member")
        func fortyFoldRunCollapsesToFirst() {
            let run = (0..<40).map { segment("el, ah, el, ah", start: 10.0 + Double($0) * 0.5) }
            let result = FinalPassDiscipline.collapseRuns(run)
            #expect(result.count == 1)
            #expect(result[0].id == run[0].id)
            #expect(result[0].start == 10.0)
            #expect(result[0].end == 10.4)
        }

        @Test("a run of two survives intact")
        func runOfTwoSurvives() {
            let pair = [segment("okay", start: 1.0), segment("okay", start: 2.0)]
            #expect(FinalPassDiscipline.collapseRuns(pair).map(\.id) == pair.map(\.id))
        }

        @Test("a run of exactly three collapses")
        func runOfThreeCollapses() {
            let run = (0..<3).map { segment("gracias", start: Double($0)) }
            let result = FinalPassDiscipline.collapseRuns(run)
            #expect(result.map(\.id) == [run[0].id])
        }

        @Test("case and punctuation variants are near-identical and collapse together")
        func caseAndPunctuationVariantsCollapse() {
            let run = [
                segment("Eh, eh, eh.", start: 0.0),
                segment("eh eh eh", start: 1.0),
                segment("EH... EH... EH!", start: 2.0),
            ]
            let result = FinalPassDiscipline.collapseRuns(run)
            #expect(result.count == 1)
            #expect(result[0].text == "Eh, eh, eh.")
        }

        @Test("interrupted repetitions are separate short runs and survive")
        func interruptedRunsSurvive() {
            let segments = [
                segment("right", start: 0.0),
                segment("right", start: 1.0),
                segment("let me check the logs", start: 2.0),
                segment("right", start: 3.0),
                segment("right", start: 4.0),
            ]
            #expect(FinalPassDiscipline.collapseRuns(segments).map(\.id) == segments.map(\.id))
        }

        @Test("segments around a collapsed run survive in order")
        func neighborsSurviveCollapse() {
            let before = segment("the deploy finished", start: 0.0)
            let run = (0..<5).map { segment("gracias", start: 1.0 + Double($0)) }
            let after = segment("so we can close the ticket", start: 7.0)
            let result = FinalPassDiscipline.collapseRuns([before] + run + [after])
            #expect(result.map(\.id) == [before.id, run[0].id, after.id])
        }
    }

    // MARK: - Empty-output guard (ADR-019)

    @Suite("FinalPassDiscipline — empty-output guard")
    struct EmptyOutputGuardTests {

        @Test("speech regions existed and everything was dropped — the pass must fail (floor stands)")
        func regionsAndEmptyOutputFails() {
            #expect(FinalPassDiscipline.emptyOutputIsFailure(regionsSelected: true, outputEmpty: true))
        }

        @Test("no speech regions anywhere — empty output is a legitimate success")
        func noRegionsEmptyOutputSucceeds() {
            #expect(!FinalPassDiscipline.emptyOutputIsFailure(regionsSelected: false, outputEmpty: true))
        }

        @Test("non-empty output is never a guard failure")
        func nonEmptyOutputNeverFails() {
            #expect(!FinalPassDiscipline.emptyOutputIsFailure(regionsSelected: true, outputEmpty: false))
            #expect(!FinalPassDiscipline.emptyOutputIsFailure(regionsSelected: false, outputEmpty: false))
        }
    }

    // MARK: - ADR-020 pure parts: chain reset, alternate language, A/B verdict

    @Suite("FinalPassDiscipline — language change resets the prompt chain")
    struct ChainResetTests {

        @Test("the first window of a channel never resets")
        func firstWindowNeverResets() {
            #expect(!FinalPassDiscipline.shouldResetChain(previousLanguage: nil, windowLanguage: "en"))
        }

        @Test("the same language carries the chain")
        func sameLanguageCarries() {
            #expect(!FinalPassDiscipline.shouldResetChain(previousLanguage: "es", windowLanguage: "es"))
        }

        @Test("a language change resets the chain — prior text in another language never conditions the decode")
        func languageChangeResets() {
            #expect(FinalPassDiscipline.shouldResetChain(previousLanguage: "en", windowLanguage: "es"))
            #expect(FinalPassDiscipline.shouldResetChain(previousLanguage: "es", windowLanguage: "en"))
        }
    }

    @Suite("FinalPassDiscipline — alternate whitelist language")
    struct AlternateLanguageTests {

        @Test("the alternate of each whitelist language is the other one")
        func alternateIsTheOtherLanguage() {
            #expect(FinalPassDiscipline.alternateWhitelistLanguage(to: "en") == "es")
            #expect(FinalPassDiscipline.alternateWhitelistLanguage(to: "es") == "en")
        }
    }

    @Suite("FinalPassDiscipline — A/B re-decode verdict")
    struct ABVerdictTests {

        @Test("the alternate wins on better mean avgLogprob")
        func alternateWinsOnConfidence() {
            let primary = [
                rawSegment(start: 0, end: 3, avgLogprob: -0.9),
                rawSegment(start: 3, end: 6, avgLogprob: -1.1),
            ]
            let alternate = [rawSegment(start: 0, end: 6, avgLogprob: -0.4)]
            #expect(FinalPassDiscipline.abChoice(primary: primary, alternate: alternate) == .alternate)
        }

        @Test("the primary wins on better mean avgLogprob")
        func primaryWinsOnConfidence() {
            let primary = [rawSegment(start: 0, end: 6, avgLogprob: -0.3)]
            let alternate = [rawSegment(start: 0, end: 6, avgLogprob: -0.8)]
            #expect(FinalPassDiscipline.abChoice(primary: primary, alternate: alternate) == .primary)
        }

        @Test("a tie keeps the primary")
        func tieKeepsPrimary() {
            let primary = [rawSegment(start: 0, end: 6, avgLogprob: -0.5)]
            let alternate = [rawSegment(start: 0, end: 6, avgLogprob: -0.5)]
            #expect(FinalPassDiscipline.abChoice(primary: primary, alternate: alternate) == .primary)
        }

        @Test("an empty alternate can never win")
        func emptyAlternateLoses() {
            let primary = [rawSegment(start: 0, end: 6, avgLogprob: -1.5)]
            #expect(FinalPassDiscipline.abChoice(primary: primary, alternate: []) == .primary)
        }

        @Test("an empty primary loses to any alternate output")
        func emptyPrimaryLosesToAnyAlternate() {
            let alternate = [rawSegment(start: 0, end: 6, avgLogprob: -1.2)]
            #expect(FinalPassDiscipline.abChoice(primary: [], alternate: alternate) == .alternate)
        }

        @Test("both empty keeps the primary")
        func bothEmptyKeepsPrimary() {
            #expect(FinalPassDiscipline.abChoice(primary: [], alternate: []) == .primary)
        }
    }

    // MARK: - Per-segment energy evidence (ADR-019 rule 2)

    /// A synthetic 30 s decode window with speech-shaped audio in the first half
    /// and digital silence in the second — the exact geometry of the 2026-08-04
    /// hallucination train: whole-window stats pass the gates (speech exists
    /// somewhere), so only per-segment evidence can catch text over the silence.
    private enum SyntheticWindow {

        /// 100 ms sine bursts (amplitude 0.5) every 300 ms: bursty and dynamic
        /// enough to clear every clear-speech gate term on any slice inside the
        /// voiced half (rms ≈ 0.2, crest ≈ 2.4, speech-window ratio ≈ 0.33).
        static func speechThenSilence(speechSeconds: Double = 15, silenceSeconds: Double = 15) -> [Float] {
            let rate = AudioConstants.sampleRate
            let burst = Int(0.1 * rate)
            let period = Int(0.3 * rate)
            let speechCount = Int(speechSeconds * rate)
            var samples = [Float]()
            samples.reserveCapacity(speechCount + Int(silenceSeconds * rate))
            for i in 0..<speechCount {
                let inBurst = (i % period) < burst
                samples.append(inBurst ? 0.5 * sin(Float(i) * 2 * .pi * 220 / Float(rate)) : 0)
            }
            samples.append(contentsOf: [Float](repeating: 0, count: Int(silenceSeconds * rate)))
            return samples
        }
    }

    @Suite("Per-segment evidence — energy stats sliced from the segment's own span")
    struct PerSegmentEvidenceTests {

        private let window = SyntheticWindow.speechThenSilence()

        @Test("a segment spanning the voiced span keeps, with recording-relative timestamps")
        func voicedSegmentKeeps() {
            let segment = rawSegment("we will ship the new build on friday", start: 2.0, end: 6.0)
            let result = TranscriptionPipeline.evidenceJudgedSegments(
                from: [segment], channel: .system, offset: 120.0, windowSamples: window)
            #expect(result.count == 1)
            #expect(result[0].text == "we will ship the new build on friday")
            #expect(result[0].start == 122.0)
            #expect(result[0].end == 126.0)
        }

        @Test("a hallucination over the in-window silence drops even with pristine decode metrics")
        func silenceHallucinationDrops() {
            let hallucination = rawSegment(
                "Gracias.", start: 20.0, end: 24.0, avgLogprob: -0.1, compressionRatio: 1.1)
            let result = TranscriptionPipeline.evidenceJudgedSegments(
                from: [hallucination], channel: .microphone, offset: 0, windowSamples: window)
            #expect(result.isEmpty)
        }

        /// The defeat this rule exists for: judged against WHOLE-window stats
        /// (speech in the first half), the same hallucination sails through the
        /// live-path filters. Per-segment evidence is the difference.
        @Test("whole-window stats would have kept the same hallucination")
        func wholeWindowStatsWouldKeepIt() {
            let hallucination = rawSegment(
                "Gracias.", start: 20.0, end: 24.0, avgLogprob: -0.1, compressionRatio: 1.1)
            let results = [TranscriptionResult(
                text: hallucination.text,
                segments: [hallucination],
                language: "es",
                timings: TranscriptionTimings()
            )]
            let wholeWindowStats = AudioStats.compute(from: window)
            let kept = TranscriptionPipeline.transcriptSegments(
                from: results, channel: .microphone, offset: 0, stats: wholeWindowStats)
            #expect(kept.count == 1)
        }

        @Test("the hallucination train: real speech survives, every invented segment over silence drops")
        func hallucinationTrainDrops() {
            let segments = [
                rawSegment("so the migration finishes tonight", start: 2.0, end: 6.0),
                rawSegment("I am sorry", start: 20.0, end: 21.2, avgLogprob: -0.4),
                rawSegment("I am sorry", start: 22.0, end: 23.2, avgLogprob: -0.4),
                rawSegment("I am sorry", start: 24.0, end: 25.2, avgLogprob: -0.4),
            ]
            let result = TranscriptionPipeline.evidenceJudgedSegments(
                from: segments, channel: .system, offset: 0, windowSamples: window)
            #expect(result.map(\.text) == ["so the migration finishes tonight"])
        }
    }

    // MARK: - Whisper boilerplate blacklist — YouTube-training artifacts (SP-007)

    @Suite("Boilerplate blacklist extensions")
    struct BoilerplateBlacklistTests {

        /// Voiced audio so the noise filter passes; avgLogprob −0.6 clears the
        /// −0.75 rejection floor but trips the boilerplate −0.55 confidence bar —
        /// exactly the regime the real meeting's artifacts arrived in.
        private let window = SyntheticWindow.speechThenSilence()

        private func judged(_ text: String) -> [TranscriptSegment] {
            let segment = rawSegment(text, start: 3.0, end: 4.2, avgLogprob: -0.6)
            return TranscriptionPipeline.evidenceJudgedSegments(
                from: [segment], channel: .system, offset: 0, windowSamples: window)
        }

        @Test("the real meeting's YouTube-training artifacts are dropped", arguments: [
            "Subtitles by the Amara.org community",
            "Thanks for watching!",
            "See you in the next one.",
            "See you in the next video!",
            "I think that's it for this video.",
            "Hi there, my name is",
            "(mumbling)",
        ])
        func artifactDrops(text: String) {
            #expect(judged(text).isEmpty)
        }

        @Test("real short sentences with the same metrics survive")
        func realShortSentenceSurvives() {
            #expect(judged("we will ship the build").count == 1)
        }
    }

    // MARK: - The composed window pipeline (ADR-019 rules 4 → 1 → 2)

    @Suite("FinalPassDiscipline — disciplined window segments")
    struct DisciplinedWindowTests {

        private let window = SyntheticWindow.speechThenSilence()

        @Test("a mixed window keeps only passing, evidenced, well-formed segments")
        func mixedWindowKeepsOnlyTheGoodOne() {
            let raw = [
                rawSegment("the rollout plan looks solid", start: 2.0, end: 6.0),
                rawSegment("el, ah, el, ah", start: 8.0, end: 12.0, avgLogprob: -1.4, compressionRatio: 3.0),
                rawSegment("Gracias.", start: 20.0, end: 24.0),
                rawSegment("thank you", start: 30.2, end: 31.0),   // born in the tail pad
            ]
            let result = FinalPassDiscipline.disciplinedWindowSegments(
                raw: raw, channel: .system, offset: 60.0, windowSamples: window)
            #expect(result.map(\.text) == ["the rollout plan looks solid"])
            #expect(result[0].start == 62.0)
        }

        @Test("an all-garbage window contributes nothing")
        func allGarbageWindowIsEmpty() {
            let raw = [
                rawSegment("eh, eh, eh", start: 0.0, end: 10.0, avgLogprob: -1.3, compressionRatio: 2.9),
                rawSegment("eh, eh, eh", start: 10.0, end: 20.0, avgLogprob: -1.5, compressionRatio: 3.4),
            ]
            let result = FinalPassDiscipline.disciplinedWindowSegments(
                raw: raw, channel: .microphone, offset: 0, windowSamples: window)
            #expect(result.isEmpty)
        }
    }
}
