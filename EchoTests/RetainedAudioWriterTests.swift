//
//  RetainedAudioWriterTests.swift
//  EchoTests
//
//  SP-005 S1: the retention writer (ADR-013). Synthetic PCM in-memory — never
//  a committed audio fixture — against a real-FS temp directory, asserting the
//  externally observable contract: samples + declared gaps in, a compressed
//  file whose positions map to recording-relative time out. The mapping
//  invariant is the whole point: every retained sample's file position must
//  equal the live clock's timestamp for it, declared gaps included.
//

import AVFoundation
import Foundation
import Testing
@testable import Echo

@Suite("RetainedAudioWriter")
struct RetainedAudioWriterTests {

    // MARK: - Helpers

    /// Runs `body` against a writer staged in a fresh temp directory, then
    /// removes it. The directory does not exist up front — the writer must
    /// create it on first write.
    private func withTempWriter<T>(_ body: (RetainedAudioWriter, URL) async throws -> T) async rethrows -> T {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "RetainedAudioWriterTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        return try await body(RetainedAudioWriter(directory: directory), directory)
    }

    /// `count` samples of a constant-amplitude tone (a 440 Hz sine), loud
    /// enough to be unmistakable after a lossy encode round-trip.
    private func tone(seconds: Double, amplitude: Float = 0.5) -> [Float] {
        let count = Int(seconds * AudioConstants.sampleRate)
        return (0..<count).map { amplitude * sin(2 * .pi * 440 * Float($0) / Float(AudioConstants.sampleRate)) }
    }

    /// Decodes the whole retained file back to 16 kHz Float samples.
    private func readBack(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: file.processingFormat.sampleRate,
            channels: 1,
            interleaved: false
        )!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
    }

    /// Lossy-codec tolerance: well inside SP-001's 100 ms cross-channel skew
    /// budget, which is the bound ADR-013's mapping invariant is judged by.
    private let tolerance = 0.1

    // MARK: - Duration (silence fill for declared gaps)

    @Test("retained duration is ingested time plus declared gap time")
    func durationCoversSamplesPlusGaps() async throws {
        try await withTempWriter { writer, _ in
            await writer.append(tone(seconds: 2.0), to: .microphone)
            await writer.noteGap(seconds: 1.5, on: .microphone)
            await writer.append(tone(seconds: 0.5), to: .microphone)

            let urls = await writer.finish()
            let url = try #require(urls[.microphone])
            #expect(url.lastPathComponent == "retained-mic.m4a")

            let file = try AVAudioFile(forReading: url)
            let duration = Double(file.length) / file.processingFormat.sampleRate
            #expect(abs(duration - 4.0) < tolerance)
        }
    }

    // MARK: - Timeline mapping (the ADR-013 invariant)

    @Test("a sample written after a gap sits at recording-relative pre-gap + gap")
    func postGapSampleMapsToLiveClockTime() async throws {
        try await withTempWriter { writer, _ in
            // 1.0 s of silence ingested, a 2.0 s declared gap, then a tone:
            // the live clock says the tone starts at t = 3.0 s.
            await writer.append([Float](repeating: 0, count: Int(AudioConstants.sampleRate)), to: .microphone)
            await writer.noteGap(seconds: 2.0, on: .microphone)
            await writer.append(tone(seconds: 0.5), to: .microphone)

            let urls = await writer.finish()
            let samples = try readBack(try #require(urls[.microphone]))

            let onsetIndex = try #require(samples.firstIndex { abs($0) > 0.1 })
            let onsetTime = Double(onsetIndex) / AudioConstants.sampleRate
            #expect(abs(onsetTime - 3.0) < tolerance)
        }
    }

    @Test("zero, negative, and non-finite gaps write nothing (the pipeline's own validation)")
    func invalidGapsAreNoOps() async throws {
        try await withTempWriter { writer, _ in
            await writer.append(tone(seconds: 1.0), to: .microphone)
            await writer.noteGap(seconds: 0, on: .microphone)
            await writer.noteGap(seconds: -3.0, on: .microphone)
            await writer.noteGap(seconds: .infinity, on: .microphone)
            await writer.noteGap(seconds: .nan, on: .microphone)

            let urls = await writer.finish()
            let file = try AVAudioFile(forReading: try #require(urls[.microphone]))
            let duration = Double(file.length) / file.processingFormat.sampleRate
            #expect(abs(duration - 1.0) < tolerance)
        }
    }

    @Test("channels write to separate files with the canonical names")
    func channelsAreSeparateFiles() async throws {
        try await withTempWriter { writer, _ in
            await writer.append(tone(seconds: 1.0), to: .microphone)
            await writer.append(tone(seconds: 2.0), to: .system)

            let urls = await writer.finish()
            #expect(urls[.microphone]?.lastPathComponent == "retained-mic.m4a")
            #expect(urls[.system]?.lastPathComponent == "retained-system.m4a")

            let system = try AVAudioFile(forReading: try #require(urls[.system]))
            let duration = Double(system.length) / system.processingFormat.sampleRate
            #expect(abs(duration - 2.0) < tolerance)
        }
    }

    // MARK: - Subordinate-to-recording failure mode

    @Test("an unwritable staging location disables retention without throwing into the append path")
    func writerFailureDegradesToDisabled() async throws {
        // A *file* where the staging directory should be: directory creation
        // fails on first write, which must disable retention — never throw.
        let blocked = FileManager.default.temporaryDirectory
            .appending(path: "RetainedAudioWriterTests-blocked-\(UUID().uuidString)")
        try Data("not a directory".utf8).write(to: blocked)
        defer { try? FileManager.default.removeItem(at: blocked) }

        let writer = RetainedAudioWriter(directory: blocked)
        await writer.append(tone(seconds: 1.0), to: .microphone)
        await writer.noteGap(seconds: 1.0, on: .microphone)
        await writer.append(tone(seconds: 1.0), to: .microphone)

        #expect(await writer.isDisabled)
        // A disabled session yields no retained audio at all: a partial file
        // must never become a final pass's input (it would replace a fuller
        // live transcript with a truncated one).
        #expect(await writer.finish().isEmpty)
    }

    @Test("appends after finish are ignored")
    func appendsAfterFinishAreIgnored() async throws {
        try await withTempWriter { writer, _ in
            await writer.append(tone(seconds: 1.0), to: .microphone)
            let urls = await writer.finish()
            let url = try #require(urls[.microphone])
            let lengthAtFinish = try AVAudioFile(forReading: url).length

            // A straggler ingest task landing after teardown must not touch
            // the finalized file.
            await writer.append(tone(seconds: 1.0), to: .microphone)
            #expect(try AVAudioFile(forReading: url).length == lengthAtFinish)
        }
    }

    @Test("discard removes every staged file")
    func discardRemovesStagedFiles() async throws {
        try await withTempWriter { writer, directory in
            await writer.append(tone(seconds: 1.0), to: .microphone)
            await writer.append(tone(seconds: 1.0), to: .system)

            await writer.discard()

            #expect(!FileManager.default.fileExists(atPath: directory.path))
        }
    }
}
