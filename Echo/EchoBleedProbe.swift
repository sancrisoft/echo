//
//  EchoBleedProbe.swift
//  Echo
//
//  Decides, from a meeting's audio alone, whether the mic carries a delayed
//  copy of what the speakers were playing — and at what delay.
//
//  It exists because echo handling is not a stored fact. The mode a meeting
//  recorded under is nowhere in its metadata, Retry must work on meetings
//  recorded before any of this existed, and the live route classifier's
//  premise — that only the built-in speakers bleed — is measurably false: an
//  HDMI TV bleeds too, and every meeting recorded through one carries the
//  teammate's voice on the You channel. Rather than persist a new field and
//  strand every old meeting, the pre-pass asks the audio.
//
//  The measurement is in the envelope, not the waveform. What survives a
//  loudspeaker, a room and a microphone is the loudness contour; the waveform
//  arrives filtered and clipped and correlates far worse than the shape of
//  its own loudness does.
//

import Foundation

nonisolated enum EchoBleedProbe {

    // MARK: Measured floors
    //
    // Every number here comes from three real meetings on the same TV
    // (2026-08-06/07), not from theory. They are deliberately not
    // configurable: a knob here is a knob on whether a meeting gets its audio
    // rewritten, and the only honest way to move one is to re-measure.

    /// Envelope resolution. `EnergyEnvelope`'s 100 ms frames are the right
    /// grain for comparing two channels' levels and far too coarse for a
    /// delay measured in tens of milliseconds.
    static let frameSeconds: TimeInterval = 0.005

    /// Window length for one delay measurement. Long enough that the
    /// correlation has speech structure to lock onto, short enough that
    /// several fit in even a brief meeting.
    static let windowSeconds: TimeInterval = 10

    /// Windows are spread across the meeting rather than taken from wherever
    /// qualifies first — a verdict drawn from one stretch is a verdict about
    /// that stretch.
    static let maxWindows = 6

    /// Below this the reference is not really playing, and a window that
    /// hears nothing can say nothing about the echo path.
    static let referenceFloor: Double = 0.01

    /// Bleed-shaped: the mic is markedly quieter than the reference over the
    /// whole window. This is the discriminator the measurements turned on —
    /// windows where the user is talking pollute the correlation, and it was
    /// exactly those that produced the low-coherence readings that first
    /// looked like clock drift.
    static let bleedRatioCeiling: Double = 0.5

    /// Delay search range. Measured paths sit at 125–180 ms; the range is
    /// generous either side so an unfamiliar room still lands inside it.
    static let maxLagSeconds: TimeInterval = 0.4

    /// Real bleed reads 0.40–0.83 in bleed-shaped windows. A headphone or
    /// mic-only pair produces no bleed-shaped windows at all, so this floor
    /// is not what keeps the probe quiet on them — it is what keeps a
    /// marginal, half-correlated stretch from being called an echo path.
    static let coherenceFloor: Double = 0.35

    /// Two windows count as agreeing when their lags land this close. The
    /// echo path does not drift within a meeting (both retained channels
    /// share the live clock), so genuine windows agree tightly and a spread
    /// of lags means the correlation found something other than echo.
    static let agreementSeconds: TimeInterval = 0.025

    /// At least this many windows must agree. One window agreeing with
    /// nothing is a coincidence; the cheapest defence against acting on one.
    static let agreementCount = 2

    // MARK: Verdict

    struct Verdict: Sendable, Equatable {
        /// How far behind the reference the mic's copy arrives.
        var delaySeconds: TimeInterval
        /// Median coherence of the agreeing windows.
        var coherence: Double
        /// Start times of the agreeing windows. The pre-pass measures its own
        /// effect here and nowhere else: these are the only stretches known
        /// to be echo, and whole-file energy would be diluted by the user's
        /// own speech, which must not be cancelled at all.
        var bleedWindowStarts: [TimeInterval]
    }

    /// The verdict, or nil when the audio shows no echo path. Nil is the
    /// answer for headphones, for a mic-only meeting, for a route that never
    /// bled, and for a meeting already cleaned on the way in — the pre-pass
    /// treats all four the same way, by leaving the audio alone.
    static func run(mic: [Float], system: [Float]) -> Verdict? {
        let micEnvelope = envelope(mic)
        let systemEnvelope = envelope(system)
        let frames = min(micEnvelope.count, systemEnvelope.count)
        let windowFrames = Int(windowSeconds / frameSeconds)
        let maxLagFrames = Int(maxLagSeconds / frameSeconds)
        guard frames >= windowFrames, windowFrames > maxLagFrames else { return nil }

        var candidates: [Int] = []
        var start = 0
        while start + windowFrames <= frames {
            let window = start ..< start + windowFrames
            let systemRMS = rms(systemEnvelope[window])
            if systemRMS >= referenceFloor, rms(micEnvelope[window]) <= bleedRatioCeiling * systemRMS {
                candidates.append(start)
            }
            start += windowFrames
        }

        var measured: [(start: Int, lag: Int, coherence: Double)] = []
        for start in spread(candidates, to: maxWindows) {
            var bestLag = 0
            var bestCoherence = -1.0
            for lag in 0 ... maxLagFrames {
                // Both slices stay inside the window: the mic side shifted
                // forward by the lag, the reference side from the window's
                // own start. Costs the last 400 ms of a 10 s window, and
                // keeps a window's verdict a property of that window.
                let coherence = correlation(
                    micEnvelope[start + lag ..< start + windowFrames],
                    systemEnvelope[start ..< start + windowFrames - lag]
                )
                if coherence > bestCoherence {
                    bestCoherence = coherence
                    bestLag = lag
                }
            }
            measured.append((start: start, lag: bestLag, coherence: bestCoherence))
        }

        let strong = measured.filter { $0.coherence >= coherenceFloor }
        var agreeing: [(start: Int, lag: Int, coherence: Double)] = []
        for anchor in strong {
            let cluster = strong.filter {
                abs(Double($0.lag - anchor.lag)) * frameSeconds <= agreementSeconds
            }
            if cluster.count > agreeing.count { agreeing = cluster }
        }
        guard agreeing.count >= agreementCount else { return nil }

        return Verdict(
            delaySeconds: median(agreeing.map { Double($0.lag) * frameSeconds }),
            coherence: median(agreeing.map(\.coherence)),
            bleedWindowStarts: agreeing.map { Double($0.start) * frameSeconds }.sorted()
        )
    }

    // MARK: Pure helpers (internal so the tables can reach them)

    /// Mean squares per `frameSeconds`. A trailing partial frame is dropped:
    /// a window is only ever whole frames, and a short last one would carry
    /// a different amount of evidence than the rest.
    static func envelope(_ samples: [Float]) -> [Double] {
        let frame = max(1, Int(AudioConstants.sampleRate * frameSeconds))
        var squares: [Double] = []
        squares.reserveCapacity(samples.count / frame)
        var start = 0
        while start + frame <= samples.count {
            var sum = 0.0
            for i in start ..< (start + frame) { sum += Double(samples[i]) * Double(samples[i]) }
            squares.append(sum / Double(frame))
            start += frame
        }
        return squares
    }

    static func rms(_ meanSquares: ArraySlice<Double>) -> Double {
        guard !meanSquares.isEmpty else { return 0 }
        return (meanSquares.reduce(0, +) / Double(meanSquares.count)).squareRoot()
    }

    /// Pearson correlation of two equal-length envelope slices. A flat slice
    /// has no variance to explain, so it correlates with nothing — silence
    /// must read as no evidence, never as a perfect match.
    static func correlation(_ a: ArraySlice<Double>, _ b: ArraySlice<Double>) -> Double {
        guard a.count == b.count, a.count > 1 else { return 0 }
        let n = Double(a.count)
        let meanA = a.reduce(0, +) / n
        let meanB = b.reduce(0, +) / n
        var covariance = 0.0, varianceA = 0.0, varianceB = 0.0
        for (x, y) in zip(a, b) {
            let dx = x - meanA, dy = y - meanB
            covariance += dx * dy
            varianceA += dx * dx
            varianceB += dy * dy
        }
        guard varianceA > 0, varianceB > 0 else { return 0 }
        return covariance / (varianceA * varianceB).squareRoot()
    }

    /// Up to `limit` entries, evenly spaced across the input — including both
    /// ends, so a verdict is never drawn from one end of the meeting.
    static func spread(_ values: [Int], to limit: Int) -> [Int] {
        guard values.count > limit, limit > 0 else { return values }
        guard limit > 1 else { return [values[0]] }
        let last = Double(values.count - 1)
        return (0 ..< limit).map {
            values[Int((Double($0) * last / Double(limit - 1)).rounded())]
        }
    }

    static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? (sorted[middle - 1] + sorted[middle]) / 2
            : sorted[middle]
    }
}
