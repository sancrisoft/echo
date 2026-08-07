//
//  AECOfflineSpikeTests.swift
//  EchoTests
//
//  The offline-AEC feasibility spike: can the vendored AEC3, fed the retained
//  channel pair after the fact, actually subtract the TV's bleed out of the
//  mic? A measurement harness, not a judge — it prints delay, coherence and
//  ERLE and writes cleaned audio to listen to; the go/no-go call is read off
//  its table by a human.
//
//  Point it at a directory holding a retained pair and run:
//
//      TEST_RUNNER_ECHO_AEC_SPIKE=<dir> xcodebuild test -project Echo.xcodeproj \
//          -scheme Echo -destination 'platform=macOS' -parallel-testing-enabled NO \
//          -only-testing:EchoTests/AECOfflineSpikeTests
//
//  The pair is either `debug-kept-mic.m4a` / `debug-kept-system.m4a` (a real
//  meeting's kept audio, copied to scratch — the meetings themselves stay
//  read-only) or `mic.wav` / `system.wav` (a copied repo fixture scenario, so
//  the no-echo control pairs can be probed without the test bundle's fixture
//  collision). Nothing here downloads or loads a transcription model.
//
//  The probe and the lockstep feeder below are the spike's own copies, kept
//  local on purpose: this slice measures whether the idea works before any of
//  it becomes product code.
//

import AVFoundation
import Foundation
import Testing
@testable import Echo

// MARK: - Gate and input

nonisolated enum AECSpike {

    /// The directory holding the pair to measure — the gate.
    static var directory: URL? {
        ProcessInfo.processInfo.environment["ECHO_AEC_SPIKE"].map {
            URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true)
        }
    }

    static var isEnabled: Bool { directory != nil }

    static let gate: Comment = """
    Offline-AEC feasibility spike — run on demand against a copied retained \
    pair: TEST_RUNNER_ECHO_AEC_SPIKE=<dir> xcodebuild test -project \
    Echo.xcodeproj -scheme Echo -destination 'platform=macOS' \
    -parallel-testing-enabled NO -only-testing:EchoTests/AECOfflineSpikeTests. \
    The directory holds debug-kept-mic.m4a/debug-kept-system.m4a or \
    mic.wav/system.wav (see this file's header)
    """

    enum SpikeError: Error, CustomStringConvertible {
        case noPair(URL)

        var description: String {
            switch self {
            case .noPair(let url):
                return "No debug-kept-{mic,system}.m4a and no {mic,system}.wav under \(url.path)"
            }
        }
    }

    /// Reads the pair as 16 kHz mono Float, whichever of the two namings the
    /// directory uses. Both channels must be present — a single channel has
    /// no echo path to measure.
    static func loadPair(in directory: URL) throws -> (mic: [Float], system: [Float]) {
        let namings = [
            (mic: "debug-kept-mic.m4a", system: "debug-kept-system.m4a"),
            (mic: "mic.wav", system: "system.wav"),
        ]
        for naming in namings {
            let mic = directory.appending(path: naming.mic, directoryHint: .notDirectory)
            let system = directory.appending(path: naming.system, directoryHint: .notDirectory)
            guard FileManager.default.fileExists(atPath: mic.path),
                  FileManager.default.fileExists(atPath: system.path)
            else { continue }
            return (mic: try Fixtures.loadWAV(at: mic), system: try Fixtures.loadWAV(at: system))
        }
        throw SpikeError.noPair(directory)
    }
}

// MARK: - Probe (spike-local)

