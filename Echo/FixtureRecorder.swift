//
//  FixtureRecorder.swift
//  Echo
//
//  DEBUG-only harness for recording the SP-001 fixture suite on real
//  hardware: both capture channels run simultaneously for a fixed take and
//  the raw 16 kHz mono streams are written as paired WAVs. There is
//  deliberately NO AEC stage anywhere in this path — mic.wav is the raw
//  near-end signal including speaker bleed, system.wav the far-end
//  reference. Fixtures must be real recordings (project rule: no simulated
//  audio data); this utility is the one sanctioned way to produce them.
//

#if DEBUG

import AVFoundation
import Foundation
import Observation

/// The SP-001 fixture scenarios (see EchoTests/Fixtures/README.md for the
/// recording instructions each of these implies).
enum FixtureScenario: String, CaseIterable, Identifiable {
    case bleedOnly = "bleed-only"
    case doubleTalk = "double-talk"
    case doubleTalkBaseline = "double-talk-baseline"
    case monologue = "monologue"
    case routeChange = "route-change"

    var id: String { rawValue }
}

/// Thread-safe sample accumulator: capture callbacks arrive on real-time
/// audio threads. A 30 s take is ~2 MB per channel, so buffering the whole
/// take in memory is fine.
private final class SampleSink: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []

    func append(_ frames: [Float]) {
        lock.lock()
        samples.append(contentsOf: frames)
        lock.unlock()
    }

    func drain() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        return samples
    }
}

@Observable
@MainActor
final class FixtureRecorder {

    enum Phase: Equatable {
        case idle
        case countingDown(Int)
        case recording(secondsRemaining: Int)
        case finished(URL)
        case failed(String)
    }

    /// Take length in seconds. Fixed: the scripted double-talk timing in the
    /// README (and the spans hardcoded in AECSignalLevelTests) assume it.
    static let takeDuration = 30
    static let countdownSeconds = 3

    private(set) var phase: Phase = .idle

    var isBusy: Bool {
        switch phase {
        case .countingDown, .recording: return true
        case .idle, .finished, .failed: return false
        }
    }

    enum RecorderError: LocalizedError {
        case emptyCapture(channel: String)
        case bufferAllocationFailed

        var errorDescription: String? {
            switch self {
            case .emptyCapture(let channel):
                return "No \(channel) audio was captured — nothing was written."
            case .bufferAllocationFailed:
                return "Couldn't allocate the audio buffer for writing."
            }
        }
    }

    /// Records one take and writes `{directory}/{scenario}/mic.wav`,
    /// `system.wav` and `info.json`. Never run this while a normal recording
    /// session is active — both would fight over the capture hardware.
    func record(scenario: FixtureScenario, into directory: URL) async {
        guard !isBusy else { return }

        // Captured up front: the route names what hardware the take was
        // recorded on (headphones baseline vs loudspeakers).
        let route = OutputRouteMonitor().currentRoute()

        let mic = MicrophoneCapture()
        let system = SystemAudioCapture()
        let micSink = SampleSink()
        let systemSink = SampleSink()
        mic.onSamples = { micSink.append($0) }
        system.onSamples = { systemSink.append($0) }

        for second in stride(from: Self.countdownSeconds, to: 0, by: -1) {
            phase = .countingDown(second)
            try? await Task.sleep(for: .seconds(1))
        }

        do {
            try await mic.start()
            try await system.start()
        } catch {
            mic.stop()
            system.stop()
            phase = .failed(error.localizedDescription)
            return
        }

        for second in stride(from: Self.takeDuration, to: 0, by: -1) {
            phase = .recording(secondsRemaining: second)
            try? await Task.sleep(for: .seconds(1))
        }

        mic.stop()
        system.stop()

        do {
            let folder = try write(
                micSamples: micSink.drain(),
                systemSamples: systemSink.drain(),
                scenario: scenario,
                route: route,
                into: directory
            )
            phase = .finished(folder)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    // MARK: - Output

    private struct FixtureInfo: Codable {
        let scenario: String
        let recordedAt: Date
        let durationSeconds: Double
        let sampleRate: Double
        let outputRouteAtRecordTime: String
    }

    private func write(
        micSamples: [Float],
        systemSamples: [Float],
        scenario: FixtureScenario,
        route: OutputRouteClass,
        into directory: URL
    ) throws -> URL {
        guard !micSamples.isEmpty else { throw RecorderError.emptyCapture(channel: "microphone") }
        guard !systemSamples.isEmpty else { throw RecorderError.emptyCapture(channel: "system") }

        let folder = directory.appendingPathComponent(scenario.rawValue, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        try Self.writeWAV(micSamples, to: folder.appendingPathComponent("mic.wav"))
        try Self.writeWAV(systemSamples, to: folder.appendingPathComponent("system.wav"))

        let info = FixtureInfo(
            scenario: scenario.rawValue,
            recordedAt: Date(),
            durationSeconds: Double(micSamples.count) / AudioConstants.sampleRate,
            sampleRate: AudioConstants.sampleRate,
            outputRouteAtRecordTime: String(describing: route)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(info).write(to: folder.appendingPathComponent("info.json"))

        return folder
    }

    /// Writes 16 kHz mono Float32 samples as a WAV. Internal (not private)
    /// so the test target can round-trip the real writer against the real
    /// fixture loader.
    nonisolated static func writeWAV(_ samples: [Float], to url: URL) throws {
        try? FileManager.default.removeItem(at: url)

        let format = AudioConstants.whisperFormat
        let file = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(samples.count)
        ) else { throw RecorderError.bufferAllocationFailed }

        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            buffer.floatChannelData![0].update(from: source.baseAddress!, count: samples.count)
        }
        try file.write(from: buffer)
    }
}

#endif
