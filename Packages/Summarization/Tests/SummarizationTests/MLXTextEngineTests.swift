//
//  MLXTextEngineTests.swift
//  SummarizationTests
//
//  The prompt the engine actually sends. `chatMLPrompt` is pure and internal,
//  so the whole turn format is assertable with no MLX, no Metal, no snapshot
//  and no 3.3 GB download — the ChatML string is built in code precisely so it
//  can be pinned here.
//
//  This suite REPLACES two things v1 relied on instead: an `assert` that the
//  system prompt survived templating, which compiled out of release and so
//  never ran where it mattered, and a debug log of the prompt's first 160
//  characters at `privacy: .public`, which could carry transcript text into
//  the unified log. A test runs in CI and carries nothing.
//
//  That the markers encode as SINGLE special tokens is a property of the
//  snapshot's vocabulary rather than of this string, so it lives in the
//  acceptance suite where a real tokenizer is on disk.
//

import Foundation
import Testing

@testable import Summarization

@Suite("ChatML prompt construction")
struct MLXTextEngineTests {

    @Test("the turn format is exactly ChatML with a thinking-disabled generation prompt")
    func promptIsExactlyChatML() {
        let prompt = MLXTextEngine.chatMLPrompt(system: "You take notes.", user: "What was decided?")

        #expect(
            prompt == """
                <|im_start|>system
                You take notes.<|im_end|>
                <|im_start|>user
                What was decided?<|im_end|>
                <|im_start|>assistant
                <think>

                </think>


                """
        )
    }

    @Test("both contents are trimmed")
    func contentsAreTrimmed() {
        let prompt = MLXTextEngine.chatMLPrompt(
            system: "  \n You take notes. \n\n", user: "\n\t What was decided? \n")

        #expect(prompt.contains("<|im_start|>system\nYou take notes.<|im_end|>\n"))
        #expect(prompt.contains("<|im_start|>user\nWhat was decided?<|im_end|>\n"))
        // Trimmed, not merely stripped at the ends of the whole prompt: no
        // stray whitespace survives between a content and its closing marker.
        #expect(!prompt.contains(" <|im_end|>"))
        #expect(!prompt.contains("\n<|im_end|>"))
    }

    /// Qwen prepends no BOS at all, and the engine encodes with
    /// `addSpecialTokens: false` for that reason. A beginning-of-sequence
    /// token appearing here — from any vocabulary's convention — would mean the
    /// prompt no longer matches the one the model's own template produces.
    @Test("no BOS token appears anywhere in the prompt")
    func noBOSToken() {
        let prompt = MLXTextEngine.chatMLPrompt(system: "You take notes.", user: "What was decided?")

        #expect(prompt.hasPrefix("<|im_start|>system\n"))
        for bos in ["<s>", "<|begin_of_text|>", "<|startoftext|>", "<|endoftext|>", "[BOS]"] {
            #expect(!prompt.contains(bos))
        }
    }

    /// The system prompt is the whole instruction set — the sections, the
    /// grounding rules, the language rule. A template that folded or dropped
    /// the system turn (as some chat templates do) would degrade every summary
    /// without erroring, so its survival is asserted verbatim, multi-line
    /// content and all.
    @Test("the system prompt survives verbatim")
    func systemPromptSurvivesVerbatim() {
        let system = """
            You write meeting notes.
            - Ground every claim in the transcript.
            - Never invent an owner, a decision or a due date.
            """
        let prompt = MLXTextEngine.chatMLPrompt(system: system, user: "Transcript.")

        #expect(prompt.contains(system))
        #expect(prompt.contains("<|im_start|>system\n\(system)<|im_end|>"))
    }

    /// The empty think block IS the thinking-disabled mechanism — there is no
    /// flag. The generation prompt pre-fills an already-closed, empty
    /// `<think>` so the model starts emitting answer content directly; drop it
    /// and a 4B spends its token budget reasoning.
    @Test("the generation prompt pre-fills an empty, closed think block")
    func emptyThinkBlockIsPresent() throws {
        let prompt = MLXTextEngine.chatMLPrompt(system: "You take notes.", user: "What was decided?")

        #expect(prompt.hasSuffix("<|im_start|>assistant\n<think>\n\n</think>\n\n"))
        // Empty: nothing but whitespace between the two think markers, so the
        // block cannot read as reasoning the model should continue.
        let opened = try #require(prompt.range(of: "<think>"))
        let closed = try #require(prompt.range(of: "</think>"))
        let inner = prompt[opened.upperBound..<closed.lowerBound]
        #expect(inner.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
}
