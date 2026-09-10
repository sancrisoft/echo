//
//  AudioTestSupport.swift
//  AudioTests
//
//  Harness plumbing for the suites that replay real recordings: reading a
//  fixture WAV into the canonical 16 kHz mono Float buffer, reading one back
//  in its native multi-channel shape (the pre-downmix `mic-native.wav`, which
//  nothing here may mix or resample — the downmix's realism check replays the
//  true device signal), and asking whether a scenario recorded that optional
//  extra at all.
//
//  It also holds what the echo-cancellation suites need on top of that: a
//  scenario's channel pair, the signal measures their assertions are written
//  in, and the replay loop that drives an `AECStage` at the real capture
//  cadence.
//
//  Nothing here records, nothing touches capture hardware, and nothing writes
//  outside a `TemporaryDirectory`. Fixture reads are read-only and gated by
//  the caller on `Fixtures.available(_:)` or `micNativeAvailable(_:)`.
//
//  These loaders are a copy of `TranscriptionTestSupport`'s, not a shared
//  helper: `EchoCore` takes something only when three packages need it
//  (CLAUDE.md) and today there are two. The copy also differs on purpose —
//  this one converts through the production downmix and resampler, which is
//  exactly what Transcription may not depend on.
//

import AVFoundation
import Audio
import EchoCoreTestSupport
import Foundation
import Synchronization

/// Collecting gate-diagnostics sink for the suites that assert on gate
/// decisions. The pipeline actor calls `record` from its own executor while
/// the test reads from elsewhere, so access is mutex-guarded: the sink
/// contract requires thread safety, not isolation.
final class CollectingGateSink: GateDiagnosticsSink {

    private let storage = Mutex<[GateDecisionRecord]>([])

    func record(_ record: GateDecisionRecord) {
        storage.withLock { $0.append(record) }
    }

    var records: [GateDecisionRecord] { storage.withLock { $0 } }
}

enum AudioTestSupport {

    enum LoadError: Error {
        case unreadable(URL)
        case unsupportedFormat(URL)
    }

    /// 16 kHz mono Float32 — the canonical ingest format both channels
    /// downmix and resample to, so a staged file decodes exactly like a real
    /// meeting's.
    static let canonicalFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: AudioConstants.sampleRate,
        channels: 1,
        interleaved: false
    )

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
    /// `mic-native.wav` loader, and the counterpart of
    /// `FixtureRecorder.writeWAV(channels:sampleRate:to:)`. The downmix's
    /// realism check replays these channels through the production downmix, so
    /// nothing here may mix or resample.
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

    /// Whether the optional native multi-channel take was recorded for the
    /// scenario. Deliberately not part of `Fixtures.available(_:)`: the
    /// recorder writes `mic-native.wav` only for multi-channel devices, so a
    /// mono scenario is a complete pair without it, and the downmix's realism
    /// check gates on this instead.
    static func micNativeAvailable(_ scenario: String) -> Bool {
        FileManager.default.fileExists(
            atPath: Fixtures.url(scenario: scenario, file: "mic-native.wav").path
        )
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
}

/// The signal measures the echo-cancellation suites assert on. Mean-square
/// energy and rms are kept apart on purpose: the double-talk criterion
/// compares energies, the speech gates compare rms and peak, and squaring
/// twice by accident would move a threshold silently.
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
