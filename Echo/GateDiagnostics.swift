//
//  GateDiagnostics.swift
//  Echo
//
//  Per-chunk speech-gate decision diagnostics (SP-002, US-12).
//
//  Every finalized chunk's gate decision becomes a `GateDecisionRecord`: the
//  derived audio metrics, the verdict, and which specific gate terms failed.
//  This is the executable form of SP-002's confirmation experiment — "which
//  term failed for the external mic: level or shape?" (open question 1) — and
//  it stays on permanently as the local diagnostic that makes "it didn't
//  transcribe" field reports attributable instead of guesswork. It also closes
//  the silent-dropout observability gap: the record stream is what a later
//  input-health classifier consumes (ADR-006 — observational only, never a
//  path switch).
//
//  Records carry derived numbers and verdicts only — never audio samples or
//  transcript text (SP-002 NFR Privacy).
//

import Foundation
import os

/// One predicate of the speech gates (glossary: the absolute energy/shape
/// thresholds a chunk must clear before it is sent to Whisper).
///
/// This enum is the single home of the gate thresholds: the live gate
/// (`TranscriptionPipeline.shouldTranscribe` via `AudioStats`) and the
/// diagnostic term breakdown both evaluate these same predicates, so the
/// record can never drift from the decision it describes.
nonisolated enum GateTerm: String, CaseIterable, Sendable {

    // Hard floor — the absolute silence floor every chunk must clear on
    // every channel before any speech-structure check runs.
    case hardFloorRMS            // rms >= 0.004
    case hardFloorPeak           // peak >= 0.020

    // Clear speech, level terms — is the signal hot enough overall?
    // SP-002 OQ1 hinges on whether external mics fail here (honest, lower
    // levels) or in the shape terms below.
    case clearSpeechRMS          // rms >= 0.010
    case clearSpeechPeak         // peak >= 0.035

    // Clear speech, shape terms — does the energy look like speech
    // (bursty, dynamic) rather than steady ambient noise?
    case clearSpeechWindowRatio  // speechWindowRatio >= 0.10
    case clearSpeechCrestFactor  // crestFactor >= 2.0
    case clearSpeechDynamics     // dynamicRangeDB >= 4.0 || strongWindowRatio >= 0.06

    // Loud fallback — clearly hot chunks pass even when a shape term
    // disagrees (all three must hold together).
    case loudFallbackRMS         // rms >= 0.018
    case loudFallbackPeak        // peak >= 0.055
    case loudFallbackWindowRatio // speechWindowRatio >= 0.18

    // System-channel-only fallback — meeting audio is cleaner than a live
    // room mic, so the Team channel accepts a lower bar (all three together).
    case systemFallbackRMS          // rms >= 0.008
    case systemFallbackPeak         // peak >= 0.030
    case systemFallbackWindowRatio  // speechWindowRatio >= 0.08

    /// Whether this single predicate holds for the given chunk metrics.
    func passes(_ stats: AudioStats) -> Bool {
        switch self {
        case .hardFloorRMS: return stats.rms >= 0.004
        case .hardFloorPeak: return stats.peak >= 0.020
        case .clearSpeechRMS: return stats.rms >= 0.010
        case .clearSpeechPeak: return stats.peak >= 0.035
        case .clearSpeechWindowRatio: return stats.speechWindowRatio >= 0.10
        case .clearSpeechCrestFactor: return stats.crestFactor >= 2.0
        case .clearSpeechDynamics: return stats.dynamicRangeDB >= 4.0 || stats.strongWindowRatio >= 0.06
        case .loudFallbackRMS: return stats.rms >= 0.018
        case .loudFallbackPeak: return stats.peak >= 0.055
        case .loudFallbackWindowRatio: return stats.speechWindowRatio >= 0.18
        case .systemFallbackRMS: return stats.rms >= 0.008
        case .systemFallbackPeak: return stats.peak >= 0.030
        case .systemFallbackWindowRatio: return stats.speechWindowRatio >= 0.08
        }
    }

    static let hardFloor: [GateTerm] = [.hardFloorRMS, .hardFloorPeak]
    static let clearSpeech: [GateTerm] = [
        .clearSpeechRMS, .clearSpeechPeak,
        .clearSpeechWindowRatio, .clearSpeechCrestFactor, .clearSpeechDynamics,
    ]
    static let loudFallback: [GateTerm] = [.loudFallbackRMS, .loudFallbackPeak, .loudFallbackWindowRatio]
    static let systemFallback: [GateTerm] = [.systemFallbackRMS, .systemFallbackPeak, .systemFallbackWindowRatio]

    /// The terms that participate in the gate decision for a channel. The
    /// system fallback exists only on the Team channel.
    static func applicableTerms(for channel: AudioChannel) -> [GateTerm] {
        switch channel {
        case .microphone: return hardFloor + clearSpeech + loudFallback
        case .system: return hardFloor + clearSpeech + loudFallback + systemFallback
        }
    }
}

/// The gate's outcome for one finalized chunk.
nonisolated enum GateVerdict: String, Sendable {
    case transcribe
    case drop
}

