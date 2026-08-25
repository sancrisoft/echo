//
//  FixtureSupport.swift
//  EchoTests
//
//  Discovery, loading, and signal helpers for the SP-001 and SP-002 fixture
//  suites. Fixtures are real hardware recordings placed at
//  Fixtures/{scenario}/mic.wav|system.wav (plus the optional
//  pre-downmix mic-native.wav for multi-channel devices, SP-002) per the
//  README — never synthesized (project rule: no simulated audio data). Tests
//  gate on `Fixtures.available(_:)` and skip with instructions until the set
//  is recorded.
//

import AVFoundation
import Foundation
import Testing
@testable import Echo

nonisolated enum Fixtures {

    /// Skip reason shown while the fixture set is not recorded yet.
    static let instructions: Comment = "Record fixtures per Fixtures/README.md"

    /// Resolved from this source file, not the test bundle: fixtures are
    /// repository content, and discovery must work without relying on Xcode
    /// resource copying.
    ///
    /// They live at the repository root, deliberately outside `EchoTests/`:
    /// that folder is a file-system-synchronized group, so anything under it
    /// is copied into the test bundle — and every scenario's `mic.wav` would
    /// then land on the same flattened path, failing the build with "Multiple
    /// commands produce …/mic.wav". Nothing here reads the bundle, so the
    /// files have no business being in it.
    static var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // EchoTests/
            .deletingLastPathComponent()   // repository root
            .appendingPathComponent("Fixtures", isDirectory: true)
    }

    static func folder(_ scenario: String) -> URL {
        root.appendingPathComponent(scenario, isDirectory: true)
    }

    static func micURL(_ scenario: String) -> URL {
        folder(scenario).appendingPathComponent("mic.wav")
    }

    static func systemURL(_ scenario: String) -> URL {
        folder(scenario).appendingPathComponent("system.wav")
    }

    /// The pre-downmix multi-channel mic take (SP-002 Testing Decisions).
    /// Only exists for scenarios recorded on a multi-channel device — the
    /// recorder writes nothing for mono devices — so it never participates
    /// in `available(_:)`.
    static func micNativeURL(_ scenario: String) -> URL {
        folder(scenario).appendingPathComponent("mic-native.wav")
    }

    /// A scenario is available only as a complete pair. `mic-native.wav` is
    /// deliberately not part of this: it is an optional extra (see
    /// `micNativeURL`), checked separately by the tests that need it.
    static func available(_ scenario: String) -> Bool {
        FileManager.default.fileExists(atPath: micURL(scenario).path)
            && FileManager.default.fileExists(atPath: systemURL(scenario).path)
    }

    /// Whether the optional native multi-channel take was recorded for the
    /// scenario (ADR-004's realism check gates on this, not `available`).
    static func micNativeAvailable(_ scenario: String) -> Bool {
        FileManager.default.fileExists(atPath: micNativeURL(scenario).path)
    }

    static func load(_ scenario: String) throws -> (mic: [Float], system: [Float]) {
        (mic: try loadWAV(at: micURL(scenario)), system: try loadWAV(at: systemURL(scenario)))
    }

    // MARK: - Meeting transcript samples (summary parity suite)

    /// Skip reason while the meeting-sample transcripts are not copied yet.
    static let meetingSampleInstructions: Comment =
        "Copy the meeting samples per Fixtures/README.md (meeting transcript samples section)"

    /// A real meeting transcript as plain text (blank-line-separated
    /// paragraphs) at `Fixtures/meeting-samples/<name>.txt` — the Notion
    /// reference pairs' transcripts, local-only like every fixture.
    static func meetingSampleURL(_ name: String) -> URL {
        root.appendingPathComponent("meeting-samples", isDirectory: true)
            .appendingPathComponent("\(name).txt")
    }

    static func meetingSampleAvailable(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: meetingSampleURL(name).path)
    }

    static func loadMeetingSampleText(_ name: String) throws -> String {
        try String(contentsOf: meetingSampleURL(name), encoding: .utf8)
    }

    /// Where the parity suite writes each generated document for human
    /// side-by-side review against the Notion reference (overwritten per run).
    static func meetingSampleOutputURL(_ name: String) -> URL {
        root.appendingPathComponent("meeting-samples", isDirectory: true)
            .appendingPathComponent("output-\(name).md")
    }

    enum LoadError: Error {
        case unreadable(URL)
        case unsupportedFormat(URL)
    }

    /// Reads a WAV into 16 kHz mono Float samples, downmixing/resampling if
    /// the file is not already in the canonical capture format.
    static func loadWAV(at url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(max(file.length, 1))
        ) else { throw LoadError.unreadable(url) }
        try file.read(into: buffer)

        let format = file.processingFormat
        if format.sampleRate == AudioConstants.sampleRate, format.channelCount == 1 {
            guard let channel = buffer.floatChannelData else { throw LoadError.unsupportedFormat(url) }
            return Array(UnsafeBufferPointer(start: channel[0], count: Int(buffer.frameLength)))
        }

        let mono = AudioDownmixer.toMono(buffer) ?? buffer
        guard let resampler = BufferResampler(from: mono.format),
              let samples = resampler.resample(mono)
        else { throw LoadError.unsupportedFormat(url) }
        return samples
    }

    /// Reads a WAV preserving its native channel layout and sample rate — the
    /// `mic-native.wav` loader. ADR-004's realism check replays these channels
    /// through the production downmix, so nothing here may mix or resample.
    static func loadNativeWAV(at url: URL) throws -> (channels: [[Float]], sampleRate: Double) {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(max(file.length, 1))
        ) else { throw LoadError.unreadable(url) }
        try file.read(into: buffer)

        guard let source = buffer.floatChannelData else { throw LoadError.unsupportedFormat(url) }
        let frames = Int(buffer.frameLength)
        let channels = (0 ..< Int(buffer.format.channelCount)).map {
            Array(UnsafeBufferPointer(start: source[$0], count: frames))
        }
        return (channels: channels, sampleRate: file.processingFormat.sampleRate)
    }
}

