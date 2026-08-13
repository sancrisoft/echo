//
//  WaveformAmplitudeTests.swift
//  EchoTests
//
//  The popover's two waves must answer to the same thing: how loud each
//  channel has been over the last stretch of *audio*. They used to average a
//  fixed count of capture callbacks instead, and the two taps don't run at the
//  same rate — the mic is a 4096-frame AVAudioEngine tap (~100 ms per
//  callback), system audio is the Core Audio IO proc (~12 ms). Eight callbacks
//  was therefore ~800 ms of mic against ~90 ms of system: the indigo wave
//  rendered a long-run average that barely moved while the gray one tracked
//  the room. These pin the fix — amplitude is a function of seconds, not of
//  callbacks.
//

import Foundation
import Testing
@testable import Echo

@Suite("Waveform amplitude (tap cadence)")
@MainActor
struct WaveformAmplitudeTests {

    /// Measured cadences of the two capture paths.
    private let systemTick: TimeInterval = 0.012
    private let micTick: TimeInterval = 0.1

    private let start = Date(timeIntervalSince1970: 1_770_000_000)

    /// Feeds one channel a level envelope sampled at its own tap cadence.
    private func feed(
        _ state: RecordingState,
        channel: AudioChannel,
        tick: TimeInterval,
        until end: TimeInterval,
        envelope: (TimeInterval) -> CGFloat
    ) {
        var t: TimeInterval = 0
        while t <= end {
            let at = start.addingTimeInterval(t)
            switch channel {
            case .microphone: state.pushInput(envelope(t), at: at)
            case .system: state.pushOutput(envelope(t), at: at)
            }
            t += tick
        }
    }

    /// Quiet room, then someone starts talking at t = 2 s.
    private func burst(_ t: TimeInterval) -> CGFloat { t < 2 ? 0.03 : 0.5 }

    @Test func bothTapCadencesReadTheSameEnvelope() {
        let state = RecordingState()
        feed(state, channel: .system, tick: systemTick, until: 2.2, envelope: burst)
        feed(state, channel: .microphone, tick: micTick, until: 2.2, envelope: burst)

        let now = start.addingTimeInterval(2.2)
        let mic = RecordingState.amplitude(of: state.inputLevels, now: now)
        let system = RecordingState.amplitude(of: state.outputLevels, now: now)

        // The speech is 200 ms old on both channels, so both waves stand up.
        #expect(mic > 0.5)
        #expect(system > 0.5)
        // And they stand up equally: the slow tap is not reporting a
        // long-run average next to the fast tap's live reading.
        #expect(abs(mic - system) < 0.05)
    }

    @Test func silenceReadsAsSilenceOnTheSlowTapToo() {
        let state = RecordingState()
        // Loud for two seconds, then the speaker stops at t = 2 s.
        let stopsTalking: (TimeInterval) -> CGFloat = { $0 < 2 ? 0.5 : 0.02 }
        feed(state, channel: .system, tick: systemTick, until: 2.4, envelope: stopsTalking)
        feed(state, channel: .microphone, tick: micTick, until: 2.4, envelope: stopsTalking)

        let now = start.addingTimeInterval(2.4)
        let mic = RecordingState.amplitude(of: state.inputLevels, now: now)
        let system = RecordingState.amplitude(of: state.outputLevels, now: now)

        // 400 ms after the last word both waves have collapsed — the mic no
        // longer drags two seconds of speech behind it.
        #expect(mic < 0.1)
        #expect(system < 0.1)
        #expect(abs(mic - system) < 0.05)
    }

    /// A 4096-frame tap on a 16 kHz device delivers every ~256 ms — longer
    /// than the averaging window itself. Between callbacks the wave must hold
    /// that device's newest reading rather than dropping to the floor and
    /// strobing back up four times a second.
    @Test func aTapSlowerThanTheWindowStillTracksItsOwnReadings() {
        let state = RecordingState()
        feed(state, channel: .microphone, tick: 0.256, until: 2.0) { _ in 0.5 }

        // 200 ms after the last callback: past the 150 ms window, nowhere
        // near stale.
        let between = RecordingState.amplitude(
            of: state.inputLevels,
            now: start.addingTimeInterval(1.792 + 0.2)
        )
        #expect(between > 0.5)
    }

    @Test func aChannelThatStopsDeliveringFallsBackToRest() {
        let state = RecordingState()
        feed(state, channel: .microphone, tick: micTick, until: 1.0) { _ in 0.6 }

        // The device disappears: no callbacks at all after t = 1 s. A second
        // later the wave must be at rest, not frozen at its last reading.
        let frozen = RecordingState.amplitude(of: state.inputLevels, now: start.addingTimeInterval(2.0))
        #expect(frozen == 0)
    }

    @Test func theWindowStaysBoundedUnderTheFastTap() {
        let state = RecordingState()
        feed(state, channel: .system, tick: systemTick, until: 30) { _ in 0.4 }

        // 30 s at ~83 callbacks/s, held to one window's worth.
        #expect(state.outputLevels.count <= 8)
        #expect(!state.outputLevels.isEmpty)
    }

    /// Averaging is latency. The mic tap already costs 100 ms to accumulate a
    /// buffer, so blending the newest reading with the previous one would put
    /// audio up to 200 ms old on screen — which is what a delay between
    /// speaking and seeing the wave move is made of. The window is narrower
    /// than the tap's cadence precisely so this can't happen.
    @Test func theMicWaveShowsItsNewestReadingNotABlend() {
        let state = RecordingState()
        state.pushInput(0.03, at: start)                            // quiet
        state.pushInput(0.5, at: start.addingTimeInterval(0.1))     // speech starts

        let onset = RecordingState.amplitude(
            of: state.inputLevels,
            now: start.addingTimeInterval(0.1)
        )
        // The newest reading alone: 0.5 * 1.4. A blend with the quiet one
        // would land near 0.37 and read as lag.
        #expect(abs(onset - 0.7) < 0.01)
    }

    @Test func stoppingClearsBothChannels() {
        let state = RecordingState()
        feed(state, channel: .system, tick: systemTick, until: 0.5) { _ in 0.7 }
        feed(state, channel: .microphone, tick: micTick, until: 0.5) { _ in 0.7 }

        state.markStopped()

        #expect(state.inputLevels.isEmpty)
        #expect(state.outputLevels.isEmpty)
        #expect(state.inputAmplitude == 0)
        #expect(state.outputAmplitude == 0)
    }

    @Test func levelsAreClampedToTheMeterRange() {
        let state = RecordingState()
        state.pushInput(-3, at: start)
        state.pushOutput(9, at: start)

        #expect(state.inputLevels.first?.value == 0)
        #expect(state.outputLevels.first?.value == 1)
    }
}
