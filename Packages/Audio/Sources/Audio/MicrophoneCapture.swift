//
//  MicrophoneCapture.swift
//  Audio
//
//  Microphone channel = the current user. Taps the default input device
//  through `AVAudioEngine`, downmixes and resamples to 16 kHz mono Float32,
//  and emits frames and loudness levels.
//
//  Restartable across device changes: the engine and tap are built fresh on
//  every `start()`, so a restart picks up the new default device and its
//  native format. Recording drives restarts from `InputDeviceMonitor`'s
//  events.
//
//  Isolation (ADR-002). v1 compiled this class as implicitly `@MainActor`
//  while its tap closure ran on the AVAudioEngine render thread — the bug
//  class the Swift 6 migration exists to remove. Here the class is `Sendable`
//  with immutable callbacks, so the render thread reads nothing that can
//  change under it; the engine, which only `start()` and `stop()` touch, is
//  the one piece of mutable state and it sits behind a `Mutex`. The
//  resampler is created inside the tap closure and captured by it alone, so
//  it is confined to the render thread by construction and a late buffer from
//  a torn-down tap can never reach a converter built for the next device's
//  format.
//

import AVFoundation
import EchoCore
import Synchronization
import os

public final class MicrophoneCapture: Sendable {

    private static let log = Logger(subsystem: AppIdentity.logSubsystem, category: "MicrophoneCapture")

    /// Advisory: macOS clamps the tap to its own minimum. Measured on this
    /// Mac (2026-08-12, 48 kHz built-in input), the engine delivers
    /// 4800-frame buffers — exactly 100.0 ms — whatever this asks for. That
    /// interval is the floor on how fresh anything derived from mic audio can
    /// be, the level meter included.
    private static let tapBufferSize: AVAudioFrameCount = 4096

    public enum CaptureError: LocalizedError {
        case permissionDenied
        case noInputDevice

        public var errorDescription: String? {
            switch self {
            case .permissionDenied: return "Microphone permission denied."
            case .noInputDevice: return "No microphone is available."
            }
        }
    }

    /// 16 kHz mono Float32 frames, ready for the pipeline. Invoked on the
    /// AVAudioEngine render thread.
    private let onSamples: (@Sendable ([Float]) -> Void)?

    /// Normalized loudness (0...1) for the live meter. Invoked on the render
    /// thread.
    private let onLevel: (@Sendable (Double) -> Void)?

    /// The untouched native-format tap buffer, delivered BEFORE the downmix
    /// and resample below ever see it — the mic exactly as the device handed
    /// it over. Exists for the DEBUG fixture recorder, which preserves
    /// multi-channel takes pre-downmix (`mic-native.wav`) so the downmix
    /// stays offline-testable against real device audio. Invoked on the
    /// render thread; the engine reuses tap buffers, so consumers must copy
    /// out synchronously. Nil (the normal case) costs a single optional check
    /// per buffer.
    private let onRawBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?

    /// Built per `start()`: a device change invalidates the old engine's
    /// input format, so restart = tear down + fresh engine on the new device.
    ///
    /// Behind a `Mutex` because `start()` and `stop()` may be called from any
    /// isolation (Recording's main actor today, a device-monitor callback
    /// tomorrow) and must not interleave; the render thread never reads it.
    private let engine = Mutex(EngineBox())

    /// `@unchecked Sendable` because `AVAudioEngine` is not `Sendable` and
    /// Swift cannot see that the `engine` lock is the only way in. The
    /// threads: whichever context calls `start()` or `stop()` — Recording's
    /// main actor today, an input-device event tomorrow. The render thread
    /// never touches it.
    private struct EngineBox: @unchecked Sendable {
        var engine: AVAudioEngine?
    }

    public init(
        onSamples: (@Sendable ([Float]) -> Void)? = nil,
        onLevel: (@Sendable (Double) -> Void)? = nil,
        onRawBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)? = nil
    ) {
        self.onSamples = onSamples
        self.onLevel = onLevel
        self.onRawBuffer = onRawBuffer
    }

    /// Prompts for (or verifies) microphone permission.
    public static func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            return false
        }
    }

    public func start() async throws {
        guard await Self.requestPermission() else { throw CaptureError.permissionDenied }

        // The engine is built, tapped and started inside the lock, so a
        // restart driven by a device event can never interleave with a stop
        // from the session. Every call in here is synchronous; the awaited
        // permission check above is deliberately outside.
        try engine.withLock { box in
            Self.tearDown(box.engine)
            box.engine = nil

            let engine = AVAudioEngine()
            let input = engine.inputNode
            let inputFormat = input.inputFormat(forBus: 0)

            // With no input device the node reports a 0 Hz / 0-channel
            // format, and installing a tap with it raises an ObjC exception.
            // Surface that as a condition the session can degrade on
            // instead: never a crash, never a stopped recording.
            guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
                throw CaptureError.noInputDevice
            }

            Self.log.info(
                """
                Mic input device format: \(inputFormat.channelCount, privacy: .public) ch @ \
                \(inputFormat.sampleRate, privacy: .public) Hz
                """
            )

            let onSamples = self.onSamples
            let onLevel = self.onLevel
            let onRawBuffer = self.onRawBuffer

            // One resampler per tap, keyed to this tap's device format, and
            // reachable only from inside this closure — which the render
            // thread runs one buffer at a time. A late buffer from a
            // torn-down tap can therefore never reach a converter built for
            // the next device's format.
            nonisolated(unsafe) var resampler: BufferResampler?

            input.installTap(onBus: 0, bufferSize: Self.tapBufferSize, format: inputFormat) { buffer, _ in
                // Native-form hook first: the raw device buffer, before any
                // downmix or resample.
                onRawBuffer?(buffer)

                // Downmix to mono so every microphone on a multi-channel
                // receiver (e.g. both DJI transmitters) is captured, not just
                // channel 0.
                let monoBuffer = AudioDownmixer.toMono(buffer) ?? buffer

                if resampler == nil {
                    resampler = BufferResampler(from: monoBuffer.format)
                }
                guard let frames = resampler?.resample(monoBuffer) else { return }

                onLevel?(AudioLevelMeter.level(from: frames))
                onSamples?(frames)
            }

            engine.prepare()
            try engine.start()
            box.engine = engine
        }
    }

    public func stop() {
        engine.withLock { box in
            Self.tearDown(box.engine)
            box.engine = nil
        }
    }

    private static func tearDown(_ engine: AVAudioEngine?) {
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
    }
}
