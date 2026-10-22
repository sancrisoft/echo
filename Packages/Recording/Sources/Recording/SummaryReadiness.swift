//
//  SummaryReadiness.swift
//  Recording
//
//  Where the summary model is, as one value the models panel and the welcome
//  screen draw: the state on the right of its row, and which action that row
//  offers.
//
//  It gates nothing. A recording waits for the transcription model only
//  (product owner, 2026-10-02): without the summary model there is still a
//  transcript, and the notes follow once the model arrives.
//
//  Its own vocabulary rather than `SummaryModelState`, for the reason
//  `RecordingReadiness` has one: the surfaces that draw it sit above this
//  package and import neither model's package, and what they need is the
//  state in the models artboard's terms.
//

import ModelDelivery
import Summarization

public enum SummaryReadiness: Equatable, Sendable {

    /// Not on disk and not being fetched yet: before the launch fetch
    /// reaches it, which waits for the transcription model first.
    case waitingToDownload

    /// Being fetched; the fraction is the model's own, clamped and forward
    /// only, never a guess.
    case downloading(Double)

    /// The user paused the download. A persisted intent: the launch fetch
    /// leaves it paused until the user resumes it.
    case paused

    /// A download the app quit in the middle of left files to resume from.
    /// No fraction on purpose: the partial byte count on disk is not
    /// trustworthy, so nothing here could honestly say how far it got.
    case incomplete

    /// On disk, coming into memory for a meeting's summary. Released again
    /// once it goes idle, which is why this comes back after a while.
    case loading

    /// A complete snapshot is on disk. Whether the weights are in memory is
    /// not this value's business.
    case ready

    /// The fetch or the load failed, with the reason it failed for.
    case failed(String)

    public var isReady: Bool { self == .ready }

    /// The download's whole percent while it runs, `nil` otherwise: from the
    /// one clamp, rounded down so it never claims 100 before the files are
    /// verified.
    public var downloadPercent: Int? {
        guard case .downloading(let fraction) = self else { return nil }
        return DownloadProgress(fraction: fraction).percent
    }

    /// The readiness the model's own state amounts to.
    init(_ state: SummaryModelState) {
        switch state {
        case .notDownloaded: self = .waitingToDownload
        case .partiallyDownloaded: self = .incomplete
        case .paused: self = .paused
        case .downloading(let fraction): self = .downloading(fraction)
        case .loading: self = .loading
        case .ready: self = .ready
        case .failed(let reason): self = .failed(reason)
        }
    }
}
