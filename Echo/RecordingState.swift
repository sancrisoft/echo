//
//  RecordingState.swift
//  Echo
//
//  Observable UI state for a recording session. This holds only display state;
//  the actual capture/transcription work lives in `RecordingController`, which
//  feeds levels and transcript segments into here.
//
//  Levels are driven by the real audio pipeline (AVAudioEngine for the mic,
//  ScreenCaptureKit for system audio) — never by simulated data.
//

import SwiftUI
import Observation
import os

/// One real capture level (0...1) and the instant it was measured.
///
/// The timestamp is the whole point. The two taps run at very different
/// cadences: the mic is an `AVAudioEngine` tap of 4096 frames — ~85–100 ms of
/// audio per callback — while system audio arrives on the Core Audio IO proc,
/// ~12 ms per callback. A window counted in *callbacks* therefore spans about
/// eight times more audio on the mic than on the system stream, which is
/// exactly how the mic wave ended up rendering an ~800 ms moving average (a
/// line that swims at a constant height no matter who is talking) next to a
/// system wave tracking ~90 ms. Windows over these are always measured in
/// seconds.
nonisolated struct LevelSample: Sendable, Equatable {
    let value: CGFloat
    let at: Date
}

@Observable
@MainActor
final class RecordingState {

    /// How much *audio* the rendered amplitude averages over, per channel.
    ///
    /// Deliberately shorter than the mic tap's measured 100 ms callback
    /// interval, because averaging is pure latency on that channel: with a
    /// window wider than the cadence the indigo wave renders the mean of the
    /// current reading and the previous one, i.e. audio up to 200 ms old, on
    /// top of the 100 ms the tap already costs to accumulate. Under the
    /// cadence, the mic falls through to its newest reading — the freshest
    /// thing that exists — while the ~12 ms system tap still averages ~5
    /// callbacks, which is what keeps the gray wave smooth rather than
    /// twitchy.
    static let levelWindow: TimeInterval = 0.06

    /// How long a channel may go without delivering before its wave drops to
    /// the resting line. Deliberately longer than `levelWindow`: a tap whose
    /// callback interval is itself longer than the window — the 4096-frame mic
    /// tap is ~85 ms at 48 kHz but ~256 ms on a 16 kHz device — must keep
    /// rendering its own newest reading between callbacks instead of
    /// flatlining. Only a channel that has genuinely stopped (the device
    /// disappeared) exceeds this.
    static let levelStaleAfter: TimeInterval = 0.5

    private(set) var isRecording = false
    private(set) var startedAt: Date?

    /// Recent per-channel capture levels, oldest first, pruned to
    /// `levelWindow`. `inputLevels` = microphone (the user); `outputLevels` =
    /// system (teammates).
    private(set) var inputLevels: [LevelSample] = []
    private(set) var outputLevels: [LevelSample] = []

    /// Aligned transcript, ordered by `start`. Both channels merge into here.
    private(set) var segments: [TranscriptSegment] = []

    /// Generated once from final transcript segments after recording stops.
    private(set) var summaryState: SummaryState = .idle

    /// Short human-readable status for the popover (e.g. "Requesting permissions…").
    var status: String = ""

    /// Subtle degradation notice while echo cancellation is reduced
    /// (SP-001 US-7); `nil` whenever echo handling is healthy.
    private(set) var echoNotice: String?

    /// Notice while the microphone is unavailable and the session continues
    /// with meeting audio only (SP-002 Reliability); `nil` whenever mic
    /// capture is healthy.
    private(set) var inputNotice: String?

    /// Per-channel input-health notices (SP-002 "no silent dropout";
    /// ADR-006 — raised/cleared by the observational classifier, never by
    /// anything that touches the audio path). Deliberately NOT `inputNotice`:
    /// that is S4's device-lost surface with its own episode discipline, and
    /// "the device is gone" and "the device delivers untranscribable signal"
    /// are different problems. Coexistence rule: each notice renders on its
    /// own row (device-lost above input health), so a health notice can
    /// never mask an active device-lost notice — and the classifier clears
    /// mic health state on every device change, so the two mic notices
    /// don't stack in practice.
    private(set) var micHealthNotice: String?
    private(set) var systemHealthNotice: String?

