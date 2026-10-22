//
//  SummarizationError.swift
//  Summarization
//
//  What this package throws. `LocalizedError` because every case can reach a
//  user as a notice on the owning observable (architecture §7, tier 2).
//
//  There is no cancelled case, for the same reason `ModelDeliveryError` has
//  none: a stop is an intent the caller records before cancelling, never a
//  `CancellationError` read back afterwards. Cancellation propagates as
//  `CancellationError` and means exactly one thing — nothing is persisted.
//

import Foundation

public enum SummarizationError: Error, LocalizedError, Equatable {

    /// No segments to summarize. Thrown before any engine call, so an empty
    /// transcript never loads a model or spends a token.
    case emptyTranscript

    /// The engine failed. Carries the underlying description because it is the
    /// only thing that distinguishes "no model on disk" from "the runtime died".
    case modelUnavailable(String)

    /// Both attempts at a document came back empty after sanitation. On the
    /// long route this is caught and degraded to the facts-only summary; on the
    /// single-pass route there is nothing grounded to fall back on, so it
    /// propagates.
    case emptyModelResponse

    public var errorDescription: String? {
        switch self {
        case .emptyTranscript:
            return "No transcript was captured."
        case .modelUnavailable(let message):
            return "The summary model is unavailable: \(message)"
        case .emptyModelResponse:
            return "The summary model returned an empty summary."
        }
    }
}
