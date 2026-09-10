//
//  RecordingAcceptanceSupport.swift
//  RecordingTests
//
//  Harness plumbing for the two suites that replay real recordings through
//  BOTH halves of the pipeline: `Audio`'s echo-cancellation stage and then
//  `Transcription`'s Parakeet pass. No package below `Recording` may import
//  Audio and Transcription at once, so this is the lowest one that can host
//  them (docs/architecture/v2-architecture.md §3, the Audio entry, "Not here,
//  and where each goes").
//
//  Kept apart from `RecordingTestSupport.swift` on purpose: that file is the
//  hostless unit harness and touches nothing outside a `TemporaryDirectory`,
//  while this one resolves the REAL models directory. That resolution is the
//  only thing here that looks at the app's data folder, it is a pure
//  existence check inside `ParakeetModel` (`readyModelDirectory()` answers
//  offline, `initialize()` is never called from a test), and nothing here
//  downloads or writes there. Every caller is gated on `.acceptance` plus its
//  own `Fixtures.available(_:)`, so an ordinary `swift test` reaches none of
//  it.
//
//  The WAV loaders are the THIRD copy of the same readers — `AudioTests` and
//  `TranscriptionTests` hold the other two — and deliberately not a shared
//  helper: `EchoCore` takes something only when three packages need it
//  (CLAUDE.md), and these are test targets, which export nothing to share.
//  This copy is Audio's rather than Transcription's on purpose: `loadWAV`
//  returns the channel directly when the file is already canonical and only
//  otherwise goes through the production downmixer and resampler, so a
//  fixture recorded in the canonical layout reaches the stage with its bytes
//  untouched, and a non-canonical one converts exactly the way capture would.
//

import AVFoundation
import Audio
import EchoCore
import EchoCoreTestSupport
import Foundation
import Synchronization
import Transcription

/// Collecting gate-diagnostics sink for the measurement suite. The pipeline
/// actor calls `record` from its own executor while the test reads from
/// elsewhere, so access is mutex-guarded: the sink contract requires thread
/// safety, not isolation.
final class CollectingGateSink: GateDiagnosticsSink {

    private let storage = Mutex<[GateDecisionRecord]>([])

    func record(_ record: GateDecisionRecord) {
        storage.withLock { $0.append(record) }
    }

    var records: [GateDecisionRecord] { storage.withLock { $0 } }
}

enum RecordingAcceptanceSupport {

    enum LoadError: Error {
        case unreadable(URL)
        case unsupportedFormat(URL)
    }

