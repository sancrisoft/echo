//
//  SummarizationPipelineStreamTests.swift
//  EchoTests
//
//  Drives the single-pass route's full streaming path (TextGenerating seam →
//  markdown accumulation → sanitizer → snapshots) with a scripted fake engine,
//  no real model. Chunks are split at cruel points — mid-word, mid-line —
//  because that is exactly how token streaming arrives. The long route's
//  NDJSON map-reduce streaming lives in SummaryMapReduceTests.
//

import Foundation
import Testing
@testable import Echo

/// Scripted TextGenerating: each call to `stream` pops the next script (an
/// array of raw chunks) and replays it, recording exactly what the pipeline
/// asked for (system, user, params) so tests can assert on the real prompts
/// and sampling in flight. Thread-safe so the pipeline can call it from any
/// isolation.
private final class ScriptedEngine: TextGenerating, @unchecked Sendable {

    struct RecordedCall {
        let system: String
        let user: String
        let params: GenerationParams
    }

    private let lock = NSLock()
    private var scripts: [[String]]
    private var recorded: [RecordedCall] = []

    init(scripts: [[String]]) {
        self.scripts = scripts
    }

    func stream(system: String, user: String, params: GenerationParams)
        -> AsyncThrowingStream<String, Error>
    {
        lock.lock()
        recorded.append(RecordedCall(system: system, user: user, params: params))
        let chunks = scripts.isEmpty ? [] : scripts.removeFirst()
        lock.unlock()
        return AsyncThrowingStream { continuation in
            for chunk in chunks {
                continuation.yield(chunk)
            }
            continuation.finish()
        }
    }

    var calls: Int {
        lock.lock()
        defer { lock.unlock() }
        return recorded.count
    }

    var recordedCalls: [RecordedCall] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }
}

private func segment(_ text: String, id: UUID = UUID(), at start: TimeInterval = 0) -> TranscriptSegment {
    TranscriptSegment(
        id: id, channel: .microphone, speaker: .me, text: text, start: start, end: start + 4
    )
}

// MARK: - Generation presets

/// The markdown route needs different sampling than the NDJSON phases, and the
/// two must never drift into each other: the preset carries the markdown
/// tuning, the default init keeps the NDJSON tuning. Both are pinned by value
/// so a "harmless" retune shows up as a failing test, not a mystery regression
/// in summary quality.
@Suite("GenerationParams presets")
struct GenerationParamsPresetTests {

    @Test("markdownSummary carries the markdown-prose tuning")
    func markdownSummaryValues() {
        let params = GenerationParams.markdownSummary
        #expect(params.temperature == 0.4)
        #expect(params.topP == 0.95)
        #expect(params.maxTokens == 4096)
        #expect(params.repetitionPenalty == 1.05)
        #expect(params.frequencyPenalty == 0.0)
        #expect(params.presencePenalty == 0.0)
    }

    @Test("the default init keeps the NDJSON tuning untouched")
    func defaultsUnchanged() {
        let params = GenerationParams()
        #expect(params.temperature == 0.3)
        #expect(params.topP == 0.9)
        #expect(params.maxTokens == 3072)
        #expect(params.repetitionPenalty == 1.1)
        #expect(params.frequencyPenalty == 0.6)
        #expect(params.presencePenalty == 0.3)
    }
}

// MARK: - Markdown sanitizer (table)

/// A small model loves to wrap its whole answer in a code fence despite being
/// told not to. The sanitizer's whole job is trim + unwrap that one outer
/// fence; anything subtler is the renderer's problem (later slice).
@Suite("sanitizedMarkdown")
struct SanitizedMarkdownTests {

    @Test("clean documents pass through untouched", arguments: [
        "### Action Items\n- [ ] Ship it",
        "Plain paragraph.",
    ])
    func passthrough(document: String) {
        #expect(SummarizationPipeline.sanitizedMarkdown(document) == document)
    }

