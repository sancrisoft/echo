//
//  ExternalInputMeasurementTests.swift
//  EchoTests
//
//  SP-002 phase-1 confirmation experiment, executable form. Replays the
//  recorded device fixtures through the real gate-decision path and records a
//  per-fixture breakdown: transcribe/drop share by duration, the
//  duration-weighted failed-term histogram over dropped chunks, and level/shape
//  percentiles. It answers OQ1 (level vs shape) and OQ2 (earbuds Team dropout)
//  from the same numbers the permanent GateDiagnostics log carries.
//
//  Part B isolates the S2 max-magnitude downmix (ADR-004): it replays the DJI
//  native multi-channel take downmixed BOTH ways — the old averaging and the
//  new max-magnitude — so the before/after of the downmix fix is measured on
//  the real device signal, which mic.wav (already max-magnitude) cannot show.
//
//  Diagnostic, not a pass/fail gate: it requires only that fixtures produced
//  records, and writes the full report to EchoTests/sp002-measure-report.txt
//  (Swift Testing swallows `print` under xcodebuild; App Sandbox is off).
//

import AVFoundation
import Foundation
import Testing
@testable import Echo

struct ExternalInputMeasurementTests {

    /// Resolved from `#filePath` like `Fixtures.root`, so it lands next to this
    /// source in EchoTests/ regardless of the test host's temp dir.
    private static func reportPath(file: String = #filePath) -> String {
        URL(fileURLWithPath: file)
            .deletingLastPathComponent()
            .appendingPathComponent("sp002-measure-report.txt").path
    }

    private var lines: [String] = []
    private mutating func emit(_ line: String) { lines.append(line) }

    @Test(.enabled(if: Fixtures.available("parity-baseline-builtin"), Fixtures.instructions))
    mutating func measureExternalInputGateVerdicts() async throws {
        let scenarios = [
            "parity-baseline-builtin",
            "parity-dji-2cm",
            "parity-dji-20cm",
            "parity-dji-50cm",
            "external-ambient",
            "earbuds-in-out",
        ]

        emit("===== SP-002 phase-1 gate-verdict measurement =====")
        emit("[A] gate verdicts on the shipping mic.wav (already max-magnitude downmix)")
        for scenario in scenarios {
            guard Fixtures.available(scenario) else {
                emit("\(scenario): NOT RECORDED — skipped")
                continue
            }
            let pair = try Fixtures.load(scenario)
            try await report(scenario: scenario, channel: .microphone, samples: pair.mic)
            try await report(scenario: scenario, channel: .system, samples: pair.system)
        }

        emit("")
        emit("[B] downmix before/after on the DJI native multi-channel take")
        emit("    (averaging = the old downmix; maxmag = S2/ADR-004)")
        for scenario in ["parity-dji-2cm", "parity-dji-20cm", "parity-dji-50cm", "external-ambient"] {
            guard Fixtures.micNativeAvailable(scenario) else {
                emit("\(scenario): no mic-native.wav — skipped")
                continue
            }
            try await compareNativeDownmix(scenario: scenario)
        }
        emit("===== end =====")

        try lines.joined(separator: "\n").write(
            toFile: Self.reportPath(), atomically: true, encoding: .utf8
        )

        // ---- Confirmed-finding regression guards ----
        // These pin what the phase-1 measurement established, so the findings
        // can't silently rot: the DJI reaches parity only because of the
        // max-magnitude downmix, ambient stays gated out, and the earbuds Team
        // signal (when captured) transcribes — its dropout is capture-side.
        func transcribeSeconds(_ samples: [Float], on channel: AudioChannel) async -> Double {
            await Self.runGate(samples, on: channel)
                .filter { $0.verdict == .transcribe }
                .reduce(0.0) { $0 + $1.chunkDuration }
        }

        let baseline = try await transcribeSeconds(Fixtures.load("parity-baseline-builtin").mic, on: .microphone)
        try #require(baseline > 0)

        // OQ1 — DJI at 20 cm and 50 cm reach transcription parity with the
        // built-in baseline through the shipping (max-magnitude) mic path.
        for scenario in ["parity-dji-20cm", "parity-dji-50cm"] where Fixtures.available(scenario) {
            let dji = try await transcribeSeconds(Fixtures.load(scenario).mic, on: .microphone)
            #expect(dji >= 0.7 * baseline, "\(scenario) below parity: \(dji)s vs baseline \(baseline)s")
        }

        // OQ1 root cause — max-magnitude is load-bearing: the same DJI 20 cm
        // native take downmixed the OLD way (averaging) reproduces the total
        // silent dropout the user reported; max-magnitude restores it.
        if Fixtures.micNativeAvailable("parity-dji-20cm") {
            let native = try Fixtures.loadNativeWAV(at: Fixtures.micNativeURL("parity-dji-20cm"))
            let averaged = try await transcribeSeconds(
                Self.resampleTo16k(Self.averagingMono(native.channels), from: native.sampleRate), on: .microphone)
            let maxmag = try await transcribeSeconds(
                Self.resampleTo16k(Self.maxMagMono(native.channels), from: native.sampleRate), on: .microphone)
            #expect(averaged < 1.0, "averaging downmix should reproduce the dropout, got \(averaged)s")
            #expect(maxmag > 5.0, "max-magnitude downmix should restore transcription, got \(maxmag)s")
        }

        // False-positive guard — the external-mic ambient/quiet-room take stays
        // below the speech gates on both channels (no hallucinated transcript).
        if Fixtures.available("external-ambient") {
            let ambient = try await transcribeSeconds(Fixtures.load("external-ambient").mic, on: .microphone)
            #expect(ambient == 0, "ambient room tone leaked past the gates: \(ambient)s")
        }

        // OQ2 — the earbuds Team dropout is NOT a gate/level failure: the audio
        // the process tap DID capture transcribes cleanly. (The dropout is the
        // tap delivering far less than the take duration; see report Part A.)
        if Fixtures.available("earbuds-in-out") {
            let teamCaptured = try await transcribeSeconds(Fixtures.load("earbuds-in-out").system, on: .system)
            #expect(teamCaptured > 0, "captured earbuds Team audio should transcribe")
        }
    }