    /// 16 kHz mono Float32 — the canonical ingest format retained audio uses,
    /// so a staged file decodes exactly like a real meeting's.
    static let canonicalFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: AudioConstants.sampleRate,
        channels: 1,
        interleaved: false
    )

    /// The real on-disk model, rooted at the shared data folder's `Models`
    /// subtree. Purely a disk check: a missing model set makes the pass throw
    /// `modelUnavailable` rather than fetch 480 MB.
    static let model = ParakeetModel(modelsRoot: DataRoot.standard.models)

    // MARK: - Reading

    /// Reads a WAV into 16 kHz mono Float samples, downmixing/resampling if
    /// the file is not already in the canonical capture format.
    static func loadWAV(at url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard
            let buffer = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat,
                frameCapacity: AVAudioFrameCount(max(file.length, 1))
            )
        else { throw LoadError.unreadable(url) }
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
    /// `mic-native.wav` loader. The downmix comparison replays these channels
    /// through both downmixes, so nothing here may mix or resample.
    static func loadNativeWAV(at url: URL) throws -> (channels: [[Float]], sampleRate: Double) {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard
            let buffer = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat,
                frameCapacity: AVAudioFrameCount(max(file.length, 1))
            )
        else { throw LoadError.unreadable(url) }
        try file.read(into: buffer)

        guard let source = buffer.floatChannelData else { throw LoadError.unsupportedFormat(url) }
        let frames = Int(buffer.frameLength)
        let channels = (0..<Int(buffer.format.channelCount)).map {
            Array(UnsafeBufferPointer(start: source[$0], count: frames))
        }
        return (channels: channels, sampleRate: file.processingFormat.sampleRate)
    }

    /// The optional pre-downmix multi-channel mic take for a scenario.
    static func micNativeURL(_ scenario: String) -> URL {
        Fixtures.url(scenario: scenario, file: "mic-native.wav")
    }

    /// Whether the optional native multi-channel take was recorded for the
    /// scenario. Deliberately not part of `Fixtures.available(_:)`: the
    /// recorder writes `mic-native.wav` only for multi-channel devices, so a
    /// mono scenario is a complete pair without it.
    static func micNativeAvailable(_ scenario: String) -> Bool {
        FileManager.default.fileExists(atPath: micNativeURL(scenario).path)
    }

    /// Both channels of a scenario, canonical 16 kHz mono. A scenario is only
    /// ever a complete pair, so callers gate on `Fixtures.available(_:)`
    /// first and this loader does not check again.
    static func loadPair(_ scenario: String) throws -> (mic: [Float], system: [Float]) {
        (
            mic: try loadWAV(at: Fixtures.url(scenario: scenario, file: "mic.wav")),
            system: try loadWAV(at: Fixtures.url(scenario: scenario, file: "system.wav"))
        )
    }

    // MARK: - Writing

    /// 16 kHz mono Float32 — the canonical ingest format retained audio uses,
    /// so the staged file decodes exactly like a real meeting's.
    static func writeCanonicalWAV(_ samples: [Float], to url: URL) throws {
        guard let format = canonicalFormat else { throw LoadError.unsupportedFormat(url) }
        let file = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        guard
            let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(samples.count)
            ), let channelData = buffer.floatChannelData
        else { throw LoadError.unsupportedFormat(url) }
        try samples.withUnsafeBufferPointer { source in
            guard let base = source.baseAddress else { throw LoadError.unsupportedFormat(url) }
            channelData[0].update(from: base, count: samples.count)
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        try file.write(from: buffer)
    }

    // MARK: - The pass

    /// Transcribes in-memory 16 kHz mono channels through the production pass.
    /// The pass reads `AVAudioFile` URLs (retained audio is its input), so each
    /// channel is staged as a canonical WAV inside a temporary directory that
    /// is removed afterwards.
    static func transcribe(_ audio: [AudioChannel: [Float]]) async throws -> [TranscriptSegment] {
        let staging = try TemporaryDirectory(prefix: "echo-recording-acceptance")
        defer { staging.remove() }

        var files: [AudioChannel: URL] = [:]
        for (channel, samples) in audio where !samples.isEmpty {
            let url = staging.path("\(channel.rawValue).wav")
            try writeCanonicalWAV(samples, to: url)
            files[channel] = url
        }
        return try await TranscriptionPass.run(retainedFiles: files, model: model)
    }
}

/// The signal measures the fixture suites assert on. Mean-square energy and
/// rms are kept apart on purpose: the double-talk criterion compares energies,
/// the speech gates compare rms and peak, and squaring twice by accident would
/// move a threshold silently.
enum SignalMetrics {

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

    /// Mean-square energy — what the double-talk preservation criterion
    /// compares.
    static func energy(_ samples: ArraySlice<Float>) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for sample in samples { sum += sample * sample }
        return sum / Float(samples.count)
    }
}

/// Replays a fixture pair through an `AECStage` in interleaved 10 ms chunks,
/// mirroring the real capture cadence. Far end is fed first in each step: in
/// production the reference copy is taken from the system stream before its
/// bleed reaches the mic.
enum AECFixtureRunner {

    /// 10 ms at 16 kHz — the engine's own frame, and the cadence the capture
    /// callbacks deliver.
    static let chunkSize = 160

    static func process(mic: [Float], system: [Float], through stage: any AECStage) -> [Float] {
        var output: [Float] = []
        output.reserveCapacity(mic.count)
        var offset = 0
        let total = max(mic.count, system.count)
        while offset < total {
            if offset < system.count {
                stage.feedFarEnd(Array(system[offset..<min(offset + chunkSize, system.count)]))
            }
            if offset < mic.count {
                output += stage.processMicSamples(Array(mic[offset..<min(offset + chunkSize, mic.count)]))
            }
            offset += chunkSize
        }
        return output
    }
}
