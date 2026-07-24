//
//  AudioDownmixerTests.swift
//  EchoTests
//
//  ADR-004: per-sample max-magnitude mono downmix. Constructed multi-channel
//  buffers with known values are legitimate here because these tests exercise
//  arithmetic on a pure function, not audio realism (SP-002 Testing Decisions,
//  layer 2 — same reasoning that lets TranscriptDedupTests run on constructed
//  segments). The realism check is the native multi-channel DJI fixture in
//  layer 1.
//

import AVFoundation
import Testing
@testable import Echo

struct AudioDownmixerTests {

    /// Builds the non-interleaved Float32 buffer shape `toMono` supports (the
    /// standard AVAudioEngine tap layout). Uses a discrete-in-order channel
    /// layout because that is what a multi-transmitter receiver presents (N
    /// independent mics, no spatial semantics) — and because the 1-2 channel
    /// convenience initializer refuses >2 channels without a layout.
    /// Force-unwraps are fine: the inputs are compile-time-known valid.
    private func makeBuffer(channels: [[Float]], sampleRate: Double = 48_000) -> AVAudioPCMBuffer {
        let layout = AVAudioChannelLayout(
            layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | AVAudioChannelCount(channels.count)
        )!
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            interleaved: false,
            channelLayout: layout
        )
        let frameCount = channels[0].count
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount))!
        buffer.frameLength = AVAudioFrameCount(frameCount)
        for (channel, samples) in channels.enumerated() {
            for (frame, sample) in samples.enumerated() {
                buffer.floatChannelData![channel][frame] = sample
            }
        }
        return buffer
    }

    private func samples(_ buffer: AVAudioPCMBuffer) -> [Float] {
        Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
    }

    /// ADR-004's motivating case (SP-002 US-2): a DJI-style receiver with one
    /// clipped-on transmitter must not attenuate it by 1/N — the active
    /// channel passes through bit-exact, whichever channel it lives on.
    @Test(arguments: [0, 1])
    func singleActiveChannelPassesThroughAtFullMagnitude(activeChannel: Int) throws {
        let active: [Float] = [0.5, -0.25, 0.9, -0.9, 0.125, 0, -0.0625, 0.75]
        let silent = [Float](repeating: 0, count: active.count)
        let buffer = makeBuffer(channels: activeChannel == 0 ? [active, silent] : [silent, active])

        let mono = try #require(AudioDownmixer.toMono(buffer))

        #expect(mono.format.channelCount == 1)
        #expect(mono.format.sampleRate == buffer.format.sampleRate)
        #expect(mono.frameLength == buffer.frameLength)
        #expect(samples(mono) == active)
    }

    /// The common USB-mic class that presents one capsule as identical L/R:
    /// downmix must be bit-identical to a single channel — no boost, no new
    /// clipping class (ADR-004's argument against equal-weight summing).
    @Test func duplicatedStereoIsBitIdenticalToOneChannel() throws {
        let capsule: [Float] = [0.9, -0.9, 0.7, -0.3, 0.99, -0.99, 0.01, 0]
        let buffer = makeBuffer(channels: [capsule, capsule])

        let mono = try #require(AudioDownmixer.toMono(buffer))

        #expect(samples(mono) == capsule)
    }

    /// Selection is per frame and sign-preserving: whichever channel dominates
    /// a given frame wins it with its original sign — not a per-buffer channel
    /// pick (ADR-004 rejected that for boundary artifacts) and not an
    /// unsigned envelope.
    @Test func dominantSampleWinsEachFrameWithSignPreserved() throws {
        let ch0: [Float] = [-0.8, 0.2, -0.1, 0.4, 0]
        let ch1: [Float] = [0.3, -0.6, 0.05, -0.9, 0.5]
        let buffer = makeBuffer(channels: [ch0, ch1])

        let mono = try #require(AudioDownmixer.toMono(buffer))

        #expect(samples(mono) == [-0.8, -0.6, -0.1, -0.9, 0.5])
    }

    /// The guarantee the manual downmix exists for, in ADR-004 form: with >2
    /// channels each dominant in a different region (three transmitters taking
    /// turns, low bleed elsewhere), every channel's speech survives — no
    /// channel is structurally dropped the way AVAudioConverter drops
    /// non-first channels on layout-less devices.
    @Test func everyChannelOfThreeIsCapturedWhereItDominates() throws {
        let ch0: [Float] = [0.8, -0.7, 0.9, 0.1, -0.1, 0.1, 0.05, -0.05, 0.05]
        let ch1: [Float] = [0.1, 0.1, -0.1, -0.75, 0.8, -0.85, 0.1, -0.1, 0.1]
        let ch2: [Float] = [-0.05, 0.05, 0.05, 0.1, -0.1, 0.1, 0.9, -0.8, 0.7]
        let buffer = makeBuffer(channels: [ch0, ch1, ch2])

        let mono = try #require(AudioDownmixer.toMono(buffer))

        #expect(samples(mono) == [0.8, -0.7, 0.9, -0.75, 0.8, -0.85, 0.9, -0.8, 0.7])
    }

    /// Mono input is untouched pass-through (ADR-004) — the exact same
    /// instance, no copy. The built-in mic and every SP-001 fixture are mono,
    /// so this is what keeps those paths structurally unaffected.
    @Test func monoBufferIsReturnedUnchanged() throws {
        let voice: [Float] = [0.1, -0.4, 0.9, 0, -0.05]
        let buffer = makeBuffer(channels: [voice])

        let mono = try #require(AudioDownmixer.toMono(buffer))

        #expect(mono === buffer)
        #expect(samples(mono) == voice)
    }

    /// ADR-004's "no device gets quieter than today": for every frame the
    /// selected sample's magnitude is at least the old averaging output's,
    /// checked over a mixed buffer of deterministic pseudo-random values
    /// (seeded LCG — reproducible, and covers sign/magnitude combinations no
    /// hand-picked table would).
    @Test func outputIsNeverQuieterThanTheChannelAverage() throws {
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next() -> Float {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Float(state >> 40) / Float(1 << 23) - 1   // -1..<1
        }
        let frameCount = 240
        let channels: [[Float]] = (0..<3).map { _ in (0..<frameCount).map { _ in next() } }
        let buffer = makeBuffer(channels: channels)

        let mono = try #require(AudioDownmixer.toMono(buffer))

        let output = samples(mono)
        let quieterFrames = (0..<frameCount).filter { frame in
            // The exact arithmetic the pre-ADR-004 code produced.
            let average = (channels[0][frame] + channels[1][frame] + channels[2][frame]) * (1 / Float(3))
            return abs(output[frame]) < abs(average)
        }
        #expect(quieterFrames.isEmpty)
    }

    /// Unsupported layouts still bail to nil so callers keep their existing
    /// `?? buffer` AVAudioConverter fallback — ADR-004 changes the mix rule,
    /// not the function's contract.
    @Test func nonFloat32InputReturnsNil() throws {
        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatInt16, sampleRate: 48_000, channels: 2, interleaved: false
        ))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8))
        buffer.frameLength = 8

        #expect(AudioDownmixer.toMono(buffer) == nil)
    }

    /// Interleaved Float32 is also unsupported: `floatChannelData` pointers on
    /// an interleaved buffer are stride-spaced, so the per-channel indexing
    /// the mix loop uses would read the wrong frames — bail to the callers'
    /// AVAudioConverter fallback instead of mixing garbage.
    @Test func interleavedFloat32InputReturnsNil() throws {
        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: true
        ))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8))
        buffer.frameLength = 8

        #expect(AudioDownmixer.toMono(buffer) == nil)
    }
}