/// Decides, from the audio alone, whether the mic carries a delayed copy of
/// the system channel — and at what delay. Envelope-domain: the echo path is
/// a room and a speaker, so what survives it reliably is the loudness
/// contour, not the waveform.
nonisolated enum SpikeProbe {

    /// Envelope resolution. `EnergyEnvelope`'s 100 ms frames are far too
    /// coarse for a delay measured in tens of milliseconds.
    static let frameSeconds: Double = 0.005
    static let windowSeconds: Double = 10
    static let maxWindows = 6

    /// The reference must actually be playing for a window to say anything
    /// about the echo path.
    static let referenceFloor: Double = 0.01

    /// Bleed-shaped: the mic is markedly quieter than the reference over the
    /// window. Windows where the user is talking pollute the correlation.
    static let bleedRatioCeiling: Double = 0.5

    static let maxLagSeconds: Double = 0.4
    static let coherenceFloor: Double = 0.35
    static let agreementSeconds: Double = 0.025

    struct Window {
        var startSeconds: Double
        var micRMS: Double
        var systemRMS: Double
        var lagSeconds: Double
        var coherence: Double
    }

    struct Result {
        /// Every bleed-shaped window that was measured, in time order.
        var windows: [Window]
        /// How many candidate windows qualified before the even thinning.
        var candidateWindows: Int
        /// How many candidate windows the reference/ratio filter rejected.
        var rejectedWindows: Int
        /// The verdict: nil when no two windows agreed on a lag.
        var delaySeconds: Double?
        /// Median coherence of the agreeing cluster (0 without a verdict).
        var coherence: Double
        /// Start times of the agreeing cluster's windows — the stretches that
        /// are actually echo, and the only honest place to measure ERLE.
        var agreeingStarts: [Double]
    }

    /// Mean squares per 5 ms frame.
    static func envelope(_ samples: [Float]) -> [Double] {
        let frame = max(1, Int(AudioConstants.sampleRate * frameSeconds))
        var squares: [Double] = []
        squares.reserveCapacity(samples.count / frame + 1)
        var start = 0
        while start + frame <= samples.count {
            var sum = 0.0
            for i in start ..< (start + frame) { sum += Double(samples[i]) * Double(samples[i]) }
            squares.append(sum / Double(frame))
            start += frame
        }
        return squares
    }

    private static func rms(_ meanSquares: ArraySlice<Double>) -> Double {
        guard !meanSquares.isEmpty else { return 0 }
        return (meanSquares.reduce(0, +) / Double(meanSquares.count)).squareRoot()
    }

    /// The channel's own noise floor: the 10th-percentile 5 ms frame rms.
    ///
    /// It is the number that decides whether an ERLE figure is a shortfall or
    /// a ceiling. ERLE can only ever be as large as the ratio of a window's
    /// total energy to the part of it that is NOT echo, so a window that is
    /// half room noise caps at 3 dB no matter how perfectly the echo is
    /// subtracted. Cleaned output sitting at this floor means the echo is
    /// gone, whatever the dB figure says.
    static func noiseFloorRMS(_ samples: [Float]) -> Double {
        let sorted = envelope(samples).sorted()
        guard !sorted.isEmpty else { return 0 }
        return sorted[sorted.count / 10].squareRoot()
    }

    /// Rms over the given 10 s windows — the level an ERLE figure is about.
    static func windowsRMS(_ samples: [Float], starts: [Double]) -> Double {
        var sum = 0.0
        var count = 0
        for start in starts {
            let first = max(0, Int(start * AudioConstants.sampleRate))
            let last = min(samples.count, first + Int(windowSeconds * AudioConstants.sampleRate))
            guard first < last else { continue }
            for i in first ..< last { sum += Double(samples[i]) * Double(samples[i]) }
            count += last - first
        }
        guard count > 0 else { return 0 }
        return (sum / Double(count)).squareRoot()
    }

    /// Pearson correlation of two equal-length envelope slices. Zero variance
    /// on either side means there is nothing to correlate, not a match.
    static func correlation(_ a: ArraySlice<Double>, _ b: ArraySlice<Double>) -> Double {
        guard a.count == b.count, a.count > 1 else { return 0 }
        let n = Double(a.count)
        let meanA = a.reduce(0, +) / n
        let meanB = b.reduce(0, +) / n
        var cov = 0.0, varA = 0.0, varB = 0.0
        for (x, y) in zip(a, b) {
            let dx = x - meanA, dy = y - meanB
            cov += dx * dy
            varA += dx * dx
            varB += dy * dy
        }
        guard varA > 0, varB > 0 else { return 0 }
        return cov / (varA * varB).squareRoot()
    }

    /// The mirror image of the bleed-shaped selection: windows where the user
    /// is clearly the loud one. Nothing in them may be cancelled, so they are
    /// where damage would show up. Spike-only — the pre-pass never needs them.
    static func userSpeechWindowStarts(mic: [Float], system: [Float]) -> [Double] {
        let micEnvelope = envelope(mic)
        let systemEnvelope = envelope(system)
        let frames = min(micEnvelope.count, systemEnvelope.count)
        let windowFrames = Int(windowSeconds / frameSeconds)
        var candidates: [Int] = []
        var start = 0
        while start + windowFrames <= frames {
            let micRMS = rms(micEnvelope[start ..< start + windowFrames])
            let systemRMS = rms(systemEnvelope[start ..< start + windowFrames])
            if micRMS >= referenceFloor, micRMS >= 2 * systemRMS { candidates.append(start) }
            start += windowFrames
        }
        return spread(candidates, to: maxWindows).map { Double($0) * frameSeconds }
    }

    static func run(mic: [Float], system: [Float]) -> Result {
        let micEnvelope = envelope(mic)
        let systemEnvelope = envelope(system)
        let frames = min(micEnvelope.count, systemEnvelope.count)
        let windowFrames = Int(windowSeconds / frameSeconds)
        let maxLagFrames = Int(maxLagSeconds / frameSeconds)
        guard frames >= windowFrames else {
            return Result(
                windows: [], candidateWindows: 0, rejectedWindows: 0,
                delaySeconds: nil, coherence: 0, agreeingStarts: []
            )
        }

        // Bleed-shaped candidates first, then thin them out evenly so the
        // survivors are spread across the meeting rather than bunched in
        // whichever stretch happened to qualify first.
        var candidates: [Int] = []
        var rejected = 0
        var start = 0
        while start + windowFrames <= frames {
            let micRMS = rms(micEnvelope[start ..< start + windowFrames])
            let systemRMS = rms(systemEnvelope[start ..< start + windowFrames])
            if systemRMS >= referenceFloor, micRMS <= bleedRatioCeiling * systemRMS {
                candidates.append(start)
            } else {
                rejected += 1
            }
            start += windowFrames
        }
        let selected = spread(candidates, to: maxWindows)

        var windows: [Window] = []
        for start in selected {
            var bestLag = 0
            var bestCoherence = -1.0
            for lag in 0 ... maxLagFrames {
                let coherence = correlation(
                    micEnvelope[start + lag ..< start + windowFrames],
                    systemEnvelope[start ..< start + windowFrames - lag]
                )
                if coherence > bestCoherence {
                    bestCoherence = coherence
                    bestLag = lag
                }
            }
            windows.append(Window(
                startSeconds: Double(start) * frameSeconds,
                micRMS: rms(micEnvelope[start ..< start + windowFrames]),
                systemRMS: rms(systemEnvelope[start ..< start + windowFrames]),
                lagSeconds: Double(bestLag) * frameSeconds,
                coherence: bestCoherence
            ))
        }

        let strong = windows.filter { $0.coherence >= coherenceFloor }
        var bestCluster: [Window] = []
        for anchor in strong {
            let cluster = strong.filter { abs($0.lagSeconds - anchor.lagSeconds) <= agreementSeconds }
            if cluster.count > bestCluster.count { bestCluster = cluster }
        }
        guard bestCluster.count >= 2 else {
            return Result(
                windows: windows, candidateWindows: candidates.count, rejectedWindows: rejected,
                delaySeconds: nil, coherence: 0, agreeingStarts: []
            )
        }
        return Result(
            windows: windows,
            candidateWindows: candidates.count,
            rejectedWindows: rejected,
            delaySeconds: median(bestCluster.map(\.lagSeconds)),
            coherence: median(bestCluster.map(\.coherence)),
            agreeingStarts: bestCluster.map(\.startSeconds)
        )
    }

    /// Up to `limit` entries, evenly spaced across the input.
    static func spread(_ values: [Int], to limit: Int) -> [Int] {
        guard values.count > limit, limit > 0 else { return values }
        guard limit > 1 else { return [values[0]] }
        return (0 ..< limit).map { values[Int((Double($0) * Double(values.count - 1) / Double(limit - 1)).rounded())] }
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

// MARK: - Offline feeding (spike-local)

nonisolated enum SpikeAEC {

    static let frame = AECFixtureRunner.chunkSize

    /// The far-end reference re-timed by `shiftSamples`: positive DELAYS it
    /// (the reference arrives later, shrinking the delay the canceller must
    /// still find), negative ADVANCES it. Both directions are measured
    /// because "pre-advance" only pays off with the sign that actually
    /// shrinks the residual delay, and that is a measurement, not an opinion.
    static func retimed(_ system: [Float], by shiftSamples: Int, length: Int) -> [Float] {
        var out = [Float](repeating: 0, count: length)
        for i in 0 ..< length {
            let source = i - shiftSamples
            if source >= 0, source < system.count { out[i] = system[source] }
        }
        return out
    }

    /// Feeds the pair through the stage `passes` times without resetting,
    /// returning each pass's mic output trimmed back to the input length.
    /// Both channels are padded to a whole number of 10 ms frames first, so
    /// no sub-frame remainder carries across a pass boundary and misaligns
    /// the two streams.
    ///
    /// `warmUpSeconds` runs a leading slice through the stage first and
    /// discards its output — the cheaper convergence fallback: the filter is
    /// already adapted when the kept pass starts, without a full second copy
    /// of the meeting and without the mid-file → start-of-file discontinuity
    /// a whole extra pass creates.
    static func run(
        mic: [Float], far: [Float],
        through stage: any AECStage,
        passes: Int,
        warmUpSeconds: Double = 0
    ) -> [[Float]] {
        let padded = ((max(mic.count, far.count) + frame - 1) / frame) * frame
        var paddedMic = mic
        paddedMic.append(contentsOf: [Float](repeating: 0, count: padded - mic.count))
        var paddedFar = far
        paddedFar.append(contentsOf: [Float](repeating: 0, count: padded - far.count))

        let warmUp = min(padded, (Int(warmUpSeconds * AudioConstants.sampleRate) / frame) * frame)
        if warmUp > 0 {
            _ = AECFixtureRunner.process(
                mic: Array(paddedMic.prefix(warmUp)),
                system: Array(paddedFar.prefix(warmUp)),
                through: stage
            )
        }

        return (0 ..< passes).map { _ in
            let output = AECFixtureRunner.process(mic: paddedMic, system: paddedFar, through: stage)
            return Array(output.prefix(mic.count))
        }
    }

    /// Echo return loss enhancement over the given windows: how much energy
    /// the canceller removed there. Whole-file energy would be diluted by the
    /// user's own speech, which the canceller must NOT remove.
    static func erleDB(
        input: [Float], output: [Float],
        windowStarts: [Double], windowSeconds: Double
    ) -> Double {
        var inEnergy = 0.0, outEnergy = 0.0
        for startSeconds in windowStarts {
            let start = max(0, Int(startSeconds * AudioConstants.sampleRate))
            let end = min(min(input.count, output.count), start + Int(windowSeconds * AudioConstants.sampleRate))
            guard start < end else { continue }
            for i in start ..< end {
                inEnergy += Double(input[i]) * Double(input[i])
                outEnergy += Double(output[i]) * Double(output[i])
            }
        }
        guard inEnergy > 0, outEnergy > 0 else { return 0 }
        return 10 * log10(inEnergy / outEnergy)
    }
}

// MARK: - The spike

@Suite(.serialized, .enabled(if: AECSpike.isEnabled, AECSpike.gate))
struct AECOfflineSpikeTests {

    /// The delays left for AEC3 to find after the reference is re-timed by
    /// the probe's measured delay. 0.04 s is the plan's default (shrink the
    /// search as far as possible); the rest of the sweep exists because
    /// "smaller residual is easier" is a theory, and AEC3's own alignment
    /// machinery is entitled to disagree with it.
    static let residualTargets: [Double] = [0.04, 0.14, 0.24, 0.34, 0.44]

    /// Convergence strategies, measured against each other.
    private enum WarmUp: String, CaseIterable {
        /// Straight through, once: what the live path does today.
        case none
        /// The plan's fallback: converge on the first 60 s, then keep the
        /// output of one full pass.
        case prefix60
        /// The plan's default: two full passes, no reset, keep pass 2.
        case fullPass
    }

    private struct Variant {
        /// The delay AEC3 is left to find, in seconds.
        var residualSeconds: Double
        /// Reference re-timing, in samples (see `SpikeAEC.retimed`).
        var shiftSamples: Int
        var warmUp: WarmUp

        var name: String {
            String(format: "res%03.0fms/%@", residualSeconds * 1000, warmUp.rawValue)
        }
    }

    @Test func measureOfflineCancellationOnAKeptPair() throws {
        let directory = try #require(AECSpike.directory)
        let pair = try AECSpike.loadPair(in: directory)
        try #require(!pair.mic.isEmpty && !pair.system.isEmpty, "empty channel in \(directory.path)")

        print("[spike] \(directory.lastPathComponent)")
        print(String(
            format: "[spike] mic %.1fs, system %.1fs",
            Double(pair.mic.count) / AudioConstants.sampleRate,
            Double(pair.system.count) / AudioConstants.sampleRate
        ))

        let probe = SpikeProbe.run(mic: pair.mic, system: pair.system)
        print("[spike] probe: \(probe.candidateWindows) bleed-shaped candidates (\(probe.rejectedWindows) rejected), \(probe.windows.count) measured")
        for window in probe.windows {
            print(String(
                format: "[spike]   %@ t=%6.1fs micRMS=%.4f sysRMS=%.4f lag=%5.0fms coherence=%+.2f",
                probe.agreeingStarts.contains(window.startSeconds) ? "*" : " ",
                window.startSeconds, window.micRMS, window.systemRMS,
                window.lagSeconds * 1000, window.coherence
            ))
        }

        guard let delay = probe.delaySeconds else {
            print("[spike] VERDICT: no echo path (no two windows agreed above coherence \(SpikeProbe.coherenceFloor))")
            return
        }
        print(String(
            format: "[spike] VERDICT: echo at %.0fms, coherence %.2f, %d agreeing windows (* above)",
            delay * 1000, probe.coherence, probe.agreeingStarts.count
        ))

        let variants = Self.residualTargets.flatMap { residual in
            WarmUp.allCases.map {
                Variant(
                    residualSeconds: residual,
                    shiftSamples: Int((delay - residual) * AudioConstants.sampleRate),
                    warmUp: $0
                )
            }
        }

        let damageStarts = SpikeProbe.userSpeechWindowStarts(mic: pair.mic, system: pair.system)
        print("[spike] damage windows (user clearly dominant): \(damageStarts.map { String(format: "%.0fs", $0) }.joined(separator: " "))")

        // The ceiling check: how far the cleaned bleed windows can possibly
        // fall before they hit the mic's own room noise.
        let noiseFloor = SpikeProbe.noiseFloorRMS(pair.mic)
        let bleedInputRMS = SpikeProbe.windowsRMS(pair.mic, starts: probe.agreeingStarts)
        print(String(
            format: "[spike] mic noise floor %.5f rms; bleed windows in at %.5f rms → ERLE ceiling ≈ %.1f dB",
            noiseFloor, bleedInputRMS,
            noiseFloor > 0 ? 20 * log10(bleedInputRMS / noiseFloor) : 0
        ))
        print("[spike] ERLE (dB): bleed = the * windows; all = every measured window; damage MUST stay ≈0")

        for variant in variants {
            let far = SpikeAEC.retimed(pair.system, by: variant.shiftSamples, length: pair.mic.count)
            let stage = WebRTCAECStage()
            let output = SpikeAEC.run(
                mic: pair.mic, far: far, through: stage,
                passes: variant.warmUp == .fullPass ? 2 : 1,
                warmUpSeconds: variant.warmUp == .prefix60 ? 60 : 0
            ).last ?? pair.mic

            func erle(_ starts: [Double]) -> Double {
                SpikeAEC.erleDB(
                    input: pair.mic, output: output,
                    windowStarts: starts, windowSeconds: SpikeProbe.windowSeconds
                )
            }
            let perWindow = probe.windows.map { erle([$0.startSeconds]) }
            print(String(
                format: "[spike]   %-22@ bleed %5.2f  all %5.2f  damage %5.2f  outRMS %.5f  healthy=%@ | per-window %@",
                variant.name, erle(probe.agreeingStarts), erle(probe.windows.map(\.startSeconds)),
                erle(damageStarts),
                SpikeProbe.windowsRMS(output, starts: probe.agreeingStarts),
                stage.isHealthy ? "y" : "n",
                perWindow.map { String(format: "%.1f", $0) }.joined(separator: " ")
            ))

            #if DEBUG
            // Written so the result can be listened to, not just read.
            try FixtureRecorder.writeWAV(
                output,
                to: directory.appending(
                    path: String(
                        format: "aec-cleaned-mic-res%03.0f-%@.wav",
                        variant.residualSeconds * 1000, variant.warmUp.rawValue
                    ),
                    directoryHint: .notDirectory
                )
            )
            #endif
        }
        print("[spike] cleaned audio written as aec-cleaned-mic-res<ms>-<warmup>.wav")
    }
}