/// One finalized-chunk gate decision: derived metrics, verdict, and the
/// per-term failure breakdown. Deliberately holds no audio samples and no
/// transcript text (SP-002 NFR Privacy).
nonisolated struct GateDecisionRecord: Sendable {

    let channel: AudioChannel
    /// Seconds of audio in the finalized chunk (1–12 s by pipeline tuning,
    /// shorter only for the end-of-session and capture-gap flushes).
    let chunkDuration: TimeInterval
    /// Where the chunk starts on its channel's session timeline — seconds
    /// since the channel's first ingested sample, capture-gap realignment
    /// included (SP-002 "input switch mid-recording"). With `chunkDuration`
    /// this makes every chunk's position reconstructable from the log alone,
    /// and it exposes the channel clock to the gate tests as a public
    /// observable. Defaults to 0 for directly-constructed records in
    /// decision-only contexts where timeline position is irrelevant.
    let chunkStartOffset: TimeInterval
    /// The full derived-metric set the gates evaluated.
    let stats: AudioStats
    let verdict: GateVerdict
    /// Every term applicable to `channel` that evaluated false on this chunk —
    /// recorded independently of whether another disjunct rescued the verdict,
    /// so per-chunk level-vs-shape failure profiles stay readable (SP-002 OQ1).
    let failedTerms: [GateTerm]

    init(
        channel: AudioChannel,
        chunkDuration: TimeInterval,
        chunkStartOffset: TimeInterval = 0,
        stats: AudioStats
    ) {
        self.channel = channel
        self.chunkDuration = chunkDuration
        self.chunkStartOffset = chunkStartOffset
        self.stats = stats
        self.verdict = Self.verdict(for: stats, on: channel)
        self.failedTerms = GateTerm.applicableTerms(for: channel).filter { !$0.passes(stats) }
    }

    /// The speech-gate decision itself — the exact boolean structure of
    /// SP-001's gates: hard floor, then clear speech, then the loud fallback,
    /// plus the Team-channel fallback. `TranscriptionPipeline.shouldTranscribe`
    /// delegates here so gate and diagnostics share one implementation.
    static func verdict(for stats: AudioStats, on channel: AudioChannel) -> GateVerdict {
        guard GateTerm.hardFloor.allSatisfy({ $0.passes(stats) }) else { return .drop }

        let clear = GateTerm.clearSpeech.allSatisfy { $0.passes(stats) }
        let loud = GateTerm.loudFallback.allSatisfy { $0.passes(stats) }
        let system = channel == .system && GateTerm.systemFallback.allSatisfy { $0.passes(stats) }
        return (clear || loud || system) ? .transcribe : .drop
    }
}

/// Receives every finalized-chunk gate decision the pipeline makes.
///
/// Called synchronously on the transcription pipeline's actor executor at
/// chunk cadence — roughly one call per second per channel at worst (SP-002
/// NFR Performance) — so implementations must be fast, non-blocking, and
/// thread-safe (`Sendable`). Sinks are observational only (ADR-006): the
/// input-health classifier consumes this stream to raise notices, and no
/// sink ever influences the audio path or the gate decision itself.
nonisolated protocol GateDiagnosticsSink: Sendable {
    func record(_ record: GateDecisionRecord)
}

/// The permanent local diagnostic sink (SP-002 US-12): one compact log line
/// per gate decision, on always — this is what makes a field report of
/// missing transcription attributable to a specific gate term.
nonisolated struct OSLogGateDiagnosticsSink: GateDiagnosticsSink {

    private static let log = Logger(subsystem: "com.sancrisoft.Echo", category: "GateDiagnostics")

    init() {}

    func record(_ record: GateDecisionRecord) {
        // .notice rather than .info: notice-level lines persist in the local
        // log store, so the gate history is still there when a "it didn't
        // transcribe" report arrives after the fact (US-12). Everything stays
        // on device — the unified log is local (NFR Privacy).
        Self.log.notice("\(Self.line(for: record), privacy: .public)")
    }

    /// One line per decision, grep-able by channel and verdict. Derived
    /// numbers and term names only — never audio samples or transcript text
    /// (NFR Privacy).
    static func line(for record: GateDecisionRecord) -> String {
        let stats = record.stats
        let failed = record.failedTerms.isEmpty
            ? "none"
            : record.failedTerms.map(\.rawValue).joined(separator: "+")
        return String(
            format: "gate %@ %@ t=%.2fs dur=%.2fs rms=%.4f peak=%.4f crest=%.1f speech=%.2f strong=%.2f active=%.2f floor=%.4f dyn=%.1fdB failed=%@",
            record.channel.rawValue,
            record.verdict.rawValue,
            record.chunkStartOffset,
            record.chunkDuration,
            stats.rms,
            stats.peak,
            stats.crestFactor,
            stats.speechWindowRatio,
            stats.strongWindowRatio,
            stats.activeRatio,
            stats.noiseFloorRMS,
            stats.dynamicRangeDB,
            failed
        )
    }
}
