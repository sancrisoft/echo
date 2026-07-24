//
//  GateDiagnosticsTests.swift
//  EchoTests
//
//  SP-002 S1: per-chunk speech-gate decision diagnostics. The pure decision
//  tests run the real stats arithmetic on constructed sample arrays (same
//  reasoning that lets TranscriptDedupTests use constructed segments — this
//  is arithmetic on a pure function; audio realism lives in the fixture
//  tests below). Constructed audio is never checked in or presented as a
//  fixture.
//

import Foundation
import Testing
@testable import Echo

/// Collecting sink for tests. The pipeline actor calls `record` from its
/// executor while the test reads from the main actor, so access is
/// lock-guarded (the sink contract requires thread safety, not isolation).
nonisolated final class CollectingGateSink: GateDiagnosticsSink, @unchecked Sendable {

    private let lock = NSLock()
    private var storage: [GateDecisionRecord] = []

    func record(_ record: GateDecisionRecord) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(record)
    }

    var records: [GateDecisionRecord] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

struct GateDiagnosticsTests {

    // MARK: - Pure decision logic (constructed arrays through the real stats)

    /// Silence must fail the hard floor (glossary: the absolute silence floor
    /// of the speech gates) on the You channel and be dropped.
    @Test func silenceFailsTheHardFloorTermsAndDrops() {
        let stats = AudioStats.compute(from: [Float](repeating: 0, count: 16_000))
        let record = GateDecisionRecord(channel: .microphone, chunkDuration: 1.0, stats: stats)

        #expect(record.verdict == .drop)
        #expect(record.failedTerms.contains(.hardFloorRMS))
        #expect(record.failedTerms.contains(.hardFloorPeak))
    }

    /// A loud burst pattern with sparse peaks — energy in ~55% of windows,
    /// silence between — is the speech shape the gates were calibrated for
    /// and must pass every term on the You channel.
    @Test func loudSpeechShapedSignalPassesEveryTermAndTranscribes() {
        let stats = AudioStats.compute(from: Self.burstSignal(onAmplitude: 0.1, spike: 0.4))
        let record = GateDecisionRecord(channel: .microphone, chunkDuration: 1.08, stats: stats)

        #expect(record.verdict == .transcribe)
        #expect(record.failedTerms.isEmpty)
    }

