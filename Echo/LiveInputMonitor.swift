//
//  LiveInputMonitor.swift
//  Echo
//
//  What is left of the live pipeline once transcription moved entirely
//  post-meeting: the two 16 kHz mono Float streams are still buffered per
//  channel and still cut at natural pauses (energy-based VAD endpointing),
//  and every finalized chunk is still measured and gate-classified — but
//  nothing decodes. There is no model here, nothing to load, nothing to wait
//  for, and no text is produced during a recording.
//
//  The chunking survives because the gate decisions do: `GateDecisionRecord`
//  is what `InputHealthTracker` consumes to raise the ADR-006 input-health
//  warnings ("your mic is being discarded", "the Team channel went quiet"),
//  and those verdicts are only meaningful over utterance-shaped chunks. So
//  this is deliberately the old ingest → endpoint → gate path with the
//  decode, the filters, and the language logic removed — not a rewrite.
//
//  Recording therefore never depends on any model: `ingest` accepts audio
//  from the first sample of the session (the old `guard loaded` drop is
//  gone), and the meeting's words come later, from `ParakeetPass`.
//

import Foundation
import os

/// Derived per-chunk audio metrics that the speech gates evaluate. A pure
/// value of numbers — it never carries samples, which is what lets the gate
/// diagnostics record (SP-002 NFR Privacy) embed it wholesale.
nonisolated struct AudioStats: Sendable {

    let rms: Float
    let peak: Float
    let activeRatio: Float
    let speechWindowRatio: Float
    let strongWindowRatio: Float
    let noiseFloorRMS: Float
    let dynamicRangeDB: Float
    let crestFactor: Float

    /// Conservative evidence that the chunk contains actual speech instead
    /// of low-level residue/silence. The individual thresholds live on
    /// `GateTerm` so the SP-002 gate diagnostics report exactly the terms
    /// this decision runs on.
    var hasClearSpeech: Bool {
        GateTerm.clearSpeech.allSatisfy { $0.passes(self) }
    }

    var hasTranscribableSpeech: Bool {
        hasClearSpeech || GateTerm.loudFallback.allSatisfy { $0.passes(self) }
    }

    var isMarginalSpeech: Bool {
        !hasClearSpeech || rms < 0.014 || speechWindowRatio < 0.16
    }

    // MARK: - Computation

    /// Analysis window for the energy probe (~30 ms). Shared with the
    /// monitor's VAD endpointing so gating and pause detection agree on
    /// what a window is.
    static let probeSamples = Int(AudioConstants.sampleRate * 0.03)

    /// A window quieter than this (RMS) is treated as non-speech. Above the
    /// `isSilent` floor so room tone / breaths still register as a pause.
    static let pauseRMS: Float = 0.01

    /// The production gate-metric computation, exposed as a pure function so
    /// the SP-002 gate-diagnostics tests can replay audio through the exact
    /// arithmetic the monitor uses.
    static func compute(from samples: [Float]) -> AudioStats {
        guard !samples.isEmpty else {
            return AudioStats(
                rms: 0,
                peak: 0,
                activeRatio: 0,
                speechWindowRatio: 0,
                strongWindowRatio: 0,
                noiseFloorRMS: 0,
                dynamicRangeDB: 0,
                crestFactor: 0
            )
        }

        var sumSquares: Float = 0
        var peak: Float = 0
        for sample in samples {
            sumSquares += sample * sample
            peak = max(peak, abs(sample))
        }

        var windowRMS: [Float] = []
        var activeWindows = 0
        var totalWindows = 0
        var start = 0
        while start + probeSamples <= samples.count {
            totalWindows += 1
            let window = rms(samples, from: start, count: probeSamples)
            windowRMS.append(window)
            if window >= pauseRMS {
                activeWindows += 1
            }
            start += probeSamples
        }

        let noiseFloor = percentile(windowRMS, fraction: 0.20)
        let loudFloor = percentile(windowRMS, fraction: 0.90)
        let speechThreshold = max(pauseRMS, noiseFloor * 2.4, 0.012)
        let strongThreshold = max(noiseFloor * 3.2, 0.020)
        let speechWindows = windowRMS.filter { $0 >= speechThreshold }.count
        let strongWindows = windowRMS.filter { $0 >= strongThreshold }.count
        let activeRatio = totalWindows > 0 ? Float(activeWindows) / Float(totalWindows) : 0
        let speechRatio = totalWindows > 0 ? Float(speechWindows) / Float(totalWindows) : 0
        let strongRatio = totalWindows > 0 ? Float(strongWindows) / Float(totalWindows) : 0
        let dynamicRange = 20 * log10(max(loudFloor, 0.000_001) / max(noiseFloor, 0.000_001))
        let totalRMS = (sumSquares / Float(samples.count)).squareRoot()
        return AudioStats(
            rms: totalRMS,
            peak: peak,
            activeRatio: activeRatio,
            speechWindowRatio: speechRatio,
            strongWindowRatio: strongRatio,
            noiseFloorRMS: noiseFloor,
            dynamicRangeDB: dynamicRange,
            crestFactor: peak / max(totalRMS, 0.000_001)
        )
    }

    /// RMS of the `count` samples starting at `start`.
    static func rms(_ samples: [Float], from start: Int, count: Int) -> Float {
        var sumSquares: Float = 0
        for i in start..<(start + count) { sumSquares += samples[i] * samples[i] }
        return (sumSquares / Float(count)).squareRoot()
    }

    private static func percentile(_ values: [Float], fraction: Double) -> Float {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let clamped = min(max(fraction, 0), 1)
        let index = Int((Double(sorted.count - 1) * clamped).rounded())
        return sorted[index]
    }
}