    @Test("leading and trailing whitespace is trimmed")
    func trimsWhitespace() {
        #expect(SummarizationPipeline.sanitizedMarkdown("\n\n  ### Notes\nBody.  \n\n") == "### Notes\nBody.")
    }

    @Test("an outer bare fence is unwrapped")
    func unwrapsBareFence() {
        let wrapped = "```\n### Notes\nBody.\n```"
        #expect(SummarizationPipeline.sanitizedMarkdown(wrapped) == "### Notes\nBody.")
    }

    @Test("an outer ```markdown fence is unwrapped")
    func unwrapsLanguageFence() {
        let wrapped = "```markdown\n### Notes\nBody.\n```"
        #expect(SummarizationPipeline.sanitizedMarkdown(wrapped) == "### Notes\nBody.")
    }

    @Test("trailing newline junk around the fence still unwraps")
    func unwrapsDespiteTrailingJunk() {
        let wrapped = "\n```markdown\n### Notes\nBody.\n```\n\n\n"
        #expect(SummarizationPipeline.sanitizedMarkdown(wrapped) == "### Notes\nBody.")
    }

    @Test("a document that merely starts with a code block is not damaged")
    func openFenceWithoutClosingStays() {
        // No closing fence line at the end → not a wrapper, leave it alone.
        let document = "```swift\nlet x = 1\n```\nAnd prose after."
        #expect(SummarizationPipeline.sanitizedMarkdown(document) == document)
    }

    @Test("whitespace-only input sanitizes to empty")
    func whitespaceOnly() {
        #expect(SummarizationPipeline.sanitizedMarkdown("  \n\t\n") == "")
    }
}

// MARK: - Plain transcript rendering (markdown prompt)

/// The markdown prompt shows the model a human-shaped transcript: same derived
/// utterances as `transcriptText` (ADR-021 merging), but no channel tag and no
/// segment IDs — the markdown route has no evidence protocol to feed.
@Suite("plainTranscriptText")
struct PlainTranscriptTextTests {

    @Test("renders derived utterances as [start-end] Speaker: text")
    func lineFormat() {
        let mine = TranscriptSegment(
            channel: .microphone, speaker: .me, text: "Morning, all.", start: 61, end: 63)
        let theirs = TranscriptSegment(
            channel: .system, speaker: .teammates, text: "Morning!", start: 64, end: 65)

        let text = SummarizationPipeline.plainTranscriptText(from: [mine, theirs])
        let lines = text.components(separatedBy: "\n")

        #expect(lines == [
            "[1:01-1:03] You: Morning, all.",
            "[1:04-1:05] Team: Morning!",
        ])
        #expect(!text.contains("[id="))
        #expect(!text.contains("[microphone]"))
        #expect(!text.contains("[system]"))
    }
}

// MARK: - Caption source (markdown-stripped head)

/// The library-row caption is written by a tiny generation that reads the head
/// of the finished summary. A markdown document's head is markup-dense
/// ("### Action Items", "- [ ]", "**bold**") — fed raw, the caption model
/// parrots the markup. `captionSource` strips the syntax so the model reads
/// prose, and caps the head so a long document never floods the prompt.
@Suite("captionSource")
struct CaptionSourceTests {

    @Test("heading, checkbox, bullet, and emphasis markup is stripped")
    func stripsMarkup() {
        let markdown = """
        ### Action Items
        - [ ] Diego to ship the **hotfix**
        - [x] Juan to test the `Echo` build

        ### Release Review
        - The team agreed the *build* is ready.
        """

        let source = SummarizationPipeline.captionSource(from: markdown)

        #expect(source.contains("Action Items"))
        #expect(source.contains("Diego to ship the hotfix"))
        #expect(source.contains("Juan to test the Echo build"))
        #expect(source.contains("The team agreed the build is ready."))
        #expect(!source.contains("#"))
        #expect(!source.contains("["))
        #expect(!source.contains("*"))
        #expect(!source.contains("`"))
    }

