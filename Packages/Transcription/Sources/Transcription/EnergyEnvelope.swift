//
//  EnergyEnvelope.swift
//  Transcription
//
//  One channel's loudness over time, frame-quantized: the whole sample buffer
//  reduced to a mean square per 100 ms.
//
//  It exists so the two channels' levels can be compared on the SAME window —
//  the measured bleed discriminator — even though the pass decodes one channel
//  at a time and lets each one's samples go before reading the next. Keeping
//  both buffers instead would double the pass's peak memory (~46 MB per hour,
//  per channel); an envelope costs ~144 KB an hour and answers the only
//  question the dedup asks of the audio.
//

import Foundation

public struct EnergyEnvelope: Sendable {

    /// Resolution. Well under the shortest segment the pass emits, so a span's
    /// level is never dominated by frame rounding.
    public static let frameSeconds: TimeInterval = 0.1

    private let meanSquares: [Float]

    public init(samples: [Float]) {
        let frame = max(1, Int(TranscriptionPass.sampleRate * Self.frameSeconds))
        var squares: [Float] = []
        squares.reserveCapacity(samples.count / frame + 1)
        var start = 0
        while start < samples.count {
            let count = min(frame, samples.count - start)
            var sum: Float = 0
            for i in start..<(start + count) { sum += samples[i] * samples[i] }
            squares.append(sum / Float(count))
            start += count
        }
        meanSquares = squares
    }

    /// RMS over `[from, to)` seconds, or nil when that window covers no frame
    /// of this channel — an unmeasurable span must read as absent evidence,
    /// never as silence.
    public func rms(from: TimeInterval, to: TimeInterval) -> Float? {
        let first = max(0, Int((from / Self.frameSeconds).rounded(.down)))
        let last = min(meanSquares.count, Int((to / Self.frameSeconds).rounded(.up)))
        guard first < last else { return nil }
        var sum: Float = 0
        for i in first..<last { sum += meanSquares[i] }
        return (sum / Float(last - first)).squareRoot()
    }

    /// Below this rms a frame holds nothing at all — not speech, not echo,
    /// not room tone worth a word. Measured on the fixtures: true silence sits
    /// at 0.0004–0.0008, the quietest transcribed bleed at 0.003, speech above
    /// 0.02. An absolute floor is safe HERE, where it only places a boundary
    /// between segments, in a way it never was for deciding what to transcribe:
    /// misplacing a boundary costs nothing, dropping audio erases words.
    public static let silenceFloor: Float = 0.002

    /// Start time of every stretch of silence lasting at least `minimum`.
    ///
    /// These are the only instants in a channel guaranteed not to fall inside
    /// a word, which makes them the safe places to end a segment — and unlike
    /// the gaps between token timings, they come from the audio itself rather
    /// than from the model's estimate of when it heard something.
    ///
    /// The START of each stretch is what is reported, not its middle: a model
    /// that stretches a token's timing forward over the silence would put the
    /// echo's first word before a midpoint, but never before the instant the
    /// speaker actually fell quiet.
    public func silenceStarts(minimum: TimeInterval) -> [TimeInterval] {
        let floor = Self.silenceFloor * Self.silenceFloor
        var starts: [TimeInterval] = []
        var runStart: Int?
        // One index past the end closes a run that reaches the last frame.
        for i in 0...meanSquares.count {
            if i < meanSquares.count, meanSquares[i] < floor {
                if runStart == nil { runStart = i }
            } else if let start = runStart {
                if Double(i - start) * Self.frameSeconds >= minimum {
                    starts.append(Double(start) * Self.frameSeconds)
                }
                runStart = nil
            }
        }
        return starts
    }

    /// How many frames either side of a frame are averaged in before comparing
    /// the two channels. Raw 100 ms frames cross over constantly during
    /// ordinary speech — a syllable's decay dips under the other channel and
    /// back — so a run measured on them is chopped into meaningless slivers.
    /// Smoothing over 300 ms makes "dominant" mean sustained, not momentary.
    private static let dominanceSmoothing = 1

    /// The longest uninterrupted stretch of `[from, to)` where this channel
    /// carries more energy than `other`.
    ///
    /// This is the one thing an echo can never fake. A bleed segment is the
    /// other channel arriving quieter through a speaker and a room, so it is
    /// under that channel for its whole length; a second of the reverse means
    /// the near speaker actually said something here. Frames only one channel
    /// has are not dominance — they are the absence of a comparison.
    public func longestDominantRun(
        over other: EnergyEnvelope,
        from: TimeInterval,
        to: TimeInterval
    ) -> TimeInterval {
        let first = max(0, Int((from / Self.frameSeconds).rounded(.down)))
        let last = min(
            min(meanSquares.count, other.meanSquares.count),
            Int((to / Self.frameSeconds).rounded(.up))
        )
        guard first < last else { return 0 }

        var longest = 0
        var current = 0
        for i in first..<last {
            let window =
                max(first, i - Self.dominanceSmoothing)..<min(last, i + Self.dominanceSmoothing + 1)
            var mine: Float = 0
            var theirs: Float = 0
            for j in window {
                mine += meanSquares[j]
                theirs += other.meanSquares[j]
            }
            current = mine > theirs ? current + 1 : 0
            longest = max(longest, current)
        }
        return Double(longest) * Self.frameSeconds
    }
}
