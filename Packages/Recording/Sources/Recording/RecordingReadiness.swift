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

import ModelDelivery
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

    /// The fetch's whole percent while it runs, `nil` otherwise: from the one
    /// clamp, rounded down so it never claims 100 before the files are
    /// verified.
    public var downloadPercent: Int? {
        guard case .downloading(let fraction) = self else { return nil }
        return DownloadProgress(fraction: fraction).percent
    }

    /// Why a recording cannot start, as every surface that offers one says it
    /// beside its held-back Record: the models artboard's row label and state
    /// ("Transcription · Waiting to download", "Transcription · 41%"), or the
    /// fetch's own reason. Approved by the product owner, 2026-10-02. `nil`
    /// once nothing is in the way.
    ///
    /// Here rather than with any one surface, because the island's faces, the
    /// menu and the window's title bar all say it, and one sentence said three
    /// ways is three sentences.
    public var waitingFor: String? {
        let state: String
        switch self {
        case .ready: return nil
        case .waitingToDownload: state = "Waiting to download"
        case .downloading:
            // Written the way the English interface writes it whatever the
            // Mac's region.
            state = "\(downloadPercent ?? 0)%"
        case .downloadFailed(let reason): state = reason
        }
        return "Transcription · \(state)"
    }

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
