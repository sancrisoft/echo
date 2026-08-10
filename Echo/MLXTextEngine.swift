//
//  MLXTextEngine.swift
//  Echo
//
//  TextGenerating implemented over mlx-swift-lm: in-process inference against
//  the loaded ModelContainer — no subprocess, no HTTP server.
//
//  Prompt construction is manual. The vendored tokenizer surface Echo already
//  ships (swift-transformers' Tokenizer) exposes encode/decode but not
//  applyChatTemplate, and chat templates historically fold or drop the system
//  prompt for some models (Gemma among them) — building the turn string
//  ourselves keeps the system prompt's survival guaranteed and inspectable
//  (ADR-010). The format below is ChatML, transcribed from the model repo's
//  chat_template.jinja (mlx-community/Qwen3.5-4B-OptiQ-4bit) for the exact
//  case we use: one system + one user message, generation prompt, thinking
//  disabled.
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
        let prompt = Self.chatMLPrompt(system: system, user: user)
        // Belt-and-braces check that the system prompt survived templating —
        // the historical Gemma failure mode this guards against is a template
        // that silently drops the system turn.
        Self.log.debug("Prompt head: \(String(prompt.prefix(160)), privacy: .public)")
        assert(prompt.contains(system.trimmingCharacters(in: .whitespacesAndNewlines)))

        try await container.perform { (context: ModelContext) in
            // addSpecialTokens: false — the template string already carries
            // its own turn markers, and Qwen defines no BOS at all; letting
            // the tokenizer inject specials would corrupt the prompt.
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

    /// ChatML turn format for [system, user] + generation prompt, per the
    /// model repo's chat_template.jinja: system and user content are trimmed,
    /// each turn is `<|im_start|>role\n…<|im_end|>\n`, no BOS anywhere (Qwen
    /// prepends none), and with thinking disabled the generation prompt
    /// pre-fills an EMPTY `<think>` block so the model starts emitting answer
    /// content directly. Generation stops on the tokenizer's declared
    /// end-of-turn token (`<|im_end|>`, tokenizer_config.json's eos_token —
    /// this repo's generation_config.json carries only sampling params),
    /// which the model factory resolves automatically.
    static func chatMLPrompt(system: String, user: String) -> String {
        let sys = system.trimmingCharacters(in: .whitespacesAndNewlines)
        let usr = user.trimmingCharacters(in: .whitespacesAndNewlines)
        return "<|im_start|>system\n\(sys)<|im_end|>\n"
            + "<|im_start|>user\n\(usr)<|im_end|>\n"
            + "<|im_start|>assistant\n<think>\n\n</think>\n\n"
    }
}
