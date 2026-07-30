//
//  FinalizationPass.swift
//  Echo
//
//  SP-005 S1: the final re-transcription pass, v0 walking skeleton. After a
//  meeting stops (and its live transcript is persisted — the floor, ADR-016),
//  the pass re-decodes the retained per-channel audio (ADR-013) in sequential
//  ≤30 s windows on the model a `FinalPassModelProviding` lends it — v0 lends
//  the live pipeline's already-loaded instance (ADR-015's floor tier: no
//  second model in memory).
//
//  The loop is deliberately window-driven: `shouldYield` is checked before
//  every decode window so slice S4 can wire recording preemption (ADR-014
//  "yields within one decode window") without touching this loop. v0 callers
//  always pass false.
//
//  Tail trap (SP-005 Further Notes): the pinned WhisperKit never decodes the
//  last ≤1.0 s of a clip (windowClipTime), so every window is padded with
//  ≥1.5 s of trailing silence before decoding — otherwise each window's tail,
//  and with it the meeting's closing words, would be structurally lost.
//

import AVFoundation
import Foundation
import WhisperKit
import os

/// Provides the Whisper model a final pass decodes with. v0's only
/// implementation lends the live pipeline's instance; slice S5 adds the
/// RAM-tiered provider (ADR-015) behind this same seam, so the window loop
/// never learns which checkpoint it is running on.
nonisolated protocol FinalPassModelProviding: Sendable {
    func withModel<T: Sendable>(_ body: @Sendable (WhisperKit) async throws -> T) async throws -> T
}

/// Lends the live pipeline's already-loaded WhisperKit instance — zero
/// additional model memory, the 8 GB tier and the universal fallback floor.
nonisolated struct LivePipelineModelProvider: FinalPassModelProviding {
    let pipeline: TranscriptionPipeline

    func withModel<T: Sendable>(_ body: @Sendable (WhisperKit) async throws -> T) async throws -> T {
        try await pipeline.withModelForFinalPass(body)
    }
}

/// Pure windowing arithmetic, separated so the plan is table-testable
/// without a model (SP-005 Testing Decisions, layer 1).
nonisolated enum FinalPassWindowPlan {

    /// Whisper's native operating point — the full context the live path's
    /// 1–12 s chunks structurally can't give it.
    static let windowSamples = Int(AudioConstants.sampleRate * 30)

    /// Trailing silence appended to every decode clip; must exceed the
    /// pinned WhisperKit's 1.0 s windowClipTime so the audible tail decodes.
    static let tailPadSamples = Int(AudioConstants.sampleRate * 1.5)

    /// Sequential, contiguous windows covering every retained sample — the
    /// last window always reaches `totalSamples` (the tail-trap guard).
    static func windows(totalSamples: Int) -> [Range<Int>] {
        guard totalSamples > 0 else { return [] }
        return stride(from: 0, to: totalSamples, by: windowSamples).map {
            $0..<min($0 + windowSamples, totalSamples)
        }
    }

    /// A window's decode clip: its samples plus the trailing silence pad.
    static func paddedClip(_ samples: ArraySlice<Float>) -> [Float] {
        var clip = Array(samples)
        clip.append(contentsOf: [Float](repeating: 0, count: tailPadSamples))
        return clip
    }
}