nonisolated enum SignalMetrics {

    static func rms(_ samples: ArraySlice<Float>) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for sample in samples { sum += sample * sample }
        return (sum / Float(samples.count)).squareRoot()
    }

    static func rms(_ samples: [Float]) -> Float { rms(samples[...]) }

    static func peak(_ samples: ArraySlice<Float>) -> Float {
        samples.reduce(0) { max($0, abs($1)) }
    }

    static func peak(_ samples: [Float]) -> Float { peak(samples[...]) }

    /// Mean-square energy — what the SP-001 double-talk criterion compares.
    static func energy(_ samples: ArraySlice<Float>) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for sample in samples { sum += sample * sample }
        return sum / Float(samples.count)
    }
}

/// Replays a fixture pair through an `AECStage` in interleaved 10 ms chunks,
/// mirroring the real capture cadence. Far end is fed first in each step:
/// in production the reference copy is taken from the system stream before
/// its bleed reaches the mic.
nonisolated enum AECFixtureRunner {

    /// 10 ms at 16 kHz (ADR-002).
    static let chunkSize = 160

    static func process(mic: [Float], system: [Float], through stage: any AECStage) -> [Float] {
        var output: [Float] = []
        output.reserveCapacity(mic.count)
        var offset = 0
        let total = max(mic.count, system.count)
        while offset < total {
            if offset < system.count {
                stage.feedFarEnd(Array(system[offset ..< min(offset + chunkSize, system.count)]))
            }
            if offset < mic.count {
                output += stage.processMicSamples(Array(mic[offset ..< min(offset + chunkSize, mic.count)]))
            }
            offset += chunkSize
        }
        return output
    }
}

// MARK: - Plumbing tests

/// These validate the harness itself and always run. The temp-dir WAV below
/// is generated at test runtime purely to exercise writer/loader plumbing —
/// synthetic audio is never checked in or presented as a fixture.
struct FixtureSupportTests {

