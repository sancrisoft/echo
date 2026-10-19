//
//  RecordingReadiness.swift
//  Recording
//
//  Whether a recording can start, and if not, why — as one value every surface
//  that can start one reads to disable its Record and say what it is waiting
//  for.
//
//  A product owner's decision (2026-10-02) that reverses a behavior v1
//  defended: "recording never waits for a model" (discovery §7). Recording now
//  waits for the transcription model, because a meeting captured with nothing
//  on disk to transcribe it is audio the user cannot read. The summary model
//  never gates: the welcome screen's "Record without notes" is a transcript
//  without a summary, and the notes follow once that model arrives.
//
//  Its own vocabulary rather than `ParakeetModelState`: the surfaces that read
//  it sit above this package and below nothing that knows the model, and what
//  they need is the reason in the artboard's terms, not the model's internals.
//

import Transcription

public enum RecordingReadiness: Equatable, Sendable {

    /// The transcription model is on disk.
    case ready

    /// Not on disk and not being fetched yet — before the launch fetch runs,
    /// or while it waits out a recording or a pass.
    case waitingToDownload

    /// Being fetched; the fraction is the model's own, clamped and forward
    /// only, never a guess.
    case downloading(Double)

    /// The fetch failed, with the reason it failed for. The user's Retry runs
    /// it again (`RecordingSession.retryTranscriptionModel()`).
    case downloadFailed(String)

    public var isReady: Bool { self == .ready }

    /// The readiness the model's own state amounts to.
    init(_ state: ParakeetModelState) {
        switch state {
        case .ready: self = .ready
        case .absent: self = .waitingToDownload
        case .downloading(let fraction): self = .downloading(fraction)
        case .failed(let reason): self = .downloadFailed(reason)
        }
    }
}

/// Why `RecordingSession.start` refused to begin.
public enum RecordingRefusal: Equatable, Sendable {
    /// The transcription model is not on disk; the readiness says why.
    case transcriptionModelNotReady(RecordingReadiness)
}
