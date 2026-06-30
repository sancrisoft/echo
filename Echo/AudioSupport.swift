//
//  AudioSupport.swift
//  Echo
//
//  Shared audio primitives used by both capture channels: the canonical format
//  WhisperKit expects, an RMS level meter for the waveforms, and a resampler
//  that converts any input buffer to 16 kHz mono Float.
//

import AVFoundation

enum AudioConstants {
    /// WhisperKit (and SpeakerKit) consume 16 kHz mono Float32 samples.
    nonisolated static let sampleRate: Double = 16_000
    nonisolated static let channels: AVAudioChannelCount = 1

    nonisolated static var whisperFormat: AVAudioFormat {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: channels,
            interleaved: false
        )!
    }
}

/// A continuous audio source that emits 16 kHz mono Float frames plus a
/// normalized loudness level (0...1) for the waveform UI.
///
/// Callbacks may be invoked on a real-time audio thread — consumers must hop to
/// their own actor/queue before touching shared state.
protocol AudioCaptureSource: AnyObject {
    /// 16 kHz mono Float frames, ready for the transcription pipeline.
    var onSamples: (@Sendable ([Float]) -> Void)? { get set }
    /// Normalized loudness (0...1) for the live waveform.
    var onLevel: (@Sendable (CGFloat) -> Void)? { get set }

    func start() async throws
    func stop()
}

enum AudioLevelMeter {
    /// Map a frame of Float samples to a 0...1 level suitable for a meter,
    /// using an RMS → dBFS mapping with a -60 dB noise floor.
    static func level(from samples: [Float]) -> CGFloat {
        guard !samples.isEmpty else { return 0 }
        var sumSquares: Float = 0
        for s in samples { sumSquares += s * s }
        let rms = (sumSquares / Float(samples.count)).squareRoot()
        guard rms > 0 else { return 0 }

        let db = 20 * log10(rms)            // dBFS, ~-160...0
        let floor: Float = -60
        let normalized = max(0, (db - floor) / -floor)   // 0 at floor, 1 at 0 dB
        return CGFloat(min(1, normalized))
    }
}

enum AudioDownmixer {
    /// Sums every channel of a non-interleaved Float buffer into a single mono
    /// channel (averaged). Returns the buffer unchanged if it's already mono.
    ///
    /// We do this manually instead of letting AVAudioConverter reduce channels,
    /// because multi-mic USB receivers (e.g. a DJI Mic Mini, with TX1 on channel
    /// 0 and TX2 on channel 1) often report no standard channel layout — and in
    /// that case AVAudioConverter keeps only channel 0, silently dropping the
    /// other microphone(s). Averaging guarantees every transmitter is captured.
    static func toMono(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let channelCount = Int(buffer.format.channelCount)
        guard channelCount > 1 else { return buffer }

        // Requires a non-interleaved Float layout (the standard AVAudioEngine tap
        // format). If it isn't, bail and let the caller fall back.
        guard
            buffer.format.commonFormat == .pcmFormatFloat32,
            let source = buffer.floatChannelData,
            let monoFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: buffer.format.sampleRate,
                channels: 1,
                interleaved: false
            ),
            let output = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: buffer.frameLength)
        else { return nil }

        output.frameLength = buffer.frameLength
        let frameCount = Int(buffer.frameLength)
        let destination = output.floatChannelData![0]
        let scale = 1 / Float(channelCount)

        for frame in 0..<frameCount {
            var sum: Float = 0
            for channel in 0..<channelCount {
                sum += source[channel][frame]
            }
            destination[frame] = sum * scale
        }
        return output
    }
}

/// Converts arbitrary PCM buffers to 16 kHz mono Float using AVAudioConverter.
final class BufferResampler {
    private let converter: AVAudioConverter
    private let targetFormat: AVAudioFormat

    init?(from inputFormat: AVAudioFormat, to targetFormat: AVAudioFormat = AudioConstants.whisperFormat) {
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else { return nil }
        self.converter = converter
        self.targetFormat = targetFormat
    }

    /// Returns the resampled 16 kHz mono Float samples, or nil on failure.
    func resample(_ buffer: AVAudioPCMBuffer) -> [Float]? {
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 1
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return nil }

        var consumed = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inStatus in
            if consumed {
                inStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inStatus.pointee = .haveData
            return buffer
        }

        guard status != .error, let channel = output.floatChannelData else { return nil }
        return Array(UnsafeBufferPointer(start: channel[0], count: Int(output.frameLength)))
    }
}
