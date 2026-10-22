//
//  MLXTextEngine.swift
//  Summarization
//
//  `TextGenerating` over mlx-swift-lm: in-process inference against a loaded
//  container. No subprocess, no HTTP server, nothing leaves the Mac.
//
//  Prompt construction is manual. The tokenizer surface this package ships
//  exposes encode and decode but not `applyChatTemplate`, and chat templates
//  historically fold or drop the system turn for some models — building the
//  turn string here keeps the system prompt's survival guaranteed and
//  inspectable. The format is ChatML, transcribed from the model repo's own
//  chat template for the exact case this package uses: one system message, one
//  user message, a generation prompt, thinking disabled.
//

import EchoCore
import Foundation
import MLX
import MLXLMCommon
import os

final class MLXTextEngine: TextGenerating {

    private static let log = Logger(subsystem: AppIdentity.logSubsystem, category: "MLXTextEngine")

    private let container: ModelContainer

    init(container: ModelContainer) {
        self.container = container
    }

    func stream(
        system: String, user: String, params: GenerationParams
    )
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
            // The seam's contract: terminating the stream cancels the
            // generation. MLX's generate loop checks cancellation per token, so
            // cancelling this task stops work rather than just detaching from it.
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
        try await container.perform { (context: ModelContext) in
            // addSpecialTokens: false — the template string already carries its
            // own turn markers, and Qwen defines no BOS at all; letting the
            // tokenizer inject specials would corrupt the prompt.
            let tokens = context.tokenizer.encode(text: prompt, addSpecialTokens: false)
            let stream = try MLXLMCommon.generate(
                input: LMInput(tokens: MLXArray(tokens)),
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

    /// Maps the engine-neutral params onto MLX's.
    ///
    /// All three penalties exist in MLX and their context windows default to 20
    /// tokens, so they are widened to 64 — the retired runtime's default, which
    /// is the window the shipped values (1.1 / 0.6 / 0.3) were tuned against.
    /// The window belongs here rather than on a preset because it is a property
    /// of this runtime, and it applies to EVERY generation: the Markdown preset
    /// zeroes two of the penalties but still runs with a 64-token window.
    /// Cross-line dedup is the accumulator's job either way.
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

    /// The ChatML turn format for [system, user] plus a generation prompt.
    ///
    /// Both contents are trimmed, each turn is
    /// `<|im_start|>role\n…<|im_end|>\n`, and there is no BOS anywhere because
    /// Qwen prepends none. With thinking disabled the generation prompt
    /// pre-fills an EMPTY `<think>` block, which is the entire mechanism — there
    /// is no flag — so the model starts emitting answer content directly.
    ///
    /// Generation stops on the tokenizer's declared end-of-turn token,
    /// `<|im_end|>`, which the model factory resolves automatically; nothing
    /// here passes a stop token explicitly.
    ///
    /// Internal so a test can pin that the system prompt survives templating.
    /// v1 guarded that with a debug log of the prompt's first 160 characters at
    /// `privacy: .public` and an `assert` that compiles out of release — a log
    /// line that could carry the transcript, plus a check that never ran where
    /// it mattered. A test runs in CI and carries nothing.
    static func chatMLPrompt(system: String, user: String) -> String {
        let sys = system.trimmingCharacters(in: .whitespacesAndNewlines)
        let usr = user.trimmingCharacters(in: .whitespacesAndNewlines)
        return "<|im_start|>system\n\(sys)<|im_end|>\n"
            + "<|im_start|>user\n\(usr)<|im_end|>\n"
            + "<|im_start|>assistant\n<think>\n\n</think>\n\n"
    }
}
