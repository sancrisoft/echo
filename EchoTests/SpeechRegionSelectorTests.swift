//
//  SpeechRegionSelectorTests.swift
//  EchoTests
//
//  SP-005 S3: evidence-based speech-region selection — the moved
//  anti-hallucination defense. The live speech gates never see the final
//  pass's full-timeline decode and the pinned WhisperKit's noSpeechProb is
//  dead code, so silence discipline is exactly this table: regions come only
//  from probes clearing the gates' hard floor, silent spans select nothing,
//  and the final audible region always reaches the retained clip's end (the
//  tail-trap guard, composed with the window plan).
//

import Foundation
import Testing
@testable import Echo

@Suite("SpeechRegionSelector")
struct SpeechRegionSelectorTests {

    private let probe = SpeechRegionSelector.probeSamples
    private let pad = SpeechRegionSelector.paddingSamples

    private let speech = SpeechRegionSelector.Probe(rms: 0.05, peak: 0.30)
    private let silence = SpeechRegionSelector.Probe(rms: 0.0005, peak: 0.001)

    /// A probe series of `count` silent probes with `speech` at the given indices.
    private func series(count: Int, speechAt indices: Set<Int>) -> [SpeechRegionSelector.Probe] {
        (0..<count).map { indices.contains($0) ? speech : silence }
    }

    // MARK: - The floor is the gates' hard floor, referenced not re-derived

    @Test("speech evidence is the gate's hard floor: both RMS and peak must clear")
    func speechEvidenceIsTheHardFloor() {
        // At the floor (GateTerm: rms >= 0.004, peak >= 0.020) — evidence.
        #expect(SpeechRegionSelector.hasSpeechEvidence(.init(rms: 0.004, peak: 0.020)))
        // RMS below the floor: no evidence, however hot the peak.
        #expect(!SpeechRegionSelector.hasSpeechEvidence(.init(rms: 0.0039, peak: 0.5)))
        // Peak below the floor: no evidence, however hot the RMS.
        #expect(!SpeechRegionSelector.hasSpeechEvidence(.init(rms: 0.05, peak: 0.019)))
    }

    // MARK: - Selection

    @Test("a fully silent series selects nothing — those spans are never decoded")
    func silentSeriesSelectsNothing() {
        let probes = series(count: 400, speechAt: [])
        #expect(SpeechRegionSelector.regions(probes: probes, totalSamples: 400 * probe).isEmpty)
    }

    @Test("no audio selects nothing")
    func emptyAudioSelectsNothing() {
        #expect(SpeechRegionSelector.regions(probes: [], totalSamples: 0).isEmpty)
    }

    @Test("a speech probe becomes one region padded ≥0.5 s on both sides")
    func speechProbeIsPaddedGenerously() {
        let total = 100 * probe
        let regions = SpeechRegionSelector.regions(
            probes: series(count: 100, speechAt: [40]),
            totalSamples: total
        )

        #expect(regions == [(40 * probe - pad)..<(41 * probe + pad)])
        #expect(pad >= Int(AudioConstants.sampleRate * 0.5))
    }

    @Test("padding clamps at the clip's start")
    func paddingClampsAtStart() {
        let total = 100 * probe
        let regions = SpeechRegionSelector.regions(
            probes: series(count: 100, speechAt: [0]),
            totalSamples: total
        )
        #expect(regions == [0..<(probe + pad)])
    }

    @Test("the final audible region reaches the clip's true end (tail-trap guard)")
    func finalAudibleRegionReachesTheEnd() {
        let count = 100
        let total = count * probe
        let regions = SpeechRegionSelector.regions(
            probes: series(count: count, speechAt: [count - 1]),
            totalSamples: total
        )
        #expect(regions.last?.upperBound == total)
    }

    @Test("a partial final probe still selects up to the clip's end")
    func partialFinalProbeSelectsTheTail() {
        // The retained file rarely ends on a 30 ms boundary; the last probe
        // covers the remainder and its region clamps to totalSamples.
        let total = 100 * probe + 200
        var probes = series(count: 100, speechAt: [])
        probes.append(speech)   // the partial 200-sample tail probe
        let regions = SpeechRegionSelector.regions(probes: probes, totalSamples: total)
        #expect(regions == [(100 * probe - pad)..<total])
    }

    @Test("nearby speech merges into one region (gap under 2 s)")
    func nearbyRegionsMerge() {
        // Padded regions end at 41·probe+pad and start at 140·probe−pad:
        // the gap is 99·probe−2·pad = 31 520 samples < 2 s (32 000) → merge.
        let total = 200 * probe
        let regions = SpeechRegionSelector.regions(
            probes: series(count: 200, speechAt: [40, 140]),
            totalSamples: total
        )
        #expect(regions == [(40 * probe - pad)..<(141 * probe + pad)])
    }

    @Test("distant speech stays separate regions (gap of 2 s or more)")
    func distantRegionsStaySeparate() {
        // Gap here is 104·probe−2·pad = 33 920 samples ≥ 2 s → two regions.
        let total = 200 * probe
        let regions = SpeechRegionSelector.regions(
            probes: series(count: 200, speechAt: [40, 145]),
            totalSamples: total
        )
        #expect(regions == [
            (40 * probe - pad)..<(41 * probe + pad),
            (145 * probe - pad)..<(146 * probe + pad),
        ])
    }

    @Test("consecutive speech probes coalesce into one continuous region")
    func consecutiveSpeechCoalesces() {
        let total = 100 * probe
        let regions = SpeechRegionSelector.regions(
            probes: series(count: 100, speechAt: [40, 41, 42, 43]),
            totalSamples: total
        )
        #expect(regions == [(40 * probe - pad)..<(44 * probe + pad)])
    }
}

/// The window plan composed over selected regions: decode windows cover
/// exactly the regions, ≤30 s each, in absolute sample positions — so the
/// recording-relative timestamp mapping survives region selection and the
/// tail-trap guard holds per region.
@Suite("FinalPassWindowPlan region composition")
struct FinalPassRegionWindowTests {

    private let rate = Int(AudioConstants.sampleRate)

    @Test("no regions plan no windows")
    func noRegionsPlanNothing() {
        #expect(FinalPassWindowPlan.windows(covering: []).isEmpty)
    }

    @Test("a short region is one window at its absolute position")
    func shortRegionIsOneWindow() {
        let region = (10 * rate)..<(14 * rate)
        #expect(FinalPassWindowPlan.windows(covering: [region]) == [region])
    }

    @Test("a long region splits into ≤30 s windows that still reach its end")
    func longRegionSplitsAndReachesItsEnd() {
        let region = (60 * rate)..<(130 * rate)   // 70 s → 30 + 30 + 10
        let windows = FinalPassWindowPlan.windows(covering: [region])

        #expect(windows.count == 3)
        #expect(windows.first?.lowerBound == region.lowerBound)
        #expect(windows.last?.upperBound == region.upperBound)
        for window in windows {
            #expect(window.count <= 30 * rate)
        }
        for (previous, next) in zip(windows, windows.dropFirst()) {
            #expect(previous.upperBound == next.lowerBound)
        }
    }

    @Test("windows never cross region boundaries — silence between regions is never decoded")
    func windowsNeverCrossRegions() {
        let first = 0..<(2 * rate)
        let second = (100 * rate)..<(103 * rate)
        let windows = FinalPassWindowPlan.windows(covering: [first, second])

        #expect(windows == [first, second])
    }
}
