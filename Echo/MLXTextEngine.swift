//
//  MLXTextEngine.swift
//  Echo
//
//  TextGenerating implemented over mlx-swift-lm: in-process inference against
//  the loaded ModelContainer — no subprocess, no HTTP server.
//
//  Prompt construction is manual. The vendored tokenizer surface Echo already
//  ships (ArgmaxCore's TokenizerWrapper) exposes encode/decode but not
//  applyChatTemplate, and Gemma templates historically fold the system prompt
//  into the first user turn — building the turn string ourselves keeps the
//  system prompt's survival guaranteed and inspectable. The format below is
//  transcribed from the model repo's chat_template.jinja
//  (mlx-community/gemma-4-12B-it-qat-OptiQ-4bit) for the exact case we use:
//  one system + one user message, generation prompt, thinking disabled.
//

import Foundation
import MLX
import MLXLMCommon
import os

nonisolated final class MLXTextEngine: TextGenerating {

    private static let log = Logger(subsystem: "com.sancrisoft.Echo", category: "MLXTextEngine")

    private let container: ModelContainer

    init(container: ModelContainer) {
        self.container = container
    }

    func stream(system: String, user: String, params: GenerationParams)
        -> AsyncThrowingStream<String, Error>
    {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.run(system: system, user: user, params: params, into: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            // Terminating the stream (consumer stops or errors out) cancels
            // the generation: MLXLMCommon's generate loop checks
            // Task.isCancelled per token and its own stream's onTermination
            // cancels the internal loop task.
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(
        system: String,
        user: String,
        params: GenerationParams,
        into continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async throws {
        let prompt = Self.gemmaPrompt(system: system, user: user)
        // Belt-and-braces check that the system prompt survived templating —
        // the historical Gemma failure mode this guards against is a template
        // that silently drops the system turn.
        Self.log.debug("Prompt head: \(String(prompt.prefix(160)), privacy: .public)")
        assert(prompt.contains(system.trimmingCharacters(in: .whitespacesAndNewlines)))

        try await container.perform { (context: ModelContext) in
            // addSpecialTokens: false — the template string already carries
            // <bos> and the turn markers; letting the tokenizer prepend its
            // own BOS would double it.
            let tokens = context.tokenizer.encode(text: prompt, addSpecialTokens: false)
            let input = LMInput(tokens: MLXArray(tokens))
            let stream = try MLXLMCommon.generate(
                input: input,
                parameters: Self.generateParameters(from: params),
                context: context
            )
            for await generation in stream {
                try Task.checkCancellation()
                if let chunk = generation.chunk, !chunk.isEmpty {
                    continuation.yield(chunk)
                }
            }
        }
    }

    /// Maps Echo's engine-neutral params onto MLX's. All three penalties exist
    /// in MLX; their context windows default to 20 tokens, so they are widened
    /// to 64 — the retired runtime's penalty-window default, which is the window the
    /// shipped values (1.1/0.6/0.3) were tuned against. Cross-line dedup is
    /// the accumulator's job either way.
    private static func generateParameters(from params: GenerationParams) -> GenerateParameters {
        GenerateParameters(
            maxTokens: params.maxTokens,
            temperature: params.temperature,
            topP: params.topP,
            repetitionPenalty: params.repetitionPenalty,
            repetitionContextSize: 64,
            presencePenalty: params.presencePenalty,
            presenceContextSize: 64,
            frequencyPenalty: params.frequencyPenalty,
            frequencyContextSize: 64
        )
    }

    /// Gemma-4 turn format for [system, user] + generation prompt, per the
    /// model repo's chat_template.jinja: system and user content are trimmed,
    /// each turn is `<|turn>role\n…<turn|>\n`, and with thinking disabled the
    /// generation prompt pre-fills an empty thought channel so the model
    /// starts emitting answer content directly. Generation stops on the ids in
    /// the repo's generation_config.json (includes the end-of-turn token),
    /// which the model factory loads automatically.
    static func gemmaPrompt(system: String, user: String) -> String {
        let sys = system.trimmingCharacters(in: .whitespacesAndNewlines)
        let usr = user.trimmingCharacters(in: .whitespacesAndNewlines)
        return "<bos><|turn>system\n\(sys)<turn|>\n"
            + "<|turn>user\n\(usr)<turn|>\n"
            + "<|turn>model\n<|channel>thought\n<channel|>"
    }
}