    // MARK: - Part A: gate verdicts on a channel

    private mutating func report(scenario: String, channel: AudioChannel, samples: [Float]) async throws {
        let records = await Self.runGate(samples, on: channel)
        let takeSeconds = Double(samples.count) / AudioConstants.sampleRate
        guard !records.isEmpty else {
            emit(String(format: "%@ %@ take=%.1fs NO RECORDS (all sub-chunk / never endpointed)",
                        scenario, channel.rawValue, takeSeconds))
            return
        }

        let total = records.reduce(0.0) { $0 + $1.chunkDuration }
        let transcribed = records.filter { $0.verdict == .transcribe }.reduce(0.0) { $0 + $1.chunkDuration }
        let dropped = records.filter { $0.verdict == .drop }
        let droppedSeconds = dropped.reduce(0.0) { $0 + $1.chunkDuration }

        emit(String(
            format: "%@ %@ chunks=%d take=%.1fs transcribe=%.1fs(%.0f%%) drop=%.1fs(%.0f%%)",
            scenario, channel.rawValue, records.count, takeSeconds,
            transcribed, total > 0 ? 100 * transcribed / total : 0,
            droppedSeconds, total > 0 ? 100 * droppedSeconds / total : 0
        ))

        if droppedSeconds > 0 {
            var line = "  drop-fail-share:"
            for term in GateTerm.applicableTerms(for: channel) {
                let share = dropped
                    .filter { $0.failedTerms.contains(term) }
                    .reduce(0.0) { $0 + $1.chunkDuration } / droppedSeconds
                if share > 0.001 { line += String(format: " %@=%.0f%%", term.rawValue, 100 * share) }
            }
            emit(line)
        }

        func pct(_ pick: (AudioStats) -> Float, _ f: Double) -> Float {
            Self.weightedPercentile(records.map { (pick($0.stats), $0.chunkDuration) }, fraction: f)
        }
        emit(String(
            format: "  rms p50=%.4f p90=%.4f | peak p50=%.4f p90=%.4f | crest p50=%.1f | speechRatio p90=%.2f",
            pct(\.rms, 0.5), pct(\.rms, 0.9),
            pct(\.peak, 0.5), pct(\.peak, 0.9),
            pct(\.crestFactor, 0.5), pct(\.speechWindowRatio, 0.9)
        ))
    }