    /// The running session's *effective* capture scope (SP-008, ADR-027):
    /// the single per-session value every recording surface renders — island,
    /// popover, dashboard live row all read this and nothing else, so a
    /// scoped request that fell back to global is visibly "Everything" on
    /// every surface at once. Fixed by the end of `RecordingController.start`
    /// and never changed mid-session (a running session never silently
    /// widens); `nil` while idle.
    private(set) var captureScope: CaptureScope?

    func updateStatus(_ text: String) { status = text }

    var elapsed: TimeInterval {
        guard let startedAt else { return 0 }
        return Date().timeIntervalSince(startedAt)
    }

    // MARK: - Session lifecycle (called by RecordingController)

    func markStarted() {
        segments.removeAll()
        summaryState = .idle
        startedAt = Date()
        isRecording = true
    }

    func markStopped() {
        isRecording = false
        startedAt = nil
        captureScope = nil
        echoNotice = nil
        inputNotice = nil
        micHealthNotice = nil
        systemHealthNotice = nil
        // Emptied, not filled with a resting value: with nothing captured
        // there is no level to report, and the wave draws its own resting
        // line at zero amplitude.
        inputLevels = []
        outputLevels = []
    }

    // MARK: - Capture scope (called by RecordingController)

    /// Publishes the session's effective scope once `start` has fixed it
    /// (SP-008, ADR-027). Cleared by `markStopped`, never by callers.
    func setCaptureScope(_ scope: CaptureScope) {
        captureScope = scope
    }

    // MARK: - Echo handling (called by RecordingController)

    func applyEchoHandlingEffect(_ effect: EchoModeMachine.Effect) {
        echoNotice = EchoDegradationNotice.notice(after: effect)
    }

    // MARK: - Input-device handling (called by RecordingController)

    /// Raise (`String`) or clear (`nil`) the mic-unavailable notice (SP-002).
    func applyInputDeviceNotice(_ notice: String?) {
        inputNotice = notice
    }

    // MARK: - Input health (called by RecordingController)

    /// Applies one input-health classifier effect (SP-002 "no silent
    /// dropout"). The effect type is notice-only by construction (ADR-006),
    /// so this mapping is exhaustively just notice text in, notice text out.
    func applyInputHealthEffect(_ effect: InputHealthClassifier.Effect) {
        switch effect {
        case .showMicHealthNotice:
            micHealthNotice = InputHealthNotice.micMessage
        case .showSystemHealthNotice:
            systemHealthNotice = InputHealthNotice.systemMessage
        case .clearHealthNotice(.microphone):
            micHealthNotice = nil
        case .clearHealthNotice(.system):
            systemHealthNotice = nil
        }
    }

    // MARK: - Summary ingestion (called by RecordingController)

    func markSummaryGenerating() {
        summaryState = .generating
        status = "Generating summary…"
    }

    func markSummaryStreaming(_ summary: MeetingSummary) {
        summaryState = .streaming(summary)
    }

    func markSummaryReady(_ summary: MeetingSummary) {
        summaryState = .ready(summary)
        status = ""
    }

    func markSummaryUnavailable(_ message: String) {
        summaryState = .unavailable(message)
        status = ""
    }

    func markSummaryFailed(_ message: String) {
        summaryState = .failed(message)
        status = message
    }

    // MARK: - Level ingestion (called from the capture services)

    /// `now` is injectable so the cadence behaviour can be driven by a
    /// synthetic clock in tests; production always stamps the real instant the
    /// capture callback delivered the level.
    func pushInput(_ level: CGFloat, at now: Date = Date()) {
        inputLevels = Self.appending(level, to: inputLevels, at: now)
    }

