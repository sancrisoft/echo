//
//  InputHealthClassifierTests.swift
//  EchoTests
//
//  SP-002 "no silent dropout" / "earbuds combo resolved or surfaced": the
//  input-health classifier consumes the per-chunk gate-decision record stream
//  (both channels) plus input-device signals, tracks sustained-discard
//  episodes, and drives the input-health notice — once per episode, within
//  the onset bound, never on silence/pauses/ambient, clearing on recovery.
//
//  These are table-driven tests over constructed record/event sequences
//  (spec Testing Decisions, layer 3: "table-driven verdict/level sequences
//  drive the classifier" — pure logic, mirroring EchoHandlingModeTests).
//  Time advances by the records' own durations; no clocks. The stats profiles
//  below are constructed values, not audio: the classifier consumes derived
//  metrics, and audio realism lives in the fixture suites (the exact
//  discrimination thresholds are TUNABLE against recorded fixtures in the
//  measurement phase — SP-002 open question 7).
//

import Foundation
import Testing
@testable import Echo

/// Collects `(sessionGeneration, effect)` deliveries from an
/// `InputHealthTracker`. Lock-guarded like `CollectingGateSink`: deliveries
/// can arrive from the pipeline's executor in production, so the collector
/// honors the same thread-safety contract.
private final class CollectingHealthEffects: @unchecked Sendable {

    private let lock = NSLock()
    private var storage: [(generation: Int, effect: InputHealthClassifier.Effect)] = []

    var deliver: @Sendable (Int, InputHealthClassifier.Effect) -> Void {
        { [self] generation, effect in
            lock.lock()
            defer { lock.unlock() }
            storage.append((generation, effect))
        }
    }

    var collected: [(generation: Int, effect: InputHealthClassifier.Effect)] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

struct InputHealthClassifierTests {

    // MARK: - Constructed stats profiles

    /// The silent-dropout signature (glossary): speech-like structure at an
    /// honest external-mic level — meter-visible energy, bursty windows,
    /// peaky crest — but too quiet for every gate level term, so the chunk
    /// is dropped on both channels. This is the profile that must accumulate.
    private static let discardedSpeechStats = AudioStats(
        rms: 0.005,            // above the 0.004 hard floor (waveform-visible)…
        peak: 0.028,           // …and above the 0.020 peak floor, so it gates
                               // on the *clear-speech* level terms, not silence
        activeRatio: 0.5,
        speechWindowRatio: 0.35,
        strongWindowRatio: 0.05,
        noiseFloorRMS: 0.001,
        dynamicRangeDB: 14,
        crestFactor: 5.6
    )

    /// Steady ambient room tone: meter-visible RMS but flat (sine-like crest,
    /// few active windows). Dropped by the gates AND below the activity
    /// heuristic — the false-positive direction the spec binds ("silence,
    /// normal pauses, and ambient room tone never raise the notice").
    private static let ambientRoomToneStats = AudioStats(
        rms: 0.005,
        peak: 0.0071,          // ≈ rms·√2: a flat hum, fails the peak hard floor
        activeRatio: 0.15,
        speechWindowRatio: 0,
        strongWindowRatio: 0,
        noiseFloorRMS: 0.005,
        dynamicRangeDB: 0.5,
        crestFactor: 1.41
    )

    /// True silence — a dead input. Shows a dead waveform, so no honest-UI
    /// contradiction exists and nothing may accumulate.
    private static let silenceStats = AudioStats(
        rms: 0, peak: 0, activeRatio: 0, speechWindowRatio: 0,
        strongWindowRatio: 0, noiseFloorRMS: 0, dynamicRangeDB: 0, crestFactor: 0
    )

    /// Healthy conversational speech: passes every clear-speech gate term on
    /// both channels — the transcribing steady state that ends episodes.
    private static let transcribableSpeechStats = AudioStats(
        rms: 0.03,
        peak: 0.12,
        activeRatio: 0.6,
        speechWindowRatio: 0.35,
        strongWindowRatio: 0.2,
        noiseFloorRMS: 0.002,
        dynamicRangeDB: 15,
        crestFactor: 4.0
    )