actor LiveInputMonitor {

    static let log = Logger(subsystem: "com.sancrisoft.Echo", category: "LiveInputMonitor")

    // MARK: - Tuning

    /// Don't finalize anything shorter than this — keeps chunks from becoming
    /// a stream of one-word slivers when there are lots of short pauses.
    private let minSamples = Int(AudioConstants.sampleRate * 1)
    /// Hard cap: if someone talks nonstop, force a cut at the quietest point
    /// within the last few seconds rather than waiting forever.
    private let maxSamples = Int(AudioConstants.sampleRate * 12)

    // VAD endpointing — what counts as "the speaker stopped".

    /// Endpointing shares its probe window and non-speech floor with the
    /// gate-metric computation (`AudioStats`), so pauses and speech windows
    /// are measured identically.
    private let probeSamples = AudioStats.probeSamples
    private let pauseRMS = AudioStats.pauseRMS
    /// A trailing run of silence this long marks the end of an utterance, so we
    /// cut here. 0.5 s clears normal between-word gaps (<200 ms) but catches
    /// clause/sentence boundaries.
    private let endpointSilence = Int(AudioConstants.sampleRate * 0.5)

    // MARK: - State

    /// Per-channel pending audio plus the recording-relative time of its first
    /// sample, so gate records carry absolute chunk offsets as we drain it.
    private struct ChannelBuffer {
        var samples: [Float] = []
        var chunkStart: TimeInterval = 0
    }

    private var mic = ChannelBuffer()
    private var system = ChannelBuffer()

    /// Receives one record per finalized-chunk gate decision (SP-002 US-12).
    private let gateDiagnostics: any GateDiagnosticsSink

    /// The sink defaults to the permanent os.Logger diagnostic; tests and the
    /// input-health classifier (ADR-006) inject their own to observe gate
    /// decisions in-process.
    init(gateDiagnostics: any GateDiagnosticsSink = OSLogGateDiagnosticsSink()) {
        self.gateDiagnostics = gateDiagnostics
    }

    private func pendingSamples(_ channel: AudioChannel) -> [Float] {
        switch channel {
        case .microphone: return mic.samples
        case .system: return system.samples
        }
    }

    private func append(_ frames: [Float], to channel: AudioChannel) {
        switch channel {
        case .microphone: mic.samples.append(contentsOf: frames)
        case .system: system.samples.append(contentsOf: frames)
        }
    }

    /// Synchronously pulls the leading `count` samples off a channel buffer and
    /// advances its clock. No `await` runs between the read and the mutation, so
    /// reentrant `ingest` calls can't observe a torn buffer.
    private func detachChunk(_ channel: AudioChannel, count: Int) -> (chunk: [Float], offset: TimeInterval)? {
        switch channel {
        case .microphone: return Self.detach(&mic, count)
        case .system: return Self.detach(&system, count)
        }
    }

    private static func detach(_ buffer: inout ChannelBuffer, _ count: Int) -> (chunk: [Float], offset: TimeInterval)? {
        let n = min(count, buffer.samples.count)
        guard n > 0 else { return nil }
        let chunk = Array(buffer.samples.prefix(n))
        buffer.samples.removeFirst(n)
        let offset = buffer.chunkStart
        buffer.chunkStart += Double(n) / AudioConstants.sampleRate
        return (chunk, offset)
    }

    // MARK: - Lifecycle

    /// Resets per-session state. Nothing is loaded and nothing is awaited —
    /// starting a recording never depends on a model.
    func start() {
        mic = ChannelBuffer()
        system = ChannelBuffer()
    }

    /// Classify whatever is left in both buffers at the end of the session, so
    /// the session's final chunks still reach the health classifier.
    func stop() {
        finalizeAll(.microphone)
        finalizeAll(.system)
    }

    private func finalizeAll(_ channel: AudioChannel) {
        guard let (chunk, offset) = detachChunk(channel, count: pendingSamples(channel).count) else { return }
        finalize(chunk, at: offset, on: channel)
    }

    // MARK: - Ingestion

    func ingest(_ frames: [Float], from channel: AudioChannel) {
        append(frames, to: channel)
        // Finalize every chunk whose boundary is currently exposed (a long
        // pause may free several at once after a backlog).
        while let cut = cutPoint(pendingSamples(channel)) {
            guard let (chunk, offset) = detachChunk(channel, count: cut) else { break }
            finalize(chunk, at: offset, on: channel)
        }
    }

    // MARK: - Capture-gap clock realignment (SP-002 "input switch mid-recording")

    /// Advances `channel`'s clock past a measured capture gap — wall time in
    /// which the channel captured nothing (a device-switch engine rebuild, a
    /// lost-device episode). The clock otherwise advances purely by ingested
    /// sample count, so an unreported gap would lag every later chunk offset on
    /// this channel by the gap duration, cumulatively across switches — which
    /// is what the gate diagnostics' `chunkStartOffset` reports against.
    ///
    /// Samples pending when the gap is declared (the mic died mid-utterance)
    /// are force-finalized as their own pre-gap chunk rather than left to merge
    /// with post-gap audio: the device was dead in between, so the two spans
    /// are separate utterances and a merged chunk's measured duration would
    /// misstate its wall span.
    ///
    /// Channel-scoped and additive: the other channel is never touched, and a
    /// session that never declares a gap behaves exactly as before.
    func noteCaptureGap(seconds: TimeInterval, on channel: AudioChannel) {
        // Only real dead time may move a clock, and never backward. Also
        // rejects NaN/infinity from a broken measurement.
        guard seconds > 0, seconds.isFinite else { return }

        let pending = detachChunk(channel, count: pendingSamples(channel).count)
        advanceClock(by: seconds, on: channel)
        Self.log.info("""
        \(channel.rawValue, privacy: .public) capture gap: clock advanced by \
        \(String(format: "%.3f", seconds), privacy: .public)s\
        \(pending == nil ? "" : ", pending pre-gap audio finalized", privacy: .public)
        """)
        if let pending {
            finalize(pending.chunk, at: pending.offset, on: channel)
        }
    }

    private func advanceClock(by seconds: TimeInterval, on channel: AudioChannel) {
        switch channel {
        case .microphone: mic.chunkStart += seconds
        case .system: system.chunkStart += seconds
        }
    }

    // MARK: - VAD endpointing

    /// Decides where (if anywhere) the pending buffer should be cut right now.
    /// Returns the number of leading samples to finalize, or `nil` to keep
    /// buffering.
    private func cutPoint(_ samples: [Float]) -> Int? {
        guard samples.count >= minSamples else { return nil }

        // Natural endpoint: the speaker paused. Cut at the end of the buffer so
        // the whole utterance (plus its trailing silence) goes out together.
        if trailingSilence(samples) >= endpointSilence { return samples.count }

        // Nonstop talking: force a cut at the quietest window we can find near
        // the end, which is the least-bad place to split mid-speech.
        if samples.count >= maxSamples { return quietestCut(samples) }

        return nil
    }

    /// Length, in samples, of the uninterrupted low-energy run at the buffer's end.
    private func trailingSilence(_ samples: [Float]) -> Int {
        var silent = 0
        var end = samples.count
        while end - probeSamples >= 0 {
            if AudioStats.rms(samples, from: end - probeSamples, count: probeSamples) >= pauseRMS { break }
            silent += probeSamples
            end -= probeSamples
        }
        return silent
    }

    /// Index of the quietest probe window in the last few seconds — used as the
    /// fallback cut when there's no real pause. Never cuts below `minSamples`.
    private func quietestCut(_ samples: [Float]) -> Int {
        let searchSpan = Int(AudioConstants.sampleRate * 4)
        let lo = max(minSamples, samples.count - searchSpan)
        let hi = samples.count - probeSamples
        guard hi > lo else { return samples.count }

        var bestRMS = Float.greatestFiniteMagnitude
        var bestCut = samples.count
        var i = lo
        while i <= hi {
            let value = AudioStats.rms(samples, from: i, count: probeSamples)
            if value < bestRMS {
                bestRMS = value
                bestCut = i + probeSamples / 2   // cut through the middle of the gap
            }
            i += probeSamples
        }
        return bestCut
    }

    // MARK: - Gate classification

    /// Measures an already-detached chunk and records its gate decision
    /// (SP-002 US-12) for both verdicts. This is the whole point of the
    /// monitor: nothing consumes the audio afterwards.
    private func finalize(_ chunk: [Float], at offset: TimeInterval, on channel: AudioChannel) {
        let stats = AudioStats.compute(from: chunk)
        gateDiagnostics.record(GateDecisionRecord(
            channel: channel,
            chunkDuration: Double(chunk.count) / AudioConstants.sampleRate,
            chunkStartOffset: offset,
            stats: stats
        ))
    }
}
