//
//  TextGenerating.swift
//  Echo
//
//  The runtime-agnostic seam between the summarization pipeline and the
//  LLM engine. Production uses MLXTextEngine; tests inject a scripted fake
//  so the full streaming/accumulation path runs without a real model
//  (SPEC-05's map-reduce work builds on the same seam).
//

import Foundation

/// One streamed generation. `system` + `user` become the model's chat
/// template; the stream yields raw text deltas exactly as the model emits
/// them (no buffering, no line splitting — that's the consumer's job).
/// Terminating the stream must cancel the underlying generation.
nonisolated protocol TextGenerating: Sendable {
    func stream(system: String, user: String, params: GenerationParams)
        -> AsyncThrowingStream<String, Error>
}

/// Sampling parameters, kept engine-neutral. Defaults preserve the values the
/// server-backed pipeline shipped with; MLX maps all of them 1:1
/// (GenerateParameters has temperature/topP/maxTokens and repetition/
/// frequency/presence penalties).
nonisolated struct GenerationParams: Sendable {
    var temperature: Float = 0.3
    var topP: Float = 0.9
    var maxTokens: Int = 3072
    var repetitionPenalty: Float = 1.1
    /// Recurrence penalties that work across NDJSON lines, not just within
    /// one — they discourage the degenerate repetition loops small models
    /// fall into (same values the HTTP body used to send).
    var frequencyPenalty: Float = 0.6
    var presencePenalty: Float = 0.3

    /// Tuning for the adaptive markdown document (the single-pass summary).
    ///
    /// The defaults above were tuned for NDJSON: the 0.6 frequency / 0.3
    /// presence penalties exist to break the degenerate repetition loops small
    /// models fall into when emitting line-oriented JSON. On a free markdown
    /// document those same penalties punish tokens that legitimately repeat —
    /// every `- [ ] ` checkbox prefix, every recurrence of an entity name
    /// ("WhatsApp Business") — so a long structured document degrades as the
    /// penalties accumulate. Here they drop to zero and a mild 1.05 repetition
    /// penalty carries loop protection alone. Temperature rises 0.3 → 0.4 for
    /// structural variety (section shapes adapt per meeting) while staying
    /// grounded, and maxTokens 3072 → 4096 gives dense meetings the room the
    /// "summaries too concise" complaint said they lacked. The plain
    /// `GenerationParams()` default stays untouched on purpose — the NDJSON
    /// map phase and the row caption still depend on it.
    static let markdownSummary = GenerationParams(
        temperature: 0.4,
        topP: 0.95,
        maxTokens: 4096,
        repetitionPenalty: 1.05,
        frequencyPenalty: 0.0,
        presencePenalty: 0.0
    )
}