    // MARK: - Record constructors (time base = the records' own durations)

    private static func droppedActivity(
        on channel: AudioChannel, duration: TimeInterval = 1.0, at offset: TimeInterval = 0
    ) -> GateDecisionRecord {
        GateDecisionRecord(
            channel: channel, chunkDuration: duration,
            chunkStartOffset: offset, stats: discardedSpeechStats
        )
    }

    private static func droppedAmbient(
        on channel: AudioChannel, duration: TimeInterval = 1.0, at offset: TimeInterval = 0
    ) -> GateDecisionRecord {
        GateDecisionRecord(
            channel: channel, chunkDuration: duration,
            chunkStartOffset: offset, stats: ambientRoomToneStats
        )
    }

    private static func droppedSilence(
        on channel: AudioChannel, duration: TimeInterval = 1.0, at offset: TimeInterval = 0
    ) -> GateDecisionRecord {
        GateDecisionRecord(
            channel: channel, chunkDuration: duration,
            chunkStartOffset: offset, stats: silenceStats
        )
    }

    private static func transcribed(
        on channel: AudioChannel, duration: TimeInterval = 1.0, at offset: TimeInterval = 0
    ) -> GateDecisionRecord {
        GateDecisionRecord(
            channel: channel, chunkDuration: duration,
            chunkStartOffset: offset, stats: transcribableSpeechStats
        )
    }

    /// Guards the profile constants above against silent gate-threshold
    /// drift: every constructed record must carry the verdict its test
    /// scenario claims, on both channels, or the whole table is meaningless.
    @Test func constructedProfilesCarryTheirIntendedGateVerdicts() {
        for channel in [AudioChannel.microphone, .system] {
            #expect(Self.droppedActivity(on: channel).verdict == .drop)
            #expect(Self.droppedAmbient(on: channel).verdict == .drop)
            #expect(Self.droppedSilence(on: channel).verdict == .drop)
            #expect(Self.transcribed(on: channel).verdict == .transcribe)
        }
    }

    // MARK: - Onset bound (SP-002 "no silent dropout", US-3/US-4)

    /// Sustained discarded speech-like activity on the mic channel raises the
    /// mic health notice exactly once — and only once the accumulated
    /// discarded-activity duration crosses the onset bound: nothing one chunk
    /// before the crossing, the show effect at the crossing chunk, and no
    /// re-fire while the same episode continues.
    @Test func micSustainedDiscardNoticesExactlyOnceAtTheOnsetBound() {
        var classifier = InputHealthClassifier()
        let bound = InputHealthClassifier.onsetBound
        let wholeChunksBeforeBound = Int(bound) - 1   // 1 s chunks: 29 of them

        for i in 0 ..< wholeChunksBeforeBound {
            let effect = classifier.handle(
                .gateDecision(Self.droppedActivity(on: .microphone, at: TimeInterval(i)))
            )
            #expect(effect == nil, "noticed after only \(i + 1) s of discarded activity")
        }

        // The crossing chunk: accumulated duration reaches the bound.
        let crossing = classifier.handle(
            .gateDecision(Self.droppedActivity(on: .microphone, at: bound - 1))
        )
        #expect(crossing == .showMicHealthNotice)

        // The episode continues: once per episode, never a re-fire.
        let continued = classifier.handle(
            .gateDecision(Self.droppedActivity(on: .microphone, at: bound))
        )
        #expect(continued == nil)
    }

    // MARK: - False-positive bar (SP-002 Reliability: conservative in both directions)

    /// Silence, normal pauses, and ambient room tone never raise the notice:
    /// two hours of dropped quiet chunks — alternating true silence and
    /// meter-visible-but-flat room tone, on both channels — accumulate
    /// nothing and emit zero effects. This is the SP-001 silence/ambient
    /// fixture bar expressed at the classifier level.
    @Test func hoursOfDroppedSilenceAndAmbientNeverNotice() {
        var classifier = InputHealthClassifier()
        var offset: TimeInterval = 0

        for second in 0 ..< (2 * 60 * 60) {
            for channel in [AudioChannel.microphone, .system] {
                let record = second.isMultiple(of: 2)
                    ? Self.droppedSilence(on: channel, at: offset)
                    : Self.droppedAmbient(on: channel, at: offset)
                #expect(classifier.handle(.gateDecision(record)) == nil)
            }
            offset += 1
        }
    }

