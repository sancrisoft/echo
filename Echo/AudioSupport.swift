//
//  AudioSupport.swift
//  Echo
//
//  Shared audio primitives used by both capture channels: the canonical format
//  the transcription model expects, an RMS level meter for the waveforms, and a resampler
//  that converts any input buffer to 16 kHz mono Float.
//

import AVFoundation

enum AudioConstants {
    /// The canonical ingest format: 16 kHz mono Float32, which is what the
    /// capture path downmixes to, what retention writes, and what the
    /// transcription model consumes.
    nonisolated static let sampleRate: Double = 16_000
    nonisolated static let channels: AVAudioChannelCount = 1

    nonisolated static var captureFormat: AVAudioFormat {
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
    /// Downmixes a non-interleaved Float buffer to mono by per-sample
    /// max-magnitude selection: each output frame is the channel sample with
    /// the largest magnitude, sign preserved (ADR-004). Returns the buffer
    /// unchanged if it's already mono.
    ///
    /// We do this manually instead of letting AVAudioConverter reduce channels,
    /// because multi-mic USB receivers (e.g. a DJI Mic Mini, with TX1 on channel
    /// 0 and TX2 on channel 1) often report no standard channel layout — and in
    /// that case AVAudioConverter keeps only channel 0, silently dropping the
    /// other microphone(s). Reading every channel ourselves guarantees no
    /// transmitter is structurally dropped.
    ///
    /// Selection replaced the original channel averaging because averaging
    /// attenuates a single active transmitter by 1/N — a 6 dB loss on a
    /// two-channel receiver with one clip-on mic, SP-002's US-2 dropout
    /// penalty. Max-magnitude passes a lone transmitter through at full
    /// strength, keeps duplicated-stereo devices bit-identical (no boost, no
    /// clip risk, unlike equal-weight summing), never destructively cancels,
    /// and no output sample is quieter than the old average (ADR-004).
    static func toMono(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let channelCount = Int(buffer.format.channelCount)
        guard channelCount > 1 else { return buffer }

        // Requires a non-interleaved Float layout (the standard AVAudioEngine tap
        // format). If it isn't, bail and let the caller fall back — interleaved
        // buffers expose stride-spaced channel pointers that the per-frame
        // indexing below would misread.
        guard
            buffer.format.commonFormat == .pcmFormatFloat32,
            !buffer.format.isInterleaved,
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

        for frame in 0..<frameCount {
            // Largest-|value| sample wins the frame; ties keep the earliest
            // channel, which is what makes duplicated stereo bit-identical.
            var selected: Float = 0
            for channel in 0..<channelCount {
                let sample = source[channel][frame]
                if abs(sample) > abs(selected) {
                    selected = sample
                }
            }
            destination[frame] = selected
        }
        return output
    }
}

/// Converts arbitrary PCM buffers to 16 kHz mono Float using AVAudioConverter.
final class BufferResampler {
    private let converter: AVAudioConverter
    private let targetFormat: AVAudioFormat

    init?(from inputFormat: AVAudioFormat, to targetFormat: AVAudioFormat = AudioConstants.captureFormat) {
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
