//
//  PreservedPlaybackTests.swift
//  EchoTests
//
//  The preserved-recording player's composition (§3.4): both channels insert
//  at the timeline origin, so the composition's duration is max(channels).
//  Fixtures are synthetic sine m4a files generated in-test into a temp
//  directory — never shipped in the bundle (they'd collide with the test
//  host's build), never real meeting audio.
//

import AVFoundation
import Foundation
import Testing
@testable import Echo

@Suite("Preserved playback composition")
struct PreservedPlaybackTests {

    /// Writes `seconds` of a quiet sine as AAC m4a — the same container and
    /// format family the retention writer produces.
    private func writeSine(seconds: Double, to url: URL) throws {
        let sampleRate = 16_000.0
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32_000,
        ]
        let file = try AVAudioFile(
            forWriting: url,
            settings: settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        let frames = Int(seconds * sampleRate)
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false
        ), let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else {
            Issue.record("Couldn't allocate the synthetic buffer")
            return
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        for i in 0..<frames {
            buffer.floatChannelData![0][i] = 0.1 * sinf(2 * .pi * 440 * Float(i) / Float(sampleRate))
        }
        try file.write(from: buffer)
    }

    @Test func compositionDurationIsTheLongerChannel() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "PreservedPlaybackTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let mic = root.appending(path: "audio-mic.m4a")
        let system = root.appending(path: "audio-system.m4a")
        try writeSine(seconds: 1.0, to: mic)
        try writeSine(seconds: 2.0, to: system)

        let composition = await PreservedPlayback.composition(
            for: [.microphone: mic, .system: system]
        )

        #expect(composition.tracks(withMediaType: .audio).count == 2)
        let duration = CMTimeGetSeconds(composition.duration)
        // AAC adds encoder priming/padding of a frame or two; the assertion
        // is "the longer channel wins", with codec-sized tolerance.
        #expect(abs(duration - 2.0) < 0.15)

        // Both tracks start at the shared origin — the alignment the
        // transcript's timestamps assume.
        for track in composition.tracks(withMediaType: .audio) {
            #expect(track.timeRange.start == .zero)
        }
    }

    @Test func aMissingChannelStillPlaysTheOther() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "PreservedPlaybackTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let mic = root.appending(path: "audio-mic.m4a")
        try writeSine(seconds: 1.5, to: mic)
        // The system entry points at a file that doesn't exist — skipped,
        // never fatal.
        let ghost = root.appending(path: "audio-system.m4a")

        let composition = await PreservedPlayback.composition(
            for: [.microphone: mic, .system: ghost]
        )

        #expect(composition.tracks(withMediaType: .audio).count == 1)
        #expect(abs(CMTimeGetSeconds(composition.duration) - 1.5) < 0.15)
    }
}