    // MARK: - Recovery (episode end) and re-notification

    /// A transcribed chunk on the channel is recovery: it ends the episode
    /// and clears the active notice automatically. A later sustained-discard
    /// episode is a NEW episode and notifies again — once, at its own onset
    /// bound (fresh accumulation, not spam).
    @Test func transcribedChunkClearsTheNoticeAndAFreshEpisodeReNotifies() {
        var classifier = InputHealthClassifier()
        var offset: TimeInterval = 0

        func discardUntilNotice() -> [InputHealthClassifier.Effect] {
            var effects: [InputHealthClassifier.Effect] = []
            for _ in 0 ..< Int(InputHealthClassifier.onsetBound) {
                if let effect = classifier.handle(
                    .gateDecision(Self.droppedActivity(on: .microphone, at: offset))
                ) {
                    effects.append(effect)
                }
                offset += 1
            }
            return effects
        }

        #expect(discardUntilNotice() == [.showMicHealthNotice])

        let recovery = classifier.handle(
            .gateDecision(Self.transcribed(on: .microphone, at: offset))
        )
        offset += 1
        #expect(recovery == .clearHealthNotice(.microphone))

        // Fresh episode: accumulation restarted from zero, so the re-notice
        // arrives exactly at the bound again — not earlier (no carried-over
        // evidence) and not suppressed (new episode, new notice).
        #expect(discardUntilNotice() == [.showMicHealthNotice])
    }

    /// Recovery while no notice is active (the episode never reached the
    /// onset bound) is silent: no clear effect without a preceding show —
    /// the same no-spurious-clear discipline S4's lifecycle machine keeps.
    @Test func transcribedChunkWithoutAnActiveNoticeEmitsNothing() {
        var classifier = InputHealthClassifier()

        for i in 0 ..< 5 {
            classifier.handle(
                .gateDecision(Self.droppedActivity(on: .microphone, at: TimeInterval(i)))
            )
        }
        #expect(classifier.handle(.gateDecision(Self.transcribed(on: .microphone, at: 5))) == nil)
    }

    // MARK: - Normal working patterns never notice

