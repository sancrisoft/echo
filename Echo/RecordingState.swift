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

@Observable
@MainActor
final class RecordingState {

    /// Number of bars rendered in each waveform.
    let barCount = 28

    /// Resting bar height (0...1) shown when a channel is silent.
    static let idleLevel: CGFloat = 0.05

    private(set) var isRecording = false
    private(set) var startedAt: Date?

    /// Rolling per-channel magnitudes (0...1), oldest first → newest last.
    /// `inputLevels` = microphone (the user); `outputLevels` = system (teammates).
    private(set) var inputLevels: [CGFloat]
    private(set) var outputLevels: [CGFloat]

    /// Aligned transcript, ordered by `start`. Both channels merge into here.
    private(set) var segments: [TranscriptSegment] = []

    /// Generated once from final transcript segments after recording stops.
    private(set) var summaryState: SummaryState = .idle

    /// Best-effort live text for each channel. These rows are provisional UI only:
    /// they are replaced by finished `segments` and should not feed summaries.
    private(set) var partialSegments: [AudioChannel: TranscriptSegment] = [:]
    private var partialSessionGeneration = 0
    private var partialGenerations: [AudioChannel: Int] = [:]
    private var partialRequestIDs: [AudioChannel: Int] = [:]

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

    /// Set when a session starts although the speech model never loaded
    /// (e.g. its download failed at launch): every ingested sample is being
    /// dropped, so the UI must say "not transcribing" instead of pretending.
    /// Cleared on stop; the next session re-checks after the load retry.
    private(set) var transcriberUnavailable = false

    func markTranscriberUnavailable(_ unavailable: Bool) {
        transcriberUnavailable = unavailable
    }

    func updateStatus(_ text: String) { status = text }

    init() {
        inputLevels = Array(repeating: Self.idleLevel, count: barCount)
        outputLevels = Array(repeating: Self.idleLevel, count: barCount)
    }

    var elapsed: TimeInterval {
        guard let startedAt else { return 0 }
        return Date().timeIntervalSince(startedAt)
    }

    // MARK: - Session lifecycle (called by RecordingController)

    func markStarted() {
        segments.removeAll()
        summaryState = .idle
        partialSegments.removeAll()
        partialGenerations.removeAll()
        partialRequestIDs.removeAll()
        startedAt = Date()
        isRecording = true
    }

    func markStopped() {
        isRecording = false
        startedAt = nil
        echoNotice = nil
        inputNotice = nil
        micHealthNotice = nil
        systemHealthNotice = nil
        transcriberUnavailable = false
        inputLevels = Array(repeating: Self.idleLevel, count: barCount)
        outputLevels = Array(repeating: Self.idleLevel, count: barCount)
        partialSegments.removeAll()
        partialGenerations.removeAll()
        partialRequestIDs.removeAll()
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

    func pushInput(_ level: CGFloat) {
        inputLevels = scroll(inputLevels, with: level)
    }

    func pushOutput(_ level: CGFloat) {
        outputLevels = scroll(outputLevels, with: level)
    }

    private func scroll(_ buffer: [CGFloat], with level: CGFloat) -> [CGFloat] {
        var next = buffer
        next.removeFirst()
        next.append(min(max(level, 0), 1))
        return next
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

    func beginPartialSession(_ sessionGeneration: Int) {
        partialSessionGeneration = sessionGeneration
        partialSegments.removeAll()
        partialGenerations.removeAll()
        partialRequestIDs.removeAll()
    }

    /// Replace the live provisional row for one channel.
    func updatePartial(
        _ segment: TranscriptSegment,
        sessionGeneration: Int,
        generation: Int,
        requestID: Int
    ) {
        guard sessionGeneration == partialSessionGeneration else { return }
        guard acceptsPartialUpdate(for: segment.channel, generation: generation, requestID: requestID) else { return }
        partialGenerations[segment.channel] = generation
        partialRequestIDs[segment.channel] = requestID
        partialSegments[segment.channel] = segment
    }

    /// Drop the provisional row for one channel, usually once its final segment
    /// is being committed.
    func clearPartial(
        for channel: AudioChannel,
        sessionGeneration: Int? = nil,
        generation: Int? = nil,
        requestID: Int? = nil
    ) {
        if let sessionGeneration {
            guard sessionGeneration == partialSessionGeneration else { return }
        }
        if let generation {
            if let requestID {
                guard acceptsPartialUpdate(for: channel, generation: generation, requestID: requestID) else { return }
                partialRequestIDs[channel] = requestID
            } else {
                let current = partialGenerations[channel] ?? 0
                guard generation >= current else { return }
                partialRequestIDs[channel] = 0
            }
            partialGenerations[channel] = generation
        }
        partialSegments[channel] = nil
    }

    func clearPartials(sessionGeneration: Int? = nil) {
        if let sessionGeneration {
            partialSessionGeneration = sessionGeneration
        }
        partialSegments.removeAll()
        partialGenerations.removeAll()
        partialRequestIDs.removeAll()
    }

    private func acceptsPartialUpdate(for channel: AudioChannel, generation: Int, requestID: Int) -> Bool {
        let currentGeneration = partialGenerations[channel] ?? 0
        let currentRequestID = partialRequestIDs[channel] ?? 0
        return generation > currentGeneration
            || (generation == currentGeneration && requestID >= currentRequestID)
    }
}