    // MARK: - Part B: downmix before/after on the native take

    private mutating func compareNativeDownmix(scenario: String) async throws {
        let native = try Fixtures.loadNativeWAV(at: Fixtures.micNativeURL(scenario))
        let perChannelRMS = native.channels.map { SignalMetrics.rms($0) }
        emit(String(
            format: "%@ native: %dch @%.0fk  per-channel rms=[%@]",
            scenario, native.channels.count, native.sampleRate / 1000,
            perChannelRMS.map { String(format: "%.4f", $0) }.joined(separator: ", ")
        ))

        let averaging = Self.resampleTo16k(Self.averagingMono(native.channels), from: native.sampleRate)
        let maxmag = Self.resampleTo16k(Self.maxMagMono(native.channels), from: native.sampleRate)

        for (label, samples) in [("averaging", averaging), ("maxmag  ", maxmag)] {
            let records = await Self.runGate(samples, on: .microphone)
            let total = records.reduce(0.0) { $0 + $1.chunkDuration }
            let transcribed = records.filter { $0.verdict == .transcribe }.reduce(0.0) { $0 + $1.chunkDuration }
            let p90rms = Self.weightedPercentile(records.map { ($0.stats.rms, $0.chunkDuration) }, fraction: 0.9)
            let p90peak = Self.weightedPercentile(records.map { ($0.stats.peak, $0.chunkDuration) }, fraction: 0.9)
            emit(String(
                format: "  %@ transcribe=%.1fs(%.0f%%) rms p90=%.4f peak p90=%.4f",
                label, transcribed, total > 0 ? 100 * transcribed / total : 0, p90rms, p90peak
            ))
        }
    }

    // MARK: - Shared

    private static func runGate(_ samples: [Float], on channel: AudioChannel) async -> [GateDecisionRecord] {
        let sink = CollectingGateSink()
        let pipeline = LiveInputMonitor(gateDiagnostics: sink)
        var offset = 0
        while offset < samples.count {
            let end = min(offset + AECFixtureRunner.chunkSize, samples.count)
            await pipeline.ingest(Array(samples[offset ..< end]), from: channel)
            offset = end
        }
        await pipeline.stop()
        return sink.records
    }

    private static func averagingMono(_ channels: [[Float]]) -> [Float] {
        guard let count = channels.map(\.count).min(), !channels.isEmpty else { return [] }
        let n = Float(channels.count)
        return (0 ..< count).map { i in channels.reduce(Float(0)) { $0 + $1[i] } / n }
    }

    private static func maxMagMono(_ channels: [[Float]]) -> [Float] {
        guard let count = channels.map(\.count).min(), !channels.isEmpty else { return [] }
        return (0 ..< count).map { i in
            var selected: Float = 0
            for ch in channels where abs(ch[i]) > abs(selected) { selected = ch[i] }
            return selected
        }
    }

    private static func resampleTo16k(_ mono: [Float], from rate: Double) -> [Float] {
        guard !mono.isEmpty,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(mono.count)),
              let resampler = BufferResampler(from: format)
        else { return [] }
        buffer.frameLength = AVAudioFrameCount(mono.count)
        mono.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: mono.count) }
        return resampler.resample(buffer) ?? []
    }

    private static func weightedPercentile(_ pairs: [(value: Float, weight: Double)], fraction: Double) -> Float {
        let sorted = pairs.filter { $0.weight > 0 }.sorted { $0.value < $1.value }
        guard !sorted.isEmpty else { return 0 }
        let totalWeight = sorted.reduce(0.0) { $0 + $1.weight }
        let target = fraction * totalWeight
        var cumulative = 0.0
        for pair in sorted {
            cumulative += pair.weight
            if cumulative >= target { return pair.value }
        }
        return sorted.last!.value
    }
}
