//
//  AudioSupport.swift
//  Audio
//
//  The primitives both capture channels share: the canonical format the
//  transcription model expects, an RMS level meter, the mono downmix, and a
//  resampler that converts any input buffer to 16 kHz mono Float32.
//

import AVFoundation
import Synchronization

/// The canonical ingest format and the buffer sizes the two taps run at.
public enum AudioConstants {

    /// The canonical ingest format: 16 kHz mono Float32, which is what the
    /// capture path downmixes to, what retention writes, and what the
    /// transcription model consumes.
    ///
    /// Transcription declares this rate too (`TranscriptionPass.sampleRate`).
    /// Two declarations rather than one shared constant is deliberate for
    /// now: EchoCore takes something only when three packages need it
    /// (CLAUDE.md), and today there are two. Recording is the third
    /// consumer; when it lands, this is the moment to lift the rate.
    public static let sampleRate: Double = 16_000
    public static let channels: AVAudioChannelCount = 1

    /// The canonical format as an `AVAudioFormat`. A computed property
    /// because `AVAudioFormat` is a class: handing every caller the same
    /// instance would share a reference across the render thread, the IO
    /// queue and the writer actor for no gain.
    public static var captureFormat: AVAudioFormat? {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: channels,
            interleaved: false
        )
    }
}

/// Maps a frame of samples to a meter position.
public enum AudioLevelMeter {

    /// Map a frame of Float samples to a 0...1 level suitable for a meter,
    /// using an RMS → dBFS mapping with a -60 dB noise floor.
    public static func level(from samples: [Float]) -> Double {
        guard !samples.isEmpty else { return 0 }
        var sumSquares: Float = 0
        for sample in samples { sumSquares += sample * sample }
        let rms = (sumSquares / Float(samples.count)).squareRoot()
        guard rms > 0 else { return 0 }

        let decibels = 20 * log10(rms)  // dBFS, ~-160...0
        let floor: Float = -60
        let normalized = max(0, (decibels - floor) / -floor)  // 0 at floor, 1 at 0 dB
        return Double(min(1, normalized))
    }
}

/// Reduces a multi-channel capture buffer to the one channel the pipeline
/// carries.
public enum AudioDownmixer {

    /// Downmixes a non-interleaved Float buffer to mono by per-sample
    /// max-magnitude selection: each output frame is the channel sample with
    /// the largest magnitude, sign preserved. Returns the buffer unchanged if
    /// it is already mono.
    ///
    /// We do this manually instead of letting AVAudioConverter reduce
    /// channels, because multi-mic USB receivers (e.g. a DJI Mic Mini, with
    /// TX1 on channel 0 and TX2 on channel 1) often report no standard
    /// channel layout — and in that case AVAudioConverter keeps only channel
    /// 0, silently dropping the other microphone(s). Reading every channel
    /// ourselves guarantees no transmitter is structurally dropped.
    ///
    /// Selection replaced the original channel averaging because averaging
    /// attenuates a single active transmitter by 1/N — a 6 dB loss on a
    /// two-channel receiver with one clip-on mic. Max-magnitude passes a lone
    /// transmitter through at full strength, keeps duplicated-stereo devices
    /// bit-identical (no boost, no clip risk, unlike equal-weight summing),
    /// never destructively cancels, and no output sample is quieter than the
    /// old average.
    public static func toMono(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let channelCount = Int(buffer.format.channelCount)
        guard channelCount > 1 else { return buffer }

        // Requires a non-interleaved Float layout (the standard AVAudioEngine
        // tap format). If it isn't, bail and let the caller fall back —
        // interleaved buffers expose stride-spaced channel pointers that the
        // per-frame indexing below would misread.
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
            let output = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: buffer.frameLength),
            let destination = output.floatChannelData?[0]
        else { return nil }

        output.frameLength = buffer.frameLength
        let frameCount = Int(buffer.frameLength)

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

/// Converts arbitrary PCM buffers to 16 kHz mono Float using
/// `AVAudioConverter`.
///
/// Not `Sendable`, and deliberately so: one resampler belongs to one capture
/// path and is only ever touched by the thread that owns that path — the
/// AVAudioEngine render thread for the microphone, the IO queue for the
/// system tap. A resampler that crossed threads would carry the converter's
/// internal state with it.
public final class BufferResampler {

    private let converter: AVAudioConverter
    private let targetFormat: AVAudioFormat

    public init?(from inputFormat: AVAudioFormat, to targetFormat: AVAudioFormat) {
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else { return nil }
        self.converter = converter
        self.targetFormat = targetFormat
    }

    /// A resampler onto the canonical capture format.
    public convenience init?(from inputFormat: AVAudioFormat) {
        guard let canonical = AudioConstants.captureFormat else { return nil }
        self.init(from: inputFormat, to: canonical)
    }

    /// Returns the resampled 16 kHz mono Float samples, or nil on failure.
    public func resample(_ buffer: AVAudioPCMBuffer) -> [Float]? {
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 1
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return nil }

        // `AVAudioConverterInputBlock` is `@Sendable`, so the "have I handed
        // the buffer over yet" flag cannot be a captured `var`. The block runs
        // synchronously on this thread for the duration of `convert`, so the
        // lock is never contended; it exists to satisfy the closure's
        // Sendability, not to arbitrate between threads.
        let consumed = Mutex(false)
        // The block is typed `@Sendable` but `AVAudioConverter` calls it
        // synchronously, on this thread, before `convert` returns — the
        // buffer never actually crosses a thread, and there is no other
        // reference to it while the conversion runs. Shadowed rather than
        // silenced module-wide with `@preconcurrency`, so the exemption names
        // exactly the one value it covers.
        nonisolated(unsafe) let buffer = buffer
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inStatus in
            let alreadyConsumed = consumed.withLock { was -> Bool in
                defer { was = true }
                return was
            }
            if alreadyConsumed {
                inStatus.pointee = .noDataNow
                return nil
            }
            inStatus.pointee = .haveData
            return buffer
        }

        guard status != .error, let channel = output.floatChannelData else { return nil }
        return Array(UnsafeBufferPointer(start: channel[0], count: Int(output.frameLength)))
    }
}
