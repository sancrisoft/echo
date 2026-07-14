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
}
