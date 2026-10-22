//
//  TranscriptionTestSupport.swift
//  TranscriptionTests
//
//  Harness plumbing for the two gated suites: reading a fixture WAV into the
//  canonical 16 kHz mono Float buffer, staging in-memory channels back out as
//  canonical WAVs, and running the production pass over them against the real
//  on-disk model.
//
//  Nothing here downloads, and nothing writes outside a `TemporaryDirectory`.
//  The only thing it reads from the app's data folder is the models directory,
//  and that read is a pure existence check inside `ParakeetModel`.
//

import AVFoundation
import EchoCore
import EchoCoreTestSupport
import Foundation
import Transcription

enum TranscriptionTestSupport {

    enum LoadError: Error {
        case unreadable(URL)
        case unsupportedFormat(URL)
    }

    /// 16 kHz mono Float32 — the ingest format retained audio uses, so a
    /// staged file decodes exactly like a real meeting's.
    static let canonicalFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: TranscriptionPass.sampleRate,
        channels: 1,
        interleaved: false
    )

    /// The real on-disk model, rooted at the shared data folder's `Models`
    /// subtree. Purely a disk check: `readyModelDirectory()` answers offline,
    /// `initialize()` is never called from a test, and a missing model set
    /// makes the pass throw `modelUnavailable` rather than fetch 480 MB.
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
        if format.sampleRate == TranscriptionPass.sampleRate, format.channelCount == 1 {
            guard let channel = buffer.floatChannelData else { throw LoadError.unsupportedFormat(url) }
            return Array(UnsafeBufferPointer(start: channel[0], count: Int(buffer.frameLength)))
        }
        return try converted(buffer, from: url)
    }

    /// The non-canonical path: one `AVAudioConverter` pass to 16 kHz mono.
    /// The PoC borrowed the capture package's downmixer and resampler here;
    /// Transcription must never depend on that package, and a fixture that is
    /// already canonical (the recorded layout) never reaches this branch.
    private static func converted(_ buffer: AVAudioPCMBuffer, from url: URL) throws -> [Float] {
        guard
            let canonicalFormat,
            let converter = AVAudioConverter(from: buffer.format, to: canonicalFormat)
        else { throw LoadError.unsupportedFormat(url) }

        let ratio = canonicalFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 4_096
        guard let output = AVAudioPCMBuffer(pcmFormat: canonicalFormat, frameCapacity: capacity) else {
            throw LoadError.unreadable(url)
        }

        // The input block is `@Sendable`, but `convert(to:error:withInputFrom:)`
        // calls it synchronously on this thread and nothing else touches these
        // two: the whole conversion is over before the call returns.
        nonisolated(unsafe) var supplied = false
        nonisolated(unsafe) let source = buffer
        var failure: NSError?
        let status = converter.convert(to: output, error: &failure) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .endOfStream
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return source
        }
        guard status != .error, failure == nil, let channel = output.floatChannelData else {
            throw LoadError.unsupportedFormat(url)
        }
        return Array(UnsafeBufferPointer(start: channel[0], count: Int(output.frameLength)))
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
    static func transcribe(
        _ audio: [AudioChannel: [Float]],
        onEvent: (@Sendable (PassEvent) -> Void)? = nil
    ) async throws -> [TranscriptSegment] {
        let staging = try TemporaryDirectory(prefix: "echo-transcription-acceptance")
        defer { staging.remove() }

        var files: [AudioChannel: URL] = [:]
        for (channel, samples) in audio where !samples.isEmpty {
            let url = staging.path("\(channel.rawValue).wav")
            try writeCanonicalWAV(samples, to: url)
            files[channel] = url
        }
        return try await TranscriptionPass.run(retainedFiles: files, model: model, onEvent: onEvent)
    }
}