    @Test("table rows and horizontal rules are dropped")
    func dropsTablesAndRules() {
        let markdown = """
        ### Options
        | Option | Cost |
        | --- | --- |
        | A | low |

        ---

        Prose survives.
        """

        let source = SummarizationPipeline.captionSource(from: markdown)

        #expect(source.contains("Options"))
        #expect(source.contains("Prose survives."))
        #expect(!source.contains("|"))
        #expect(!source.contains("---"))
    }

    @Test("a plain paragraph passes through unchanged")
    func plainParagraphPassesThrough() {
        let prose = "A quick sync about shipping the release on Friday."
        #expect(SummarizationPipeline.captionSource(from: prose) == prose)
    }

    @Test("the stripped head is capped, and the cap applies after stripping")
    func capsAfterStripping() {
        // Every line spends most of its characters on markup; stripping first
        // means the cap budgets prose, not asterisks.
        let line = "- [ ] **Someone** to do the `thing` again\n"
        let markdown = String(repeating: line, count: 200)

        let source = SummarizationPipeline.captionSource(from: markdown)

        #expect(source.count <= 1200)
        #expect(!source.contains("*"))
        #expect(source.hasPrefix("Someone to do the thing again"))
    }
}

@Suite("SummarizationPipeline streaming")
struct SummarizationPipelineStreamTests {

    /// One markdown document, split at hostile boundaries: mid-word, mid-line,
    /// and a char-by-char tail. Snapshots must fill in progressively and never
    /// shrink, and the final snapshot must carry the sanitized full document
    /// with every legacy field left empty.
    @Test("cruel chunk splits still produce a growing markdown document")
    func cruelSplits() async throws {
        let document = """
        ### Action Items
        - [ ] Update the changelog

        ### Release Review
        You and Team agreed the build is ready to ship.
        """

        var chunks: [String] = []
        let breakpoints = [3, 11, 19, 30, 44, 58]   // mid-word and mid-line on purpose
        var remaining = document
        var consumed = 0
        for breakpoint in breakpoints {
            let take = breakpoint - consumed
            guard take > 0, take < remaining.count else { continue }
            let index = remaining.index(remaining.startIndex, offsetBy: take)
            chunks.append(String(remaining[..<index]))
            remaining = String(remaining[index...])
            consumed = breakpoint
        }
        chunks.append(contentsOf: remaining.map(String.init))

        let engine = ScriptedEngine(scripts: [chunks])
        let pipeline = SummarizationPipeline()

        var snapshots: [MeetingSummary] = []
        for try await snapshot in await pipeline.generate(from: [segment("hello")], using: engine) {
            snapshots.append(snapshot)
        }

        let final = try #require(snapshots.last)
        #expect(final.markdown == document)
        #expect(final.shortSummary.isEmpty)
        #expect(final.detailedSummary.isEmpty)
        #expect(final.decisions.isEmpty)
        #expect(final.actionItems.isEmpty)
        #expect(final.openQuestions.isEmpty)
        #expect(final.risks.isEmpty)
        #expect(engine.calls == 1)

        // Progressive: many snapshots, and the document only ever grows.
        #expect(snapshots.count > 3)
        var previousLength = 0
        for snapshot in snapshots {
            #expect(snapshot.markdown.count >= previousLength)
            previousLength = snapshot.markdown.count
        }
    }

    /// The markdown route must generate with the markdown tuning, not the
    /// NDJSON default — the whole point of the preset. Every field is compared
    /// so a partial hand-off (say, only maxTokens copied over) still fails.
    @Test("the single-pass route streams with the markdownSummary preset")
    func singlePassUsesMarkdownPreset() async throws {
        let engine = ScriptedEngine(scripts: [["### Notes\nBody."]])
        let pipeline = SummarizationPipeline()

        for try await _ in await pipeline.generate(from: [segment("hi")], using: engine) {}

        let call = try #require(engine.recordedCalls.first)
        let expected = GenerationParams.markdownSummary
        #expect(call.params.temperature == expected.temperature)
        #expect(call.params.topP == expected.topP)
        #expect(call.params.maxTokens == expected.maxTokens)
        #expect(call.params.repetitionPenalty == expected.repetitionPenalty)
        #expect(call.params.frequencyPenalty == expected.frequencyPenalty)
        #expect(call.params.presencePenalty == expected.presencePenalty)
    }

