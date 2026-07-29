//
//  TurnTemplateTests.swift
//  EchoTests
//
//  The executable form of ADR-010 (Echo owns the summary model's turn
//  template in code): the ChatML scaffold for Qwen3.5 is a pure function, so
//  its exact shape — marker order, system-content survival, the empty-think-
//  block generation prompt — is asserted with no model loaded. The Gemma
//  template this replaces shipped with zero test coverage; the swap is when
//  the template gains the unit test the runtime assert alone never was
//  (SP-004 Testing Decisions, layer 1).
//

import Testing
@testable import Echo

@Suite("ChatML turn template")
struct TurnTemplateTests {

    // MARK: Exact scaffold (tracer)

    /// The whole template, byte for byte, for Echo's single case (one system
    /// + one user message + generation prompt, thinking disabled) — the shape
    /// transcribed from the model repo's chat_template.jinja. Qwen uses no
    /// BOS, so <bos> must appear nowhere, and nothing may follow the empty
    /// think block's closing blank line.
    @Test(arguments: [
        (
            system: "You are a meeting summarizer.",
            user: "Summarize this meeting.",
            expected: "<|im_start|>system\nYou are a meeting summarizer.<|im_end|>\n"
                + "<|im_start|>user\nSummarize this meeting.<|im_end|>\n"
                + "<|im_start|>assistant\n<think>\n\n</think>\n\n"
        ),
        (
            system: "s",
            user: "u",
            expected: "<|im_start|>system\ns<|im_end|>\n"
                + "<|im_start|>user\nu<|im_end|>\n"
                + "<|im_start|>assistant\n<think>\n\n</think>\n\n"
        ),
    ] as [(system: String, user: String, expected: String)])
    func buildsTheExactChatMLScaffold(row: (system: String, user: String, expected: String)) {
        let prompt = MLXTextEngine.chatMLPrompt(system: row.system, user: row.user)
        #expect(prompt == row.expected)
        #expect(prompt.hasSuffix("<|im_start|>assistant\n<think>\n\n</think>\n\n"))
        #expect(!prompt.contains("<bos>"))
    }

    // MARK: System-prompt survival

    /// The historical failure mode this ownership exists to prevent: chat
    /// templates that silently fold or drop the system turn. The system
    /// content must land verbatim inside its own system turn.
    @Test func systemContentSurvivesVerbatim() {
        let system = "Ground every claim in the transcript. Never invent owners or due dates."
        let prompt = MLXTextEngine.chatMLPrompt(system: system, user: "Summarize.")
        #expect(prompt.contains("<|im_start|>system\n\(system)<|im_end|>\n"))
    }

    // MARK: User turn

    /// User content gets its own turn — between `<|im_start|>user\n` and
    /// `<|im_end|>` — never merged into the system turn.
    @Test func userContentLandsInItsOwnTurn() {
        let user = "[00:12] You: QA finished the regression pass yesterday."
        let prompt = MLXTextEngine.chatMLPrompt(system: "Take meeting notes.", user: user)
        #expect(prompt.contains("<|im_start|>user\n\(user)<|im_end|>\n"))
    }

    // MARK: Whitespace trimming

    /// Parity with the retired Gemma template: leading/trailing whitespace on
    /// both contents is trimmed, so pipeline callers that end their prompts
    /// with a newline don't smuggle blank lines into the turns.
    @Test func leadingAndTrailingWhitespaceIsTrimmed() {
        let prompt = MLXTextEngine.chatMLPrompt(system: "  Take notes. \n", user: "\n\n Transcript body \t")
        #expect(prompt.contains("<|im_start|>system\nTake notes.<|im_end|>\n"))
        #expect(prompt.contains("<|im_start|>user\nTranscript body<|im_end|>\n"))
    }

    // MARK: Thinking stays disabled

    /// The silent-failure risk of SP-004 open question 2: a template that
    /// re-enabled thinking would burn the token budget on reasoning the user
    /// never sees. The generation prompt must pre-fill exactly one EMPTY
    /// think block — `<think>\n\n</think>` with nothing inside — and no other
    /// `<think>` may exist anywhere in the prompt.
    @Test func thinkingStaysDisabled() {
        let prompt = MLXTextEngine.chatMLPrompt(system: "Take notes.", user: "Transcript body")
        #expect(prompt.contains("<think>\n\n</think>"))
        #expect(prompt.components(separatedBy: "<think>").count == 2)
        #expect(prompt.components(separatedBy: "</think>").count == 2)
    }
}