    #if DEBUG
    @Test func wavRoundTripPreservesCanonical16kMonoSamples() throws {
        // Deterministic ramp: exercises the real fixture writer against the
        // real fixture loader, sample for sample.
        let samples: [Float] = (0 ..< 1600).map { Float($0 % 320) / 320 - 0.5 }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("echo-wav-plumbing-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }

        try FixtureRecorder.writeWAV(samples, to: url)
        let loaded = try Fixtures.loadWAV(at: url)

        #expect(loaded.count == samples.count)
        #expect(zip(loaded, samples).allSatisfy { abs($0 - $1) <= 1e-6 })
    }

    @Test func nativeWAVRoundTripPreservesChannelsAndSampleRate() throws {
        // Two distinct deterministic ramps: a writer that swapped, merged,
        // or dropped a channel could not round-trip both. 48 kHz stereo is
        // the DJI receiver's native shape (SP-002 / ADR-004).
        let left: [Float] = (0 ..< 4800).map { Float($0 % 480) / 480 - 0.5 }
        let right: [Float] = (0 ..< 4800).map { 0.5 - Float($0 % 240) / 240 }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("echo-native-plumbing-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }

        try FixtureRecorder.writeWAV(channels: [left, right], sampleRate: 48_000, to: url)
        let native = try Fixtures.loadNativeWAV(at: url)

        #expect(native.sampleRate == 48_000)
        #expect(native.channels.count == 2)
        #expect(native.channels[0].count == left.count)
        #expect(native.channels[1].count == right.count)
        #expect(zip(native.channels[0], left).allSatisfy { abs($0 - $1) <= 1e-6 })
        #expect(zip(native.channels[1], right).allSatisfy { abs($0 - $1) <= 1e-6 })
    }

    @Test func nativeWriterRejectsRaggedChannels() {
        #expect(throws: (any Error).self) {
            try FixtureRecorder.writeWAV(
                channels: [[0.1, 0.2, 0.3], [0.1]],
                sampleRate: 48_000,
                to: FileManager.default.temporaryDirectory
                    .appendingPathComponent("echo-native-ragged-\(UUID().uuidString).wav")
            )
        }
    }
    #endif

    @Test func fixtureRootSitsOutsideTheTestTargetsFolder() {
        #expect(Fixtures.root.path.hasSuffix("/Fixtures"))
        #expect(!Fixtures.root.path.contains("EchoTests"))
    }

    @Test func micNativeURLResolvesInsideTheScenarioFolder() {
        let url = Fixtures.micNativeURL("parity-dji-20cm")
        #expect(url.path.hasSuffix("/Fixtures/parity-dji-20cm/mic-native.wav"))
    }

    @Test func micNativeIsAbsentForUnrecordedScenarios() {
        #expect(!Fixtures.micNativeAvailable("no-such-scenario"))
    }

    @Test(.enabled(if: Fixtures.available("bleed-only"), Fixtures.instructions))
    func pairAvailabilityNeverRequiresTheOptionalNativeTake() {
        // bleed-only is recorded on the built-in (mono) mic: the pair is
        // complete and no mic-native.wav exists — availability must hold.
        #expect(Fixtures.available("bleed-only"))
        #expect(!Fixtures.micNativeAvailable("bleed-only"))
    }

    @Test func missingScenarioIsUnavailable() {
        #expect(!Fixtures.available("no-such-scenario"))
    }

    @Test func loadingAMissingWAVThrows() {
        #expect(throws: (any Error).self) {
            try Fixtures.loadWAV(at: Fixtures.micURL("no-such-scenario"))
        }
    }

    @Test func signalMetricsMatchHandComputedValues() {
        let square: [Float] = [0.5, -0.5, 0.5, -0.5]
        #expect(SignalMetrics.rms(square) == 0.5)
        #expect(SignalMetrics.energy(square[...]) == 0.25)
        #expect(SignalMetrics.peak([0.1, -0.9, 0.3]) == 0.9)
        #expect(SignalMetrics.rms([]) == 0)
        #expect(SignalMetrics.peak([]) == 0)
    }

    @Test func fixtureRunnerPreservesSampleOrderThroughPassthrough() {
        // 500 samples: not a multiple of the 160-sample chunk on purpose.
        let mic: [Float] = (0 ..< 500).map { Float($0) / 500 }
        let system = [Float](repeating: 0, count: 500)

        let output = AECFixtureRunner.process(mic: mic, system: system, through: PassthroughAECStage())
        #expect(output == mic)
    }
}