    /// A cheap regression net over the adaptive ruleset — not a full-text
    /// assert (wording may be tuned), but the load-bearing invariants must
    /// survive any rewording: the Action Items anchor, the never-invent
    /// grounding rule, the dominant-language rule, the no-code-fences output
    /// contract, and the never-empty-section rule. Asserted on the system
    /// prompt the engine actually receives, so a prompt/plumbing mismatch
    /// fails too.
    @Test("the system prompt encodes the adaptive ruleset's invariants")
    func systemPromptInvariants() async throws {
        let engine = ScriptedEngine(scripts: [["### Notes\nBody."]])
        let pipeline = SummarizationPipeline()

        for try await _ in await pipeline.generate(from: [segment("hi")], using: engine) {}

        let system = try #require(engine.recordedCalls.first).system
        #expect(system.contains("### Action Items"))
        #expect(system.localizedCaseInsensitiveContains("never invent an owner or a due date"))
        #expect(system.contains("dominant language of the transcript"))
        #expect(system.localizedCaseInsensitiveContains("no code fences"))
        #expect(system.localizedCaseInsensitiveContains("never write an empty section"))
        // S8 measured-gap rules: the commitment sweep (mid-topic commitments
        // still get a checkbox), the mention-is-not-ownership test (the
        // owner-invention trap), and the hard small-talk omission.
        #expect(system.localizedCaseInsensitiveContains("sweep the whole transcript for commitments"))
        #expect(system.localizedCaseInsensitiveContains("naming someone who did not take the task is an error"))
        #expect(system.localizedCaseInsensitiveContains("no section, no mention"))
    }

    @Test("a document streamed inside a code fence is unwrapped in the final snapshot")
    func fenceUnwrappedAtTheEnd() async throws {
        let chunks = ["```markdown\n### No", "tes\nBody.", "\n```"]
        let engine = ScriptedEngine(scripts: [chunks])
        let pipeline = SummarizationPipeline()

        var final: MeetingSummary?
        for try await snapshot in await pipeline.generate(from: [segment("hi")], using: engine) {
            final = snapshot
        }

        #expect(final?.markdown == "### Notes\nBody.")
    }

    @Test("a whitespace-only generation retries exactly once")
    func retriesOnceThenSucceeds() async throws {
        let whitespace = ["   \n", "\t\n\n"]
        let good = ["### Notes\nSecond try worked."]
        let engine = ScriptedEngine(scripts: [whitespace, good])
        let pipeline = SummarizationPipeline()

        var final: MeetingSummary?
        for try await snapshot in await pipeline.generate(from: [segment("hi")], using: engine) {
            final = snapshot
        }

        #expect(engine.calls == 2)
        #expect(final?.markdown == "### Notes\nSecond try worked.")
    }

    @Test("two whitespace-only generations end in emptyModelResponse")
    func emptyAfterRetry() async {
        let engine = ScriptedEngine(scripts: [["  \n"], ["\t \n"]])
        let pipeline = SummarizationPipeline()

        var thrown: Error?
        do {
            for try await _ in await pipeline.generate(from: [segment("hi")], using: engine) {}
        } catch {
            thrown = error
        }

        #expect(engine.calls == 2)
        guard case .emptyModelResponse? = thrown as? SummarizationError else {
            Issue.record("Expected emptyModelResponse, got \(String(describing: thrown))")
            return
        }
    }

    /// The library row's caption is generated from the finished summary, so a
    /// markdown-only summary (no legacy prose fields) must still feed it.
    @Test("a markdown-only summary still produces a one-line caption")
    func captionFromMarkdownOnlySummary() async throws {
        let engine = ScriptedEngine(scripts: [["A quick sync about shipping the release."]])
        let pipeline = SummarizationPipeline()
        let summary = MeetingSummary(
            markdown: "### Release Plan\nYou and Team agreed to ship Friday.",
            shortSummary: "", detailedSummary: "",
            decisions: [], actionItems: [], openQuestions: [], risks: [])

        let caption = await pipeline.oneLineDescription(for: summary, using: engine)

        #expect(engine.calls == 1)
        #expect(caption == "A quick sync about shipping the release.")
    }