    /// A mostly-working mic: short runs of gated-out chunks between
    /// transcribed speech (thinking pauses, trailing utterances the gates
    /// discard). Every transcribed chunk ends the episode, so an hour of
    /// this pattern accumulates nothing — a working channel never notices,
    /// no matter how much borderline audio its gates discard in between.
    @Test func interleavedDiscardsAndTranscriptionsNeverAccumulateToANotice() {
        var classifier = InputHealthClassifier()
        var offset: TimeInterval = 0

        for _ in 0 ..< 100 {   // 100 × (5 s discarded + 1 s transcribed)
            for _ in 0 ..< 5 {
                #expect(classifier.handle(
                    .gateDecision(Self.droppedActivity(on: .microphone, at: offset))
                ) == nil)
                offset += 1
            }
            #expect(classifier.handle(
                .gateDecision(Self.transcribed(on: .microphone, at: offset))
            ) == nil)
            offset += 1
        }
    }

    /// The deliberate flip side — a genuinely gated-out mic with natural
    /// speech cadence: discarded activity separated by dropped *silence*
    /// (the speaker's own pauses; nothing transcribes because everything is
    /// gated out). Silence is neutral — it neither accumulates nor resets —
    /// so the episode still reaches the onset bound and the notice still
    /// fires. Anything else would let normal pauses indefinitely defer the
    /// notice SP-002's "always fires within its onset bound" demands.
    @Test func droppedSilenceBetweenDiscardedActivityDoesNotResetTheEpisode() {
        var classifier = InputHealthClassifier()
        var offset: TimeInterval = 0
        var effects: [InputHealthClassifier.Effect] = []
        let halfBound = Int(InputHealthClassifier.onsetBound) / 2   // 15 × 1 s

        func feed(_ record: GateDecisionRecord) {
            if let effect = classifier.handle(.gateDecision(record)) {
                effects.append(effect)
            }
            offset += 1
        }

        for _ in 0 ..< halfBound { feed(Self.droppedActivity(on: .microphone, at: offset)) }
        for _ in 0 ..< 10 { feed(Self.droppedSilence(on: .microphone, at: offset)) }
        #expect(effects.isEmpty)   // 15 s of activity + neutral silence: below the bound

        for _ in 0 ..< halfBound { feed(Self.droppedActivity(on: .microphone, at: offset)) }
        #expect(effects == [.showMicHealthNotice])
    }

    // MARK: - Team channel: the earbuds case (SP-002 US-6)

    /// Sustained discard on the system channel is surfaced the same way —
    /// the unsupported-combination notice. This is what catches a Bluetooth
    /// earbuds input+output dropout, including one that only begins
    /// mid-recording (a profile switch after minutes of healthy Team audio):
    /// the same episode discipline applies wherever in the session it starts,
    /// so the Team channel is never silently mute.
    @Test func systemChannelSustainedDiscardRaisesTheUnsupportedCombinationNotice() {
        var classifier = InputHealthClassifier()
        var offset: TimeInterval = 0

        // A healthy stretch first: the dropout begins mid-recording.
        for _ in 0 ..< 300 {
            #expect(classifier.handle(.gateDecision(Self.transcribed(on: .system, at: offset))) == nil)
            offset += 1
        }

        // Then every Team chunk starts gating out (the profile switch).
        var effects: [InputHealthClassifier.Effect] = []
        for _ in 0 ..< Int(InputHealthClassifier.onsetBound) {
            if let effect = classifier.handle(
                .gateDecision(Self.droppedActivity(on: .system, at: offset))
            ) {
                effects.append(effect)
            }
            offset += 1
        }
        #expect(effects == [.showSystemHealthNotice])

        // Recovery clears it, same as the mic channel.
        #expect(classifier.handle(.gateDecision(Self.transcribed(on: .system, at: offset)))
            == .clearHealthNotice(.system))
    }

    /// Channel independence: the mic and Team channels fail for different
    /// physical reasons (mic device vs. tap/route), so evidence never mixes —
    /// a mic episode neither advances nor clears the system channel's state,
    /// and vice versa, even interleaved chunk by chunk.
    @Test func channelsAccumulateAndClearIndependently() {
        var classifier = InputHealthClassifier()
        var offset: TimeInterval = 0
        var micEffects: [InputHealthClassifier.Effect] = []
        var systemEffects: [InputHealthClassifier.Effect] = []
        // Interleave: the mic discards activity while the Team channel
        // transcribes happily. Team recoveries must not end the mic episode.
        for _ in 0 ..< Int(InputHealthClassifier.onsetBound) {
            if let effect = classifier.handle(
                .gateDecision(Self.droppedActivity(on: .microphone, at: offset))
            ) {
                micEffects.append(effect)
            }
            if let effect = classifier.handle(
                .gateDecision(Self.transcribed(on: .system, at: offset))
            ) {
                systemEffects.append(effect)
            }
            offset += 1
        }
        #expect(micEffects == [.showMicHealthNotice])
        #expect(systemEffects.isEmpty)

        // And a mic recovery clears only the mic notice — the system
        // channel, now discarding, keeps its own independent accumulation.
        for _ in 0 ..< 10 {
            if let effect = classifier.handle(
                .gateDecision(Self.droppedActivity(on: .system, at: offset))
            ) {
                systemEffects.append(effect)
            }
            offset += 1
        }
        #expect(classifier.handle(.gateDecision(Self.transcribed(on: .microphone, at: offset)))
            == .clearHealthNotice(.microphone))
        #expect(systemEffects.isEmpty)
    }

    // MARK: - Input-device changes (new device, new evidence)

    /// An input-device change resets mic-channel accumulation: the evidence
    /// was gathered against the old device and says nothing about the new
    /// one, so the fresh device gets a full onset bound of its own before
    /// any notice (the conservative, no-false-positive direction).
    @Test func deviceChangeResetsMicAccumulation() {
        var classifier = InputHealthClassifier()
        let bound = Int(InputHealthClassifier.onsetBound)

        for i in 0 ..< (bound - 1) {
            classifier.handle(.gateDecision(Self.droppedActivity(on: .microphone, at: TimeInterval(i))))
        }
        #expect(classifier.handle(.micDeviceChanged) == nil)   // nothing to clear yet

        // One more discarded chunk would have crossed the bound on the old
        // device; on the new device it is second one of thirty.
        var effects: [InputHealthClassifier.Effect] = []
        for i in 0 ..< bound {
            if let effect = classifier.handle(
                .gateDecision(Self.droppedActivity(on: .microphone, at: TimeInterval(bound + i)))
            ) {
                effects.append(effect)
            }
            if i == 0 { #expect(effects.isEmpty, "old device's evidence survived the change") }
        }
        #expect(effects == [.showMicHealthNotice])
    }

    /// Design choice, recorded: a device change also clears an active mic
    /// health notice. The notice named evidence against the old device;
    /// keeping it up against a device the classifier knows nothing about
    /// would be a standing false positive — and if the new device also
    /// fails, a fresh episode re-notices within its own onset bound. (This
    /// mirrors S4's lifecycle machine treating a device change as a fresh
    /// capture attempt.) The device-lost degradation arrives through the
    /// same reset, so S4's mic-unavailable notice is never accompanied by a
    /// stale mic health notice underneath it.
    @Test func deviceChangeClearsAnActiveMicNoticeAndStartsAFreshEpisode() {
        var classifier = InputHealthClassifier()
        var offset: TimeInterval = 0

        for _ in 0 ..< Int(InputHealthClassifier.onsetBound) {
            classifier.handle(.gateDecision(Self.droppedActivity(on: .microphone, at: offset)))
            offset += 1
        }

        #expect(classifier.handle(.micDeviceChanged) == .clearHealthNotice(.microphone))

        // Same episode discipline afterwards: a full fresh bound, then one
        // new notice.
        var effects: [InputHealthClassifier.Effect] = []
        for _ in 0 ..< Int(InputHealthClassifier.onsetBound) {
            if let effect = classifier.handle(
                .gateDecision(Self.droppedActivity(on: .microphone, at: offset))
            ) {
                effects.append(effect)
            }
            offset += 1
        }
        #expect(effects == [.showMicHealthNotice])
    }

    /// The input device is mic-side hardware: changing it neither resets nor
    /// clears the Team channel's state — an earbuds-style system episode
    /// keeps its evidence across input flapping (US-6: the Team dropout must
    /// surface even while the user fiddles with input devices).
    @Test func deviceChangeLeavesTheSystemChannelUntouched() {
        var classifier = InputHealthClassifier()
        var offset: TimeInterval = 0
        var effects: [InputHealthClassifier.Effect] = []
        let halfBound = Int(InputHealthClassifier.onsetBound) / 2

        for _ in 0 ..< halfBound {
            if let effect = classifier.handle(
                .gateDecision(Self.droppedActivity(on: .system, at: offset))
            ) {
                effects.append(effect)
            }
            offset += 1
        }
        #expect(classifier.handle(.micDeviceChanged) == nil)
        for _ in 0 ..< halfBound {
            if let effect = classifier.handle(
                .gateDecision(Self.droppedActivity(on: .system, at: offset))
            ) {
                effects.append(effect)
            }
            offset += 1
        }

        // 15 s + device change + 15 s: still one uninterrupted system episode.
        #expect(effects == [.showSystemHealthNotice])
    }

    // MARK: - Global structural sweep (ADR-006)

    /// ADR-006: the classifier is observational — it "raises and clears the
    /// input-health notice … it never changes the audio path." Like the S4
    /// lifecycle sweep, the guarantee is structural: `Effect` has no case
    /// that could touch capture, the AEC, the gates, or the mode machine, so
    /// a path switch is unrepresentable. The switch below is exhaustive with
    /// NO default clause — adding any non-notice effect case breaks this
    /// test at compile time. On top of that, every generated event sequence
    /// must keep per-channel notice discipline: a show only while no notice
    /// is active on that channel, a clear only while one is (never spam,
    /// never a dangling clear), each effect on its own channel's state.
    @Test func noEventSequenceProducesAnythingButDisciplinedNoticeEffects() {
        // 12 s chunks (the pipeline's maximum) so sustained-discard episodes
        // can cross the 30 s onset bound inside short generated sequences.
        let events: [InputHealthClassifier.Event] = [
            .gateDecision(Self.droppedActivity(on: .microphone, duration: 12)),
            .gateDecision(Self.droppedAmbient(on: .microphone, duration: 12)),
            .gateDecision(Self.droppedSilence(on: .microphone, duration: 12)),
            .gateDecision(Self.transcribed(on: .microphone, duration: 12)),
            .gateDecision(Self.droppedActivity(on: .system, duration: 12)),
            .gateDecision(Self.transcribed(on: .system, duration: 12)),
            .micDeviceChanged,
        ]

        var sequences: [[InputHealthClassifier.Event]] = [[]]
        for _ in 0 ..< 5 {
            sequences = sequences.flatMap { prefix in events.map { prefix + [$0] } }
        }

        for sequence in sequences {
            var classifier = InputHealthClassifier()
            var noticeShowing: [AudioChannel: Bool] = [.microphone: false, .system: false]

            for event in sequence {
                guard let effect = classifier.handle(event) else { continue }

                // Exhaustive by design — no `default`. A new effect case
                // must be handled here, which is the moment to re-prove it
                // cannot reach the audio path.
                switch effect {
                case .showMicHealthNotice:
                    #expect(noticeShowing[.microphone] == false,
                            "mic notice re-fired within an episode: \(sequence)")
                    noticeShowing[.microphone] = true
                case .showSystemHealthNotice:
                    #expect(noticeShowing[.system] == false,
                            "system notice re-fired within an episode: \(sequence)")
                    noticeShowing[.system] = true
                case .clearHealthNotice(let channel):
                    #expect(noticeShowing[channel] == true,
                            "\(channel) clear without a preceding show: \(sequence)")
                    noticeShowing[channel] = false
                }
            }
        }
    }

    // MARK: - Wiring: fan-out sink and the session tracker

    /// The controller hands the pipeline ONE sink; the fan-out keeps the
    /// permanent OSLog diagnostic (US-12) and the input-health classifier
    /// (ADR-006) both fed from the same gate-decision stream — every record
    /// to every sink, in order.
    @Test func fanOutDeliversEveryRecordToEverySinkInOrder() {
        let first = CollectingGateSink()
        let second = CollectingGateSink()
        let fanOut = FanOutGateDiagnosticsSink([first, second])

        fanOut.record(Self.droppedActivity(on: .microphone, at: 0))
        fanOut.record(Self.transcribed(on: .system, at: 1))

        for sink in [first, second] {
            let records = sink.records
            #expect(records.count == 2)
            #expect(records.first?.channel == .microphone)
            #expect(records.first?.verdict == .drop)
            #expect(records.last?.channel == .system)
            #expect(records.last?.verdict == .transcribe)
        }
    }

    /// The tracker classifies only within a session: records arriving before
    /// `beginSession` or after `endSession` (capture-teardown stragglers)
    /// produce no effects — a notice can never appear while idle.
    @Test func trackerClassifiesOnlyWithinASession() {
        let effects = CollectingHealthEffects()
        let tracker = InputHealthTracker()
        tracker.onEffect = effects.deliver

        func thirtySixSecondsOfDiscard() {
            for i in 0 ..< 3 {
                tracker.record(Self.droppedActivity(
                    on: .microphone, duration: 12, at: TimeInterval(i * 12)
                ))
            }
        }

        thirtySixSecondsOfDiscard()                    // before any session
        #expect(effects.collected.isEmpty)

        tracker.beginSession(generation: 3)
        thirtySixSecondsOfDiscard()                    // inside the session
        #expect(effects.collected.count == 1)

        tracker.endSession()
        thirtySixSecondsOfDiscard()                    // stragglers after stop
        #expect(effects.collected.count == 1)
    }

    /// Effects carry the generation of the session whose evidence produced
    /// them (the controller drops stale deliveries by generation, like the
    /// engine-event path), and `beginSession` starts from zero evidence —
    /// nothing accumulated in one session can notice in the next.
    @Test func trackerTagsEffectsWithTheGenerationAndResetsEvidencePerSession() {
        let effects = CollectingHealthEffects()
        let tracker = InputHealthTracker()
        tracker.onEffect = effects.deliver

        tracker.beginSession(generation: 1)
        tracker.record(Self.droppedActivity(on: .microphone, duration: 12, at: 0))
        tracker.record(Self.droppedActivity(on: .microphone, duration: 12, at: 12))
        #expect(effects.collected.isEmpty)             // 24 s: below the bound

        tracker.beginSession(generation: 2)            // fresh session, fresh evidence
        tracker.record(Self.droppedActivity(on: .microphone, duration: 12, at: 0))
        tracker.record(Self.droppedActivity(on: .microphone, duration: 12, at: 12))
        #expect(effects.collected.isEmpty)             // old 24 s must not carry over

        tracker.record(Self.droppedActivity(on: .microphone, duration: 12, at: 24))
        let collected = effects.collected
        #expect(collected.count == 1)
        #expect(collected.first?.generation == 2)
        #expect(collected.first?.effect == .showMicHealthNotice)
    }

    /// Device signals flow through the tracker into the classifier: a device
    /// change after an active notice delivers the clear, tagged with the
    /// same session generation.
    @Test func trackerForwardsDeviceSignalsToTheClassifier() {
        let effects = CollectingHealthEffects()
        let tracker = InputHealthTracker()
        tracker.onEffect = effects.deliver

        tracker.beginSession(generation: 5)
        for i in 0 ..< 3 {
            tracker.record(Self.droppedActivity(
                on: .microphone, duration: 12, at: TimeInterval(i * 12)
            ))
        }
        tracker.noteMicDeviceChanged()

        let collected = effects.collected
        #expect(collected.count == 2)
        #expect(collected.first?.effect == .showMicHealthNotice)
        #expect(collected.last?.generation == 5)
        #expect(collected.last?.effect == .clearHealthNotice(.microphone))
    }

    // MARK: - Notice UI state (RecordingState mapping)

    /// Effects map to the per-channel English notice strings, clears are
    /// channel-scoped, and stopping the recording clears both — mirroring
    /// `RecordingStateEchoNoticeTests` for the third notice surface.
    @Test @MainActor func stateAppliesHealthEffectsAndStoppingClearsThem() {
        let state = RecordingState()
        state.markStarted()

        state.applyInputHealthEffect(.showMicHealthNotice)
        state.applyInputHealthEffect(.showSystemHealthNotice)
        #expect(state.micHealthNotice == InputHealthNotice.micMessage)
        #expect(state.systemHealthNotice == InputHealthNotice.systemMessage)

        state.applyInputHealthEffect(.clearHealthNotice(.microphone))
        #expect(state.micHealthNotice == nil)
        #expect(state.systemHealthNotice == InputHealthNotice.systemMessage)

        state.markStopped()
        #expect(state.micHealthNotice == nil)
        #expect(state.systemHealthNotice == nil)
    }

    /// Coexistence rule (recorded in `RecordingState`): the health notices
    /// live beside S4's device-lost notice, never in it — raising or
    /// clearing one surface must not touch the other, so a health notice
    /// can never mask an active device-lost notice.
    @Test @MainActor func healthNoticesNeverTouchTheDeviceLostNotice() {
        let state = RecordingState()
        state.markStarted()

        state.applyInputDeviceNotice(InputDeviceNotice.micUnavailableMessage)
        state.applyInputHealthEffect(.showSystemHealthNotice)
        #expect(state.inputNotice == InputDeviceNotice.micUnavailableMessage)
        #expect(state.systemHealthNotice == InputHealthNotice.systemMessage)

        state.applyInputHealthEffect(.clearHealthNotice(.system))
        #expect(state.inputNotice == InputDeviceNotice.micUnavailableMessage)

        state.applyInputDeviceNotice(nil)
        state.applyInputHealthEffect(.showMicHealthNotice)
        #expect(state.inputNotice == nil)
        #expect(state.micHealthNotice == InputHealthNotice.micMessage)
    }
}
