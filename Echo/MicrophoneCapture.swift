//
//  MicrophoneCapture.swift
//  Echo
//
//  Microphone channel = the current user. Uses AVAudioEngine to tap the
//  default input device, resamples to 16 kHz mono Float, and emits frames and
//  loudness levels.
//
//  Apple's Voice Processing I/O is enabled on the input node, which applies
//  acoustic echo cancellation (cancels the system output that leaks into the
//  mic — e.g. meeting audio from the monitor speakers picked up by the DJI mic)
//  plus noise suppression and AGC — the native equivalent of Krisp / Voice
//  Isolation, fully on-device.
//

import AVFoundation
import os

final class MicrophoneCapture: AudioCaptureSource {

    static let log = Logger(subsystem: "com.sancrisoft.Echo", category: "MicrophoneCapture")

    var onSamples: (@Sendable ([Float]) -> Void)?
    var onLevel: (@Sendable (CGFloat) -> Void)?

    private let engine = AVAudioEngine()
    private var resampler: BufferResampler?
    private var didLogFormat = false
    private let tapBufferSize: AVAudioFrameCount = 4096

    enum CaptureError: LocalizedError {
        case permissionDenied
        case resamplerUnavailable

        var errorDescription: String? {
            switch self {
            case .permissionDenied: return "Microphone permission denied."
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

        let input = engine.inputNode

        // Enable acoustic echo cancellation + noise suppression. Must be set
        // while the engine is stopped. Degrade gracefully if unavailable.
        do {
            try input.setVoiceProcessingEnabled(true)
            // Don't duck the meeting audio the user is listening to while they speak.
            input.voiceProcessingOtherAudioDuckingConfiguration = AVAudioVoiceProcessingOtherAudioDuckingConfiguration(
                enableAdvancedDucking: false,
                duckingLevel: .min
            )
            Self.log.info("Voice processing (AEC + noise suppression) enabled")
        } catch {
            Self.log.error("Voice processing unavailable, capturing raw mic: \(error.localizedDescription, privacy: .public)")
        }

        // Voice processing changes the input node's output format, so let the
        // engine pick it (format: nil) and read it from the first buffer.
        input.installTap(onBus: 0, bufferSize: tapBufferSize, format: nil) { [weak self] buffer, _ in
            guard let self else { return }

            if !self.didLogFormat {
                self.didLogFormat = true
                Self.log.info("Mic tap format: \(buffer.format.channelCount, privacy: .public) ch @ \(buffer.format.sampleRate, privacy: .public) Hz")
            }

            // Average all channels to mono so every microphone on a multi-channel
            // receiver (e.g. both DJI transmitters) is captured, not just channel 0.
            // (Voice processing already outputs mono, so this is then a no-op.)
            let monoBuffer = AudioDownmixer.toMono(buffer) ?? buffer

            if self.resampler == nil {
                self.resampler = BufferResampler(from: monoBuffer.format)
            }
            guard let frames = self.resampler?.resample(monoBuffer) else { return }

            self.onLevel?(AudioLevelMeter.level(from: frames))
            self.onSamples?(frames)
        }

        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
        resampler = nil
        didLogFormat = false
    }
}