    /// The caption preference chain stays shortSummary → markdown →
    /// detailedSummary, but the markdown leg must feed the STRIPPED head —
    /// the caption model reads prose, not markup.
    @Test("a markdown-only summary feeds the stripped head to the caption prompt")
    func captionPromptGetsStrippedMarkdown() async throws {
        let engine = ScriptedEngine(scripts: [["A sync about shipping the release."]])
        let pipeline = SummarizationPipeline()
        let summary = MeetingSummary(
            markdown: "### Release Plan\n- [ ] Diego to ship **v1** on `Friday`",
            shortSummary: "", detailedSummary: "",
            decisions: [], actionItems: [], openQuestions: [], risks: [])

        _ = await pipeline.oneLineDescription(for: summary, using: engine)

        let user = try #require(engine.recordedCalls.first).user
        #expect(user.contains("Release Plan"))
        #expect(user.contains("Diego to ship v1 on Friday"))
        #expect(!user.contains("###"))
        #expect(!user.contains("- [ ]"))
        #expect(!user.contains("**"))
        #expect(!user.contains("`"))
    }

    @Test("a short summary still outranks the markdown document as caption source")
    func captionPrefersShortSummary() async throws {
        let engine = ScriptedEngine(scripts: [["A caption."]])
        let pipeline = SummarizationPipeline()
        let summary = MeetingSummary(
            markdown: "### Markdown Notes\nShould not be used.",
            shortSummary: "The short prose summary.", detailedSummary: "",
            decisions: [], actionItems: [], openQuestions: [], risks: [])

        _ = await pipeline.oneLineDescription(for: summary, using: engine)

        let user = try #require(engine.recordedCalls.first).user
        #expect(user.contains("The short prose summary."))
        #expect(!user.contains("Markdown Notes"))
    }

    @Test("an entirely empty summary yields no caption and never calls the engine")
    func captionSkipsEmptySummary() async {
        let engine = ScriptedEngine(scripts: [["should never be used"]])
        let pipeline = SummarizationPipeline()
        let summary = MeetingSummary(
            shortSummary: "", detailedSummary: "",
            decisions: [], actionItems: [], openQuestions: [], risks: [])

        let caption = await pipeline.oneLineDescription(for: summary, using: engine)

        #expect(engine.calls == 0)
        #expect(caption == nil)
    }

    @Test("empty transcript throws without touching the engine")
    func emptyTranscript() async {
        let engine = ScriptedEngine(scripts: [])
        let pipeline = SummarizationPipeline()

        var thrown: Error?
        do {
            for try await _ in await pipeline.generate(from: [], using: engine) {}
        } catch {
            thrown = error
        }

        #expect(engine.calls == 0)
        guard case .emptyTranscript? = thrown as? SummarizationError else {
            Issue.record("Expected emptyTranscript, got \(String(describing: thrown))")
            return
        }
    }

    @Test("engine failure surfaces as modelUnavailable")
    func engineFailure() async {
        struct Boom: Error {}
        struct FailingEngine: TextGenerating {
            func stream(system: String, user: String, params: GenerationParams)
                -> AsyncThrowingStream<String, Error>
            {
                AsyncThrowingStream { $0.finish(throwing: Boom()) }
            }
        }
        let pipeline = SummarizationPipeline()

        var thrown: Error?
        do {
            for try await _ in await pipeline.generate(from: [segment("hi")], using: FailingEngine()) {}
        } catch {
            thrown = error
        }

        guard case .modelUnavailable? = thrown as? SummarizationError else {
            Issue.record("Expected modelUnavailable, got \(String(describing: thrown))")
            return
        }
    }
}
