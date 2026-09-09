//
//  TextGenerating.swift
//  Summarization
//
//  The seam between the pipeline and whatever runs the model. Production is
//  `MLXTextEngine`; every test in this package drives the full streaming,
//  line-splitting and accumulation path through a scripted fake, which is why
//  the pipeline layer needs neither MLX nor Metal nor a 3.3 GB download.
//
//  The protocol is deliberately one method wide. It carries a system string, a
//  user string and sampling parameters — no message array, no roles beyond
//  those two, no chat template. Turning those two strings into ChatML is the
//  engine's job and is done in code (ADR-010).
//

import Foundation

/// One streamed generation.
///
/// The stream yields raw text deltas exactly as the model emits them — no
/// buffering, no line splitting; splitting NDJSON into lines is the consumer's
/// job. Not `async` and not `throws`: the stream is returned synchronously and
/// failures arrive as stream failures.
///
/// Terminating the stream must cancel the underlying generation. The pipeline
/// relies on this for cancellation: it never signals a stop any other way.
public protocol TextGenerating: Sendable {
    func stream(
        system: String, user: String, params: GenerationParams
    )
        -> AsyncThrowingStream<String, Error>
}

/// Sampling parameters, kept engine-neutral.
///
/// The defaults are the NDJSON preset — the map phase and the row caption both
/// depend on `GenerationParams()` meaning exactly that, so the defaults are not
/// free to change.
///
/// The penalty WINDOW is not here. All three penalties are applied over a
/// 64-token context, and that number lives with the engine that maps these
/// values onto MLX, because it is a property of the runtime rather than of a
/// preset (see `MLXTextEngine`).
public struct GenerationParams: Hashable, Sendable {
    public var temperature: Float = 0.3
    public var topP: Float = 0.9
    public var maxTokens: Int = 3072
    public var repetitionPenalty: Float = 1.1
    /// Recurrence penalties that work across NDJSON lines, not just within
    /// one — they discourage the degenerate repetition loops small models fall
    /// into when emitting line-oriented JSON.
    public var frequencyPenalty: Float = 0.6
    public var presencePenalty: Float = 0.3

    public init(
        temperature: Float = 0.3,
        topP: Float = 0.9,
        maxTokens: Int = 3072,
        repetitionPenalty: Float = 1.1,
        frequencyPenalty: Float = 0.6,
        presencePenalty: Float = 0.3
    ) {
        self.temperature = temperature
        self.topP = topP
        self.maxTokens = maxTokens
        self.repetitionPenalty = repetitionPenalty
        self.frequencyPenalty = frequencyPenalty
        self.presencePenalty = presencePenalty
    }

    /// Tuning for the adaptive Markdown document, on both routes.
    ///
    /// The defaults above were tuned for NDJSON: the 0.6 frequency / 0.3
    /// presence penalties exist to break the degenerate repetition loops small
    /// models fall into when emitting line-oriented JSON. On a free Markdown
    /// document those same penalties punish tokens that legitimately repeat —
    /// every `- [ ] ` checkbox prefix, every recurrence of an entity name — so a
    /// long structured document degrades as the penalties accumulate. Here they
    /// drop to zero and a mild 1.05 repetition penalty carries loop protection
    /// alone. Temperature rises 0.3 → 0.4 for structural variety (section shapes
    /// adapt per meeting) while staying grounded, and maxTokens 3072 → 4096 gives
    /// dense meetings the room the "summaries too concise" complaint said they
    /// lacked.
    public static let markdownSummary = GenerationParams(
        temperature: 0.4,
        topP: 0.95,
        maxTokens: 4096,
        repetitionPenalty: 1.05,
        frequencyPenalty: 0.0,
        presencePenalty: 0.0
    )

    /// The row caption: one short sentence, so the token ceiling drops to 64 and
    /// the temperature to 0.2. Everything else stays at the NDJSON defaults on
    /// purpose — these are the values the caption was measured with.
    public static let caption = GenerationParams(temperature: 0.2, maxTokens: 64)
}
