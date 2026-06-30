//
//  MicrophoneCapture.swift
//  Echo
//
//  Microphone channel = the current user. Uses AVAudioEngine to tap the
//  default input device, resamples to 16 kHz mono Float, and emits frames and
//  loudness levels.
//

import AVFoundation
import os

final class MicrophoneCapture: AudioCaptureSource {

    static let log = Logger(subsystem: "com.sancrisoft.Echo", category: "MicrophoneCapture")

    var onSamples: (@Sendable ([Float]) -> Void)?
    var onLevel: (@Sendable (CGFloat) -> Void)?

    private let engine = AVAudioEngine()
    private var resampler: BufferResampler?
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
        let inputFormat = input.inputFormat(forBus: 0)

        Self.log.info("""
        Mic input device format: \(inputFormat.channelCount, privacy: .public) ch @ \
        \(inputFormat.sampleRate, privacy: .public) Hz
        """)

        input.installTap(onBus: 0, bufferSize: tapBufferSize, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }

            // Average all channels to mono so every microphone on a multi-channel
            // receiver (e.g. both DJI transmitters) is captured, not just channel 0.
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
    }
}