nonisolated enum FinalizationPass {

    static let log = Logger(subsystem: "com.sancrisoft.Echo", category: "FinalizationPass")

    enum PassError: Error {
        /// The lender has no loaded model — the pass cannot run now.
        case modelUnavailable
        /// `shouldYield` asked the pass to stop between decode windows
        /// (ADR-014 recording preemption; S4 wires the caller side).
        case preempted
        /// The retained file couldn't be opened or read as 16 kHz Float PCM.
        case unreadableAudio(String)
    }

    /// Re-transcribes every retained channel and returns the complete final
    /// segment set, timeline-ordered, ready for the atomic replace. Throws on
    /// any failure — the caller leaves the live transcript standing and keeps
    /// the retained audio (ADR-016).
    static func run(
        retainedFiles: [AudioChannel: URL],
        model: some FinalPassModelProviding,
        shouldYield: @Sendable () -> Bool = { false }
    ) async throws -> [TranscriptSegment] {
        var segments: [TranscriptSegment] = []
        // Deterministic channel order; the sort below owns the timeline.
        for channel in [AudioChannel.microphone, .system] {
            guard let url = retainedFiles[channel] else { continue }
            segments += try await transcribeChannel(
                url: url,
                channel: channel,
                model: model,
                shouldYield: shouldYield
            )
        }
        return segments.sorted { $0.start < $1.start }
    }

    // MARK: - Per-channel window loop

    private static func transcribeChannel(
        url: URL,
        channel: AudioChannel,
        model: some FinalPassModelProviding,
        shouldYield: @Sendable () -> Bool
    ) async throws -> [TranscriptSegment] {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw PassError.unreadableAudio(error.localizedDescription)
        }
        guard file.processingFormat.commonFormat == .pcmFormatFloat32 else {
            throw PassError.unreadableAudio("Unexpected decoded format for \(url.lastPathComponent)")
        }

        let totalSamples = Int(file.length)
        let windows = FinalPassWindowPlan.windows(totalSamples: totalSamples)
        Self.log.info("""
        Final pass: \(channel.rawValue, privacy: .public) — \
        \(String(format: "%.1f", Double(totalSamples) / AudioConstants.sampleRate), privacy: .public)s retained, \
        \(windows.count, privacy: .public) windows
        """)

        var segments: [TranscriptSegment] = []
        // Sticky across windows, like the live path's per-channel language
        // cache: the first in-whitelist detection wins until a later window
        // detects another whitelisted language.
        var sessionLanguage: String?

        for window in windows {
            if shouldYield() { throw PassError.preempted }

            let samples = try read(file, window: window)
            let clip = FinalPassWindowPlan.paddedClip(samples[...])
            let offset = Double(window.lowerBound) / AudioConstants.sampleRate
            let carried = sessionLanguage

            let (produced, language) = try await model.withModel { whisper -> ([TranscriptSegment], String?) in
                // The live path discards chunks whose detected language is
                // outside en/es; the final pass never discards audio for
                // language reasons (SP-005): out-of-whitelist detections fall
                // back to the carried session language (or English).
                var windowLanguage = carried
                if let detection = try? await whisper.detectLangauge(audioArray: clip),
                   TranscriptionPipeline.allowedTranscriptionLanguages.contains(detection.language) {
                    windowLanguage = detection.language
                }

                var options = TranscriptionPipeline.liveDecodeOptions
                options.language = windowLanguage ?? "en"
                let results = try await whisper.transcribe(audioArray: clip, decodeOptions: options)

                // Same segment assembly + noise/boilerplate filters as the
                // live path, with recording-relative timestamps (window
                // offset + within-window segment offsets). Stats come from
                // the unpadded samples so the filters judge the real audio.
                let stats = AudioStats.compute(from: samples)
                let produced = TranscriptionPipeline.transcriptSegments(
                    from: results,
                    channel: channel,
                    offset: offset,
                    stats: stats
                )
                return (produced, windowLanguage)
            }

            sessionLanguage = language ?? sessionLanguage
            // A segment may bleed into the silence pad; the clip's real audio
            // ends at the window boundary, so clamp there.
            let windowEnd = Double(window.upperBound) / AudioConstants.sampleRate
            segments += produced.map { segment in
                var clamped = segment
                clamped.end = min(segment.end, windowEnd)
                return clamped
            }
        }
        return segments
    }

    private static func read(_ file: AVAudioFile, window: Range<Int>) throws -> [Float] {
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(window.count)
        ) else {
            throw PassError.unreadableAudio("Couldn't allocate a \(window.count)-frame read buffer")
        }
        do {
            file.framePosition = AVAudioFramePosition(window.lowerBound)
            try file.read(into: buffer, frameCount: AVAudioFrameCount(window.count))
        } catch {
            throw PassError.unreadableAudio(error.localizedDescription)
        }
        guard let channelData = buffer.floatChannelData else {
            throw PassError.unreadableAudio("Decoded buffer exposes no Float channel data")
        }
        return Array(UnsafeBufferPointer(start: channelData[0], count: Int(buffer.frameLength)))
    }
}