    /// A steady tone at speech-adjacent level: hot enough for the level terms,
    /// but flat (crest ~1.41, no window dynamics) — the "loud ambient noise"
    /// profile the shape terms exist to reject. Level terms must pass and the
    /// failure must be attributed to the shape terms alone (SP-002 OQ1:
    /// level-vs-shape attribution).
    @Test func loudFlatSignalFailsOnlyShapeAndLoudnessCapTerms() {
        let stats = AudioStats.compute(from: Self.sine(amplitude: 0.045))
        let record = GateDecisionRecord(channel: .microphone, chunkDuration: 1.08, stats: stats)

        #expect(record.verdict == .drop)
        #expect(Set(record.failedTerms) == [
            .clearSpeechWindowRatio, .clearSpeechCrestFactor, .clearSpeechDynamics,
            .loudFallbackPeak, .loudFallbackWindowRatio,
        ])
    }

    /// The same flat tone must not sneak through the Team channel's more
    /// permissive fallback either — its speech-window ratio term fails, so
    /// loud ambient noise never becomes transcript text on any channel.
    @Test func loudFlatSignalAlsoDropsOnTheSystemChannel() {
        let stats = AudioStats.compute(from: Self.sine(amplitude: 0.045))
        let record = GateDecisionRecord(channel: .system, chunkDuration: 1.08, stats: stats)

        #expect(record.verdict == .drop)
        #expect(record.failedTerms.contains(.systemFallbackWindowRatio))
    }

    /// A speech-shaped burst pattern at honest external-mic level: correct
    /// shape (bursty windows, healthy crest, real dynamics) but too quiet for
    /// the level terms. This is the silent-dropout signature SP-002's
    /// experiment measures — the diagnostics must attribute it to the level
    /// terms alone, with every shape term reported as passing.
    @Test func quietSpeechShapedSignalFailsOnlyLevelTermsOnTheMicChannel() {
        let stats = AudioStats.compute(from: Self.burstSignal(onAmplitude: 0.013, spike: 0.032))
        let record = GateDecisionRecord(channel: .microphone, chunkDuration: 1.08, stats: stats)

        #expect(record.verdict == .drop)
        #expect(Set(record.failedTerms) == [
            .clearSpeechRMS, .clearSpeechPeak,
            .loudFallbackRMS, .loudFallbackPeak,
        ])
    }

    /// The same quiet speech-shaped signal on the Team channel clears the
    /// system-only fallback (meeting audio is trusted at a lower bar), while
    /// the record still lists the failed clear/loud level terms — failed
    /// terms are reported independently of the disjunct that rescued the
    /// verdict, so level-vs-shape profiles stay readable per chunk.
    @Test func quietSpeechShapedSignalIsRescuedByTheSystemFallback() {
        let stats = AudioStats.compute(from: Self.burstSignal(onAmplitude: 0.013, spike: 0.032))
        let record = GateDecisionRecord(channel: .system, chunkDuration: 1.08, stats: stats)

        #expect(record.verdict == .transcribe)
        #expect(Set(record.failedTerms) == [
            .clearSpeechRMS, .clearSpeechPeak,
            .loudFallbackRMS, .loudFallbackPeak,
        ])
    }

    // MARK: - Full path through the public ingest interface

    /// Two seconds of silence through the real ingest → endpoint → gate path
    /// must surface as exactly two per-chunk drop records on the injected
    /// sink. Silent chunks never reach the transcriber, so no Whisper model
    /// is needed (the gate runs first — that ordering is the silent-dropout
    /// mechanism SP-002 instruments).
    @Test func silentIngestEmitsOneDropRecordPerFinalizedChunk() async {
        let sink = CollectingGateSink()
        let pipeline = TranscriptionPipeline(gateDiagnostics: sink)
        await pipeline.prepareForGateTestingWithoutTranscriber()

        let chunk = [Float](repeating: 0, count: AECFixtureRunner.chunkSize)
        let totalSamples = 2 * Int(AudioConstants.sampleRate)
        for _ in 0 ..< (totalSamples / AECFixtureRunner.chunkSize) {
            await pipeline.ingest(chunk, from: .microphone)
        }

        let records = sink.records
        #expect(records.count == 2)
        for record in records {
            #expect(record.channel == .microphone)
            #expect(record.verdict == .drop)
            #expect(record.failedTerms.contains(.hardFloorRMS))
            #expect(record.failedTerms.contains(.hardFloorPeak))
            #expect(abs(record.chunkDuration - 1.0) < 0.001)
            #expect(record.stats.rms == 0)
        }
    }

    /// Team-channel decisions carry the correct channel and include the
    /// system-only fallback terms in their breakdown — the input-health
    /// classifier must be able to attribute an earbuds-style Team dropout
    /// (SP-002 success criterion: never a silently mute Team channel).
    @Test func systemChannelRecordsCarryTheSystemFallbackBreakdown() async {
        let sink = CollectingGateSink()
        let pipeline = TranscriptionPipeline(gateDiagnostics: sink)
        await pipeline.prepareForGateTestingWithoutTranscriber()

        let chunk = [Float](repeating: 0, count: AECFixtureRunner.chunkSize)
        for _ in 0 ..< (Int(AudioConstants.sampleRate) / AECFixtureRunner.chunkSize) {
            await pipeline.ingest(chunk, from: .system)
        }

        let records = sink.records
        #expect(records.count == 1)
        #expect(records.first?.channel == .system)
        #expect(records.first?.verdict == .drop)
        #expect(records.first?.failedTerms.contains(.systemFallbackRMS) == true)
        #expect(records.first?.failedTerms.contains(.systemFallbackPeak) == true)
        #expect(records.first?.failedTerms.contains(.systemFallbackWindowRatio) == true)
    }

    // MARK: - Permanent os.Logger sink (US-12)

    /// The permanent diagnostic line must carry everything a field report
    /// needs to attribute a missing transcription: channel, verdict, duration,
    /// the derived metrics, and the failed terms — on one compact line.
    @Test func logLineCarriesChannelVerdictMetricsAndFailedTerms() {
        let silent = GateDecisionRecord(
            channel: .microphone,
            chunkDuration: 1.0,
            stats: AudioStats.compute(from: [Float](repeating: 0, count: 16_000))
        )
        let line = OSLogGateDiagnosticsSink.line(for: silent)

        #expect(!line.contains("\n"))
        #expect(line.contains("microphone"))
        #expect(line.contains("drop"))
        #expect(line.contains("dur=1.00s"))
        for metric in ["rms=", "peak=", "crest=", "speech=", "strong=", "active=", "floor=", "dyn="] {
            #expect(line.contains(metric), "missing \(metric)")
        }
        #expect(line.contains(GateTerm.hardFloorRMS.rawValue))
        #expect(line.contains(GateTerm.hardFloorPeak.rawValue))

        let speech = GateDecisionRecord(
            channel: .system,
            chunkDuration: 1.08,
            stats: AudioStats.compute(from: Self.burstSignal(onAmplitude: 0.1, spike: 0.4))
        )
        let speechLine = OSLogGateDiagnosticsSink.line(for: speech)
        #expect(speechLine.contains("system"))
        #expect(speechLine.contains("transcribe"))
        #expect(speechLine.contains("failed=none"))
    }

    // MARK: - Privacy shape guard (SP-002 NFR Privacy)

    /// A record is derived numbers and enums only: no stored audio buffer and
    /// no free-form text anywhere in its value tree. Guards against samples
    /// or transcript snippets ever being attached to the diagnostics.
    /// (Empty arrays cast to any element type at runtime, so the buffer check
    /// flags non-empty Float arrays — an empty one carries no audio anyway.)
    @Test func recordsContainNoAudioBuffersAndNoText() {
        let samples = Self.burstSignal(onAmplitude: 0.1, spike: 0.4)
        let transcribed = GateDecisionRecord(
            channel: .system, chunkDuration: 1.08, stats: AudioStats.compute(from: samples)
        )
        let dropped = GateDecisionRecord(
            channel: .microphone, chunkDuration: 1.0,
            stats: AudioStats.compute(from: [Float](repeating: 0, count: 16_000))
        )

        var frontier: [Any] = [transcribed, dropped]
        while let value = frontier.popLast() {
            #expect((value as? [Float])?.isEmpty != false, "record stores an audio buffer: \(type(of: value))")
            #expect(!(value is String), "record stores free-form text: \(type(of: value))")
            frontier.append(contentsOf: Mirror(reflecting: value).children.map(\.value))
        }
    }

    // MARK: - Fixture verdict profiles (real takes, SP-001 fixture suite)

    /// Replays the bleed-only raw mic take (real speaker bleed, no AEC)
    /// through the public ingest path at capture cadence: every finalized
    /// chunk must yield exactly one record, so the records account for the
    /// whole take — the "no unmeasured chunk" property that makes silent
    /// dropout impossible to miss in the diagnostics.
    @Test(.enabled(if: Fixtures.available("bleed-only"), Fixtures.instructions))
    func bleedOnlyRawMicTakeIsFullyCoveredByPerChunkRecords() async throws {
        let take = try Fixtures.loadWAV(at: Fixtures.micURL("bleed-only"))
        let sink = CollectingGateSink()
        let pipeline = TranscriptionPipeline(gateDiagnostics: sink)
        await pipeline.prepareForGateTestingWithoutTranscriber()

        await Self.replay(take, into: pipeline, on: .microphone)

        let records = sink.records
        #expect(!records.isEmpty)
        #expect(records.allSatisfy { $0.channel == .microphone })
        let covered = records.reduce(0) { $0 + $1.chunkDuration }
        let takeDuration = Double(take.count) / AudioConstants.sampleRate
        #expect(abs(covered - takeDuration) < 0.01, "records cover \(covered)s of a \(takeDuration)s take")
    }

    /// The monologue take is the built-in-mic happy path: real user speech
    /// at conversational distance must be majority-transcribed. Guards the
    /// SP-002 "built-in path unchanged" criterion at the gate level — if the
    /// diagnostics ever showed this take majority-dropped, the gates (or the
    /// instrumentation) regressed.
    @Test(.enabled(if: Fixtures.available("monologue"), Fixtures.instructions))
    func monologueMicTakeIsMajorityTranscribedByDuration() async throws {
        let take = try Fixtures.loadWAV(at: Fixtures.micURL("monologue"))
        let sink = CollectingGateSink()
        let pipeline = TranscriptionPipeline(gateDiagnostics: sink)
        await pipeline.prepareForGateTestingWithoutTranscriber()

        await Self.replay(take, into: pipeline, on: .microphone)

        let records = sink.records
        let total = records.reduce(0) { $0 + $1.chunkDuration }
        let transcribed = records.filter { $0.verdict == .transcribe }.reduce(0) { $0 + $1.chunkDuration }
        try #require(total > 0)
        #expect(records.contains { $0.verdict == .transcribe })
        #expect(
            transcribed / total >= 0.5,
            "monologue speech mostly gated out: \(transcribed)s of \(total)s transcribable"
        )
    }

    // MARK: - Constructed signals

    /// Feeds a take through the public ingest path in capture-sized chunks
    /// (AECFixtureRunner's 10 ms convention) and flushes the tail with `stop`,
    /// mirroring a real session end.
    private static func replay(
        _ samples: [Float],
        into pipeline: TranscriptionPipeline,
        on channel: AudioChannel
    ) async {
        var offset = 0
        while offset < samples.count {
            let end = min(offset + AECFixtureRunner.chunkSize, samples.count)
            await pipeline.ingest(Array(samples[offset ..< end]), from: channel)
            offset = end
        }
        await pipeline.stop()
    }

    /// Deterministic burst pattern aligned to the stats probe window: cycles
    /// of five "on" windows (a square wave at `onAmplitude`, so window RMS ==
    /// `onAmplitude` exactly) followed by four silent windows, with a single
    /// `spike` sample setting the global peak. 36 windows ≈ 1.08 s.
    private static func burstSignal(onAmplitude: Float, spike: Float) -> [Float] {
        let window = AudioStats.probeSamples
        var samples: [Float] = []
        samples.reserveCapacity(36 * window)
        for cycle in 0 ..< 4 {
            for windowInCycle in 0 ..< 9 {
                let on = windowInCycle < 5
                for i in 0 ..< window {
                    let sign: Float = i.isMultiple(of: 2) ? 1 : -1
                    samples.append(on ? onAmplitude * sign : 0)
                }
                if cycle == 0, windowInCycle == 0 {
                    samples[samples.count - window / 2] = spike
                }
            }
        }
        return samples
    }

    /// A 200 Hz sine — 6 full cycles per probe window, so every window has
    /// identical RMS (amplitude / √2) and the sampled peak is exact.
    private static func sine(amplitude: Float) -> [Float] {
        let count = 36 * AudioStats.probeSamples
        return (0 ..< count).map { amplitude * sin(2 * .pi * 200 * Float($0) / 16_000) }
    }
}
