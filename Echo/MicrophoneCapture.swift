//
//  MicrophoneCapture.swift
//  Echo
//
//  Microphone channel = the current user. Uses AVAudioEngine to tap the
//  default input device, resamples to 16 kHz mono Float, and emits frames and
//  loudness levels.
//
//  Restartable across device changes (SP-002): the engine and tap are built
//  fresh on every `start()`, so a restart picks up the new default device and
//  its native format. `RecordingController` drives restarts from the
//  `InputDeviceMonitor` events.
//

import AVFoundation
import os

final class MicrophoneCapture: AudioCaptureSource {

    static let log = Logger(subsystem: "com.sancrisoft.Echo", category: "MicrophoneCapture")

    var onSamples: (@Sendable ([Float]) -> Void)?
    var onLevel: (@Sendable (CGFloat) -> Void)?

    /// Built per `start()`: a device change invalidates the old engine's
    /// input format, so restart = tear down + fresh engine on the new device.
    private var engine: AVAudioEngine?
    private let tapBufferSize: AVAudioFrameCount = 4096

    enum CaptureError: LocalizedError {
        case permissionDenied
        case noInputDevice
        case resamplerUnavailable

        var errorDescription: String? {
            switch self {
            case .permissionDenied: return "Microphone permission denied."
            case .noInputDevice: return "No microphone is available."
            case .resamplerUnavailable: return "Couldn't set up microphone audio."
            }
        }
    }

    /// Prompts for (or verifies) microphone permission.
    static func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            return false
        }
    }

    func start() async throws {
        guard await Self.requestPermission() else { throw CaptureError.permissionDenied }

        // Restart-safe: drop any previous engine before building the new one.
        stop()

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inputFormat = input.inputFormat(forBus: 0)

        // With no input device the node reports a 0 Hz / 0-channel format, and
        // installing a tap with it raises an ObjC exception. Surface that as a
        // condition the session can degrade on instead (SP-002 Reliability:
        // never a crash, never a stopped recording).
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw CaptureError.noInputDevice
        }

        Self.log.info("""
        Mic input device format: \(inputFormat.channelCount, privacy: .public) ch @ \
        \(inputFormat.sampleRate, privacy: .public) Hz
        """)

        // One resampler per tap, keyed to this tap's device format: a late
        // buffer from a torn-down tap can never reach a converter built for
        // the next device's format.
        var resampler: BufferResampler?

        input.installTap(onBus: 0, bufferSize: tapBufferSize, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }

            // Downmix to mono so every microphone on a multi-channel receiver
            // (e.g. both DJI transmitters) is captured, not just channel 0.
            let monoBuffer = AudioDownmixer.toMono(buffer) ?? buffer

            if resampler == nil {
                resampler = BufferResampler(from: monoBuffer.format)
            }
            guard let frames = resampler?.resample(monoBuffer) else { return }

            self.onLevel?(AudioLevelMeter.level(from: frames))
            self.onSamples?(frames)
        }

        engine.prepare()
        try engine.start()
        self.engine = engine
    }

    func stop() {
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
        self.engine = nil
    }
}