    func pushOutput(_ level: CGFloat, at now: Date = Date()) {
        outputLevels = Self.appending(level, to: outputLevels, at: now)
    }

    /// Appends one measured level and drops everything that has aged out of
    /// `levelWindow` — pruning by age, never by count, which is what keeps the
    /// two very differently-paced taps comparable (see `LevelSample`). The
    /// buffer stays bounded by the window and the tap's own rate: ~5 samples
    /// on the system stream, exactly one on the mic.
    private static func appending(_ level: CGFloat, to samples: [LevelSample], at now: Date) -> [LevelSample] {
        var next = samples
        next.append(LevelSample(value: min(max(level, 0), 1), at: now))
        let cutoff = now.addingTimeInterval(-levelWindow)
        if let firstFresh = next.firstIndex(where: { $0.at >= cutoff }), firstFresh > 0 {
            next.removeFirst(firstFresh)
        }
        return next
    }

    // MARK: - Waveform amplitudes

    /// The microphone wave's height (0...1) — the user.
    var inputAmplitude: CGFloat { Self.amplitude(of: inputLevels) }

    /// The system wave's height (0...1) — teammates.
    var outputAmplitude: CGFloat { Self.amplitude(of: outputLevels) }

    /// One display amplitude from a channel's recent levels: the mean of the
    /// last `levelWindow` of audio, lightly gained so ordinary speech reads as
    /// a visible wave. Entirely real capture data.
    ///
    /// Freshness is re-checked here rather than trusted from the last prune:
    /// a channel that stops delivering callbacks altogether (the mic device
    /// disappears mid-session) must fall back to the resting line instead of
    /// freezing at whatever it last measured. A channel that is merely slower
    /// than the window keeps rendering its newest reading — see
    /// `levelStaleAfter`.
    static func amplitude(of samples: [LevelSample], now: Date = Date()) -> CGFloat {
        guard let newest = samples.last,
              now.timeIntervalSince(newest.at) <= levelStaleAfter
        else { return 0 }
        let window = samples.filter { now.timeIntervalSince($0.at) <= levelWindow }
        let considered = window.isEmpty ? [newest] : window
        let mean = considered.reduce(CGFloat(0)) { $0 + $1.value } / CGFloat(considered.count)
        return min(1, mean * 1.4)
    }

    // MARK: - Transcript ingestion (called from the transcription pipeline)

    private static let dedupLog = Logger(subsystem: "com.sancrisoft.Echo", category: "EchoDedup")
    private let echoDedup = EchoDedupPolicy()

    /// Insert a finished segment, keeping `segments` sorted by start time.
    /// Mic-channel segments that are speaker bleed (echo duplicates of a Team
    /// segment, per ADR-003) are suppressed instead of inserted; every
    /// suppression is logged so a wrongly deleted line stays diagnosable.
    func append(_ segment: TranscriptSegment) {
        if let match = echoDedup.suppressionMatch(for: segment, against: segments) {
            Self.dedupLog.info("""
            Suppressed echo segment "\(segment.text, privacy: .public)" \
            [\(segment.start, format: .fixed(precision: 2))s–\(segment.end, format: .fixed(precision: 2))s] \
            duplicating Team segment "\(match.text, privacy: .public)" \
            [\(match.start, format: .fixed(precision: 2))s–\(match.end, format: .fixed(precision: 2))s]
            """)
            return
        }
        let index = segments.firstIndex { $0.start > segment.start } ?? segments.count
        segments.insert(segment, at: index)
    }

    /// SP-005 S6: the final pass atomically replaced the just-stopped
    /// meeting's persisted transcript while its live segments were still on
    /// screen — swap in the final set so an open detail (and a later
    /// `retrySummary`) shows the transcript that actually exists on disk.
    /// Never during a recording: a live session owns its segments.
    func replaceSegments(_ finalSegments: [TranscriptSegment]) {
        guard !isRecording else { return }
        segments = finalSegments
    }
}
