//
//  SummaryDocument.swift
//  Summarization
//
//  What the summarizer emits. The pipeline streams progressively more complete
//  documents as the model writes, and exactly one of them is final.
//
//  This package produces a document and stops. It does not decide when a
//  summary runs, it does not write `summary.md`, and it holds no notion of a
//  meeting's status — the scheduler and the finalization gate belong to
//  Recording, persistence to `MeetingStore`.
//

import Foundation

/// A summary at one moment in its generation.
public struct SummaryDocument: Hashable, Sendable {

    /// The Markdown to show, and — on a final document — the Markdown to
    /// persist. Never blank on a final document: if both reduce attempts came
    /// back empty, this carries the grounded facts rendered deterministically
    /// rather than nothing at all.
    public let markdown: String

    /// The facts the long route extracted, each carrying the segment ids that
    /// ground it. Empty on the single-pass route, which extracts no facts —
    /// its grounding is the prompt and the transcript in the same context.
    public let facts: MergedFacts

    /// The detected language, as an English language name ("Spanish"), or nil
    /// when detection had no confident answer. Carried out so a caller can
    /// record what the summary was written in without re-running detection.
    public let language: String?

    /// The model that wrote this, as a person would read it ("Qwen3.5 4B").
    public let modelName: String

    /// Whether this is the completed document.
    ///
    /// The one bit a caller must respect before persisting anything. Every
    /// earlier element of the stream is a partial document — real Markdown, but
    /// the model has not finished writing it. A generation that is cancelled or
    /// fails never emits a final document at all: the stream throws instead.
    ///
    /// v1 signalled completion only by its stream ending, which made "did this
    /// finish?" a property of the consumer's control flow rather than of the
    /// value. Every consumer got it right; nothing about the shape helped them.
    public let isFinal: Bool

    public init(
        markdown: String,
        facts: MergedFacts = MergedFacts(),
        language: String? = nil,
        modelName: String,
        isFinal: Bool
    ) {
        self.markdown = markdown
        self.facts = facts
        self.language = language
        self.modelName = modelName
        self.isFinal = isFinal
    }
}

/// Where a long-route generation has got to.
///
/// Typed rather than a sentence, for the reason `ModelDelivery` reports a phase
/// and a fraction: the words a user reads belong to the UI, and a package that
/// hardcodes "Summarizing part 3/7…" cannot be localized or restyled without a
/// change here. The single-pass route reports nothing — it is one generation
/// with no parts to count.
public enum SummaryPhase: Equatable, Sendable {
    /// Mapping one chunk. `part` is 1-based, for display.
    case mapping(part: Int, of: Int)
    /// Writing the final document from the merged material.
    case reducing
    /// Nothing left to report. v1 sent an empty string here to clear its status
    /// line; this is that signal, named.
    case finished
}
