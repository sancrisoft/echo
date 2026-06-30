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

    /// Short human-readable status for the popover (e.g. "Requesting permissions…").
    var status: String = ""

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
        startedAt = Date()
        isRecording = true
    }

    func markStopped() {
        isRecording = false
        startedAt = nil
        inputLevels = Array(repeating: Self.idleLevel, count: barCount)
        outputLevels = Array(repeating: Self.idleLevel, count: barCount)
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

    /// Insert a finished segment, keeping `segments` sorted by start time.
    func append(_ segment: TranscriptSegment) {
        let index = segments.firstIndex { $0.start > segment.start } ?? segments.count
        segments.insert(segment, at: index)
    }
}
