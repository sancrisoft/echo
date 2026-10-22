//
//  SummarizerStreamTests.swift
//  SummarizationTests
//
//  The single-pass route's full streaming path (the `TextGenerating` seam →
//  markdown accumulation → sanitation → drafts → one final document) driven by
//  a scripted fake engine, no real model. Deltas are split at cruel points —
//  mid-word, mid-line — because that is exactly how token streaming arrives.
//  The long route's NDJSON map-reduce streaming lives in
//  SummaryMapReduceTests; the pure text and language transforms it shares are
//  asserted here, where they are read.
//

import EchoCore
import Foundation
import Synchronization
import Testing

@testable import Summarization

/// Scripted `TextGenerating`: each call to `stream` pops the next script (an
/// array of raw deltas) and replays it, recording exactly what the summarizer
/// asked for (system, user, params) so tests can assert on the real prompts and
/// sampling in flight. `Mutex`-guarded, so the actor may call it from any
/// isolation.
private final class ScriptedEngine: TextGenerating {

    struct RecordedCall {
        let system: String
        let user: String
        let params: GenerationParams
    }

    private struct State {
        var scripts: [[String]]
        var recorded: [RecordedCall] = []
    }

    private let state: Mutex<State>

    init(scripts: [[String]]) {
        state = Mutex(State(scripts: scripts))
    }

    func stream(system: String, user: String, params: GenerationParams) -> AsyncThrowingStream<String, Error> {
        let deltas = state.withLock { state -> [String] in
            state.recorded.append(RecordedCall(system: system, user: user, params: params))
            return state.scripts.isEmpty ? [] : state.scripts.removeFirst()
        }
        return AsyncThrowingStream { continuation in
            for delta in deltas { continuation.yield(delta) }
            continuation.finish()
        }
    }

    var calls: Int { state.withLock { $0.recorded.count } }

    var recordedCalls: [RecordedCall] { state.withLock { $0.recorded } }
}

private func segment(_ text: String, id: UUID = UUID(), at start: TimeInterval = 0) -> TranscriptSegment {
    TranscriptSegment(id: id, channel: .microphone, speaker: .me, text: text, start: start, end: start + 4)
}

private func makeSummarizer() -> Summarizer {
    Summarizer(modelName: "Test Model")
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

    /// The caption is one short sentence: the ceiling drops to 64 tokens and
    /// the temperature to 0.2, and everything else stays at the NDJSON defaults
    /// on purpose — those are the values it was measured with.
    @Test("caption drops the token ceiling and keeps the rest at the defaults")
    func captionValues() {
        let params = GenerationParams.caption
        let defaults = GenerationParams()
        #expect(params.temperature == 0.2)
        #expect(params.maxTokens == 64)
        #expect(params.topP == defaults.topP)
        #expect(params.repetitionPenalty == defaults.repetitionPenalty)
        #expect(params.frequencyPenalty == defaults.frequencyPenalty)
        #expect(params.presencePenalty == defaults.presencePenalty)
    }
}

// MARK: - Markdown sanitizer (table)

/// A small model loves to wrap its whole answer in a code fence despite being
/// told not to. The sanitizer's whole job is trim + unwrap that one outer
/// fence; anything subtler is the renderer's problem.
@Suite("sanitizedMarkdown")
struct SanitizedMarkdownTests {

    @Test(
        "clean documents pass through untouched",
        arguments: [
            "### Action Items\n- [ ] Ship it",
            "Plain paragraph.",
        ]
    )
    func passthrough(document: String) {
        #expect(SummaryText.sanitizedMarkdown(document) == document)
    }

    @Test("leading and trailing whitespace is trimmed")
    func trimsWhitespace() {
        #expect(SummaryText.sanitizedMarkdown("\n\n  ### Notes\nBody.  \n\n") == "### Notes\nBody.")
    }

    @Test("an outer bare fence is unwrapped")
    func unwrapsBareFence() {
        let wrapped = "```\n### Notes\nBody.\n```"
        #expect(SummaryText.sanitizedMarkdown(wrapped) == "### Notes\nBody.")
    }

    @Test("an outer ```markdown fence is unwrapped")
    func unwrapsLanguageFence() {
        let wrapped = "```markdown\n### Notes\nBody.\n```"
        #expect(SummaryText.sanitizedMarkdown(wrapped) == "### Notes\nBody.")
    }

    @Test("trailing newline junk around the fence still unwraps")
    func unwrapsDespiteTrailingJunk() {
        let wrapped = "\n```markdown\n### Notes\nBody.\n```\n\n\n"
        #expect(SummaryText.sanitizedMarkdown(wrapped) == "### Notes\nBody.")
    }

    @Test("a document that merely starts with a code block is not damaged")
    func openFenceWithoutClosingStays() {
        // No closing fence line at the end → not a wrapper, leave it alone.
        let document = "```swift\nlet x = 1\n```\nAnd prose after."
        #expect(SummaryText.sanitizedMarkdown(document) == document)
    }

    @Test("whitespace-only input sanitizes to empty")
    func whitespaceOnly() {
        #expect(SummaryText.sanitizedMarkdown("  \n\t\n") == "")
    }
}

// MARK: - Plain transcript rendering (markdown prompt)

/// The markdown prompt shows the model a human-shaped transcript: the same
/// derived utterances the map route renders, but no channel tag and no segment
/// ids — the markdown route has no evidence protocol to feed.
@Suite("plainTranscriptText")
struct PlainTranscriptTextTests {

    @Test("renders derived utterances as [start-end] Speaker: text")
    func lineFormat() {
        let mine = TranscriptSegment(
            channel: .microphone, speaker: .me, text: "Morning, all.", start: 61, end: 63)
        let theirs = TranscriptSegment(
            channel: .system, speaker: .teammates, text: "Morning!", start: 64, end: 65)

        let text = SummaryPrompts.plainTranscriptText(from: [mine, theirs])
        let lines = text.components(separatedBy: "\n")

        #expect(
            lines == [
                "[1:01-1:03] You: Morning, all.",
                "[1:04-1:05] Team: Morning!",
            ]
        )
        #expect(!text.contains("[id="))
        #expect(!text.contains("[microphone]"))
        #expect(!text.contains("[system]"))
    }
}

// MARK: - Dominant language

/// Language detection steers the prompts' language injection: an English name
/// for a clearly dominant language, nil when there is no confident answer. A
/// wrong label would steer the WHOLE summary's language, so for garbled or
/// too-short text nil (generic prompts) is the only safe answer.
@Suite("detectedLanguage")
struct DominantLanguageTests {

    @Test("the sample's measured bounds and confidence floor")
    func samplingConstants() {
        #expect(SummaryLanguage.sampleBudget == 3_000)
        #expect(SummaryLanguage.sampleSegments == 60)
        #expect(SummaryLanguage.confidenceFloor == 0.6)
    }

    @Test("clearly Spanish segments detect as Spanish")
    func spanishDetected() {
        let segments = [
            segment("Bueno, empecemos con la revisión del panel de métricas de esta semana."),
            segment("Claro, las pruebas de regresión terminaron ayer y todo salió bien."),
            segment("Entonces estamos de acuerdo: lanzamos la beta el viernes que viene."),
        ]
        #expect(Summarizer.detectedLanguage(of: segments) == "Spanish")
    }

    @Test("clearly English segments detect as English")
    func englishDetected() {
        let segments = [
            segment("Okay, let's review the dashboard launch and the regression pass."),
            segment("QA finished everything yesterday and the results all came back green."),
            segment("Then we are agreed: we ship the beta this coming Friday morning."),
        ]
        #expect(Summarizer.detectedLanguage(of: segments) == "English")
    }

    @Test("empty, garbled, or too-short text yields nil, never a coin-flip label")
    func unconfidentYieldsNil() {
        #expect(Summarizer.detectedLanguage(of: []) == nil)
        #expect(Summarizer.detectedLanguage(of: [segment("")]) == nil)
        #expect(Summarizer.detectedLanguage(of: [segment("zzxq vrrk 12 glmp 44")]) == nil)
    }

    /// The sample is spread across the meeting rather than taken from its head,
    /// so a meeting that opens with an English greeting and then runs in Spanish
    /// is still Spanish.
    @Test("an English greeting does not mislabel a Spanish meeting")
    func englishGreetingDoesNotMislabelSpanish() {
        var segments = [segment("Hi everyone, good morning, thanks for joining the call today.")]
        segments.append(
            contentsOf: [
                segment("Bueno, empecemos con la revisión del panel de métricas de esta semana."),
                segment("Las pruebas de regresión terminaron ayer y todo salió bien, sin errores."),
                segment("Tenemos que decidir si movemos el despliegue al jueves por la tarde."),
                segment("El equipo de soporte reportó tres incidencias nuevas en la versión anterior."),
                segment("Entonces estamos de acuerdo: lanzamos la beta el viernes que viene."),
            ])

        #expect(Summarizer.detectedLanguage(of: segments) == "Spanish")
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

        let source = SummaryText.captionSource(from: markdown)

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

        let source = SummaryText.captionSource(from: markdown)

        #expect(source.contains("Options"))
        #expect(source.contains("Prose survives."))
        #expect(!source.contains("|"))
        #expect(!source.contains("---"))
    }

    @Test("a plain paragraph passes through unchanged")
    func plainParagraphPassesThrough() {
        let prose = "A quick sync about shipping the release on Friday."
        #expect(SummaryText.captionSource(from: prose) == prose)
    }

    @Test("the stripped head is capped, and the cap applies after stripping")
    func capsAfterStripping() {
        // Every line spends most of its characters on markup; stripping first
        // means the cap budgets prose, not asterisks.
        let line = "- [ ] **Someone** to do the `thing` again\n"
        let markdown = String(repeating: line, count: 200)

        let source = SummaryText.captionSource(from: markdown)

        #expect(SummaryText.captionSourceBudget == 1_200)
        #expect(source.count <= SummaryText.captionSourceBudget)
        #expect(!source.contains("*"))
        #expect(source.hasPrefix("Someone to do the thing again"))
    }
}

// MARK: - Streaming

@Suite("Summarizer streaming")
struct SummarizerStreamTests {

    /// One markdown document, split at hostile boundaries: mid-word, mid-line,
    /// and a char-by-char tail. Drafts must fill in progressively and never
    /// shrink, and the final document must carry the sanitized whole.
    @Test("cruel delta splits still produce a growing markdown document")
    func cruelSplits() async throws {
        let document = """
            ### Action Items
            - [ ] Update the changelog

            ### Release Review
            You and Team agreed the build is ready to ship.
            """

        var deltas: [String] = []
        // Mid-word and mid-line on purpose.
        let breakpoints = [3, 11, 19, 30, 44, 58]
        var remaining = document
        var consumed = 0
        for breakpoint in breakpoints {
            let take = breakpoint - consumed
            guard take > 0, take < remaining.count else { continue }
            let index = remaining.index(remaining.startIndex, offsetBy: take)
            deltas.append(String(remaining[..<index]))
            remaining = String(remaining[index...])
            consumed = breakpoint
        }
        deltas.append(contentsOf: remaining.map(String.init))

        let engine = ScriptedEngine(scripts: [deltas])
        let summarizer = makeSummarizer()

        var documents: [SummaryDocument] = []
        for try await draft in await summarizer.generate(from: [segment("hello")], using: engine) {
            documents.append(draft)
        }

        let final = try #require(documents.last)
        #expect(final.markdown == document)
        #expect(final.isFinal)
        #expect(final.modelName == "Test Model")
        // The single-pass route extracts no facts.
        #expect(final.facts.decisions.isEmpty)
        #expect(final.facts.actionItems.isEmpty)
        #expect(final.facts.openQuestions.isEmpty)
        #expect(final.facts.risks.isEmpty)
        #expect(engine.calls == 1)

        // Exactly one final document, and it is the last element.
        #expect(documents.filter(\.isFinal).count == 1)
        #expect(documents.dropLast().allSatisfy { !$0.isFinal })

        // Progressive: many elements, and the document only ever grows.
        #expect(documents.count > 3)
        var previousLength = 0
        for draft in documents {
            #expect(draft.markdown.count >= previousLength)
            previousLength = draft.markdown.count
        }
    }

    /// The markdown route must generate with the markdown tuning, not the
    /// NDJSON default — the whole point of the preset. Every field is compared
    /// so a partial hand-off (say, only maxTokens copied over) still fails.
    @Test("the single-pass route streams with the markdownSummary preset")
    func singlePassUsesMarkdownPreset() async throws {
        let engine = ScriptedEngine(scripts: [["### Notes\nBody."]])
        let summarizer = makeSummarizer()

        for try await _ in await summarizer.generate(from: [segment("hi")], using: engine) {}

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
        let summarizer = makeSummarizer()

        for try await _ in await summarizer.generate(from: [segment("hi")], using: engine) {}

        let system = try #require(engine.recordedCalls.first).system
        #expect(system.contains("### Action Items"))
        #expect(system.localizedCaseInsensitiveContains("never invent an owner or a due date"))
        #expect(system.contains("dominant language of the transcript"))
        #expect(system.localizedCaseInsensitiveContains("no code fences"))
        #expect(system.localizedCaseInsensitiveContains("never write an empty section"))
        // The measured-gap rules: the commitment sweep (mid-topic commitments
        // still get a checkbox), the mention-is-not-ownership test (the
        // owner-invention trap), and the hard small-talk omission.
        #expect(system.localizedCaseInsensitiveContains("sweep the whole transcript for commitments"))
        #expect(system.localizedCaseInsensitiveContains("naming someone who did not take the task is an error"))
        #expect(system.localizedCaseInsensitiveContains("no section, no mention"))
    }

    /// Recency reinforcement: the small-talk omission rule in the far-away
    /// system prompt alone measured 6/6 leaks, so the USER prompt must CLOSE
    /// with the work-notes reminder — after the transcript, at the end of the
    /// context, where a small model weighs it most. The fixture text is
    /// deliberately language-undetectable: with no confident language, the
    /// prompts keep their generic wording and the ownership recap stays the
    /// closer.
    @Test("the user prompt closes with the work-notes reminder after the transcript")
    func userPromptClosesWithWorkNotesReminder() async throws {
        let engine = ScriptedEngine(scripts: [["### Notes\nBody."]])
        let summarizer = makeSummarizer()

        let segments = [segment("zzxq vrrk 12 glmp 44")]
        for try await _ in await summarizer.generate(from: segments, using: engine) {}

        let user = try #require(engine.recordedCalls.first).user
        let transcript = try #require(user.range(of: "Transcript:"))
        let reminder = try #require(user.range(of: "Reminder: these are WORK notes."))
        #expect(transcript.upperBound <= reminder.lowerBound)
        #expect(user.localizedCaseInsensitiveContains("leave out all social and personal conversation"))
        #expect(user.localizedCaseInsensitiveContains("no section, no mention"))
        // No confident language → no explicit language sentence.
        #expect(!user.contains("Write the notes in"))
        // The reminder carries BOTH probabilistic traps: measured alone, the
        // small-talk line at the end displaced the ownership rule (owner trap
        // 4/4 → 0/2), so the owner recap must close the context with it.
        #expect(user.hasSuffix("checkbox with NO name."))
    }

    /// The field bug: a fully-Spanish transcript produced an ENGLISH summary —
    /// the scaffolding is English and the closing slot dominates. A detected
    /// language must therefore appear EXPLICITLY: as framing before the
    /// transcript and as the reminder's final sentence. Zero-sum guard:
    /// language is appended — the small-talk and ownership recaps must survive
    /// alongside it.
    @Test("a Spanish transcript injects the explicit language sentence, keeping both recaps")
    func spanishTranscriptInjectsLanguageSentence() async throws {
        let engine = ScriptedEngine(scripts: [["### Notas\nCuerpo."]])
        let summarizer = makeSummarizer()
        let segments = [
            segment("Bueno, empecemos con la revisión del panel de métricas de esta semana."),
            segment("Claro, las pruebas de regresión terminaron ayer y todo salió bien."),
            segment("Entonces estamos de acuerdo: lanzamos la beta el viernes que viene."),
        ]

        var final: SummaryDocument?
        for try await document in await summarizer.generate(from: segments, using: engine) {
            final = document
        }

        let user = try #require(engine.recordedCalls.first).user
        let sentence = try #require(user.range(of: "Write the notes in Spanish."))
        let transcript = try #require(user.range(of: "Transcript:"))
        #expect(sentence.upperBound <= transcript.lowerBound)
        #expect(user.hasSuffix("Write the notes in Spanish."))
        #expect(user.localizedCaseInsensitiveContains("no section, no mention"))
        #expect(user.localizedCaseInsensitiveContains("checkbox with NO name"))
        // The detected language is carried out on the document, so a caller
        // records what the summary was written in without re-detecting.
        #expect(final?.language == "Spanish")
    }

    @Test("a document streamed inside a code fence is unwrapped in the final document")
    func fenceUnwrappedAtTheEnd() async throws {
        let deltas = ["```markdown\n### No", "tes\nBody.", "\n```"]
        let engine = ScriptedEngine(scripts: [deltas])
        let summarizer = makeSummarizer()

        var final: SummaryDocument?
        for try await document in await summarizer.generate(from: [segment("hi")], using: engine) {
            final = document
        }

        #expect(final?.markdown == "### Notes\nBody.")
        #expect(final?.isFinal == true)
    }

    @Test("a whitespace-only generation retries exactly once")
    func retriesOnceThenSucceeds() async throws {
        let whitespace = ["   \n", "\t\n\n"]
        let good = ["### Notes\nSecond try worked."]
        let engine = ScriptedEngine(scripts: [whitespace, good])
        let summarizer = makeSummarizer()

        var final: SummaryDocument?
        for try await document in await summarizer.generate(from: [segment("hi")], using: engine) {
            final = document
        }

        #expect(engine.calls == 2)
        #expect(final?.markdown == "### Notes\nSecond try worked.")
        #expect(final?.isFinal == true)
    }

    @Test("two whitespace-only generations end in emptyModelResponse")
    func emptyAfterRetry() async {
        let engine = ScriptedEngine(scripts: [["  \n"], ["\t \n"]])
        let summarizer = makeSummarizer()

        var documents: [SummaryDocument] = []
        var thrown: Error?
        do {
            for try await document in await summarizer.generate(from: [segment("hi")], using: engine) {
                documents.append(document)
            }
        } catch {
            thrown = error
        }

        #expect(engine.calls == 2)
        #expect(thrown as? SummarizationError == .emptyModelResponse)
        // A failed generation emits no final document — there is nothing to
        // mistake for a result.
        #expect(documents.allSatisfy { !$0.isFinal })
    }

    /// The library row's caption is generated from the finished document.
    @Test("a finished document produces a one-line caption")
    func captionFromDocument() async throws {
        let engine = ScriptedEngine(scripts: [["A quick sync about shipping the release."]])
        let summarizer = makeSummarizer()
        let document = SummaryDocument(
            markdown: "### Release Plan\nYou and Team agreed to ship Friday.",
            modelName: "Test Model",
            isFinal: true
        )

        let caption = await summarizer.caption(for: document, using: engine)

        #expect(engine.calls == 1)
        #expect(caption == "A quick sync about shipping the release.")
        // One short sentence: the caption preset, not the markdown one.
        let params = try #require(engine.recordedCalls.first).params
        #expect(params.temperature == GenerationParams.caption.temperature)
        #expect(params.maxTokens == GenerationParams.caption.maxTokens)
    }

    /// The caption model reads prose, not markup, so the markdown leg must feed
    /// the STRIPPED head.
    @Test("the caption prompt gets the stripped head of the document")
    func captionPromptGetsStrippedMarkdown() async throws {
        let engine = ScriptedEngine(scripts: [["A sync about shipping the release."]])
        let summarizer = makeSummarizer()
        let document = SummaryDocument(
            markdown: "### Release Plan\n- [ ] Diego to ship **v1** on `Friday`",
            modelName: "Test Model",
            isFinal: true
        )

        _ = await summarizer.caption(for: document, using: engine)

        let user = try #require(engine.recordedCalls.first).user
        #expect(user.contains("Release Plan"))
        #expect(user.contains("Diego to ship v1 on Friday"))
        #expect(!user.contains("###"))
        #expect(!user.contains("- [ ]"))
        #expect(!user.contains("**"))
        #expect(!user.contains("`"))
    }

    @Test("an empty document yields no caption and never calls the engine")
    func captionSkipsEmptyDocument() async {
        let engine = ScriptedEngine(scripts: [["should never be used"]])
        let summarizer = makeSummarizer()
        let document = SummaryDocument(markdown: "", modelName: "Test Model", isFinal: true)

        let caption = await summarizer.caption(for: document, using: engine)

        #expect(engine.calls == 0)
        #expect(caption == nil)
    }

    @Test("empty transcript throws without touching the engine")
    func emptyTranscript() async {
        let engine = ScriptedEngine(scripts: [])
        let summarizer = makeSummarizer()

        var thrown: Error?
        do {
            for try await _ in await summarizer.generate(from: [], using: engine) {}
        } catch {
            thrown = error
        }

        #expect(engine.calls == 0)
        #expect(thrown as? SummarizationError == .emptyTranscript)
    }

    @Test("engine failure surfaces as modelUnavailable and emits no final document")
    func engineFailure() async {
        struct Boom: Error {}
        struct FailingEngine: TextGenerating {
            func stream(
                system: String, user: String, params: GenerationParams
            ) -> AsyncThrowingStream<String, Error> {
                AsyncThrowingStream { $0.finish(throwing: Boom()) }
            }
        }
        let summarizer = makeSummarizer()

        var documents: [SummaryDocument] = []
        var thrown: Error?
        do {
            for try await document in await summarizer.generate(from: [segment("hi")], using: FailingEngine()) {
                documents.append(document)
            }
        } catch {
            thrown = error
        }

        guard case .modelUnavailable = thrown as? SummarizationError else {
            Issue.record("Expected modelUnavailable, got \(String(describing: thrown))")
            return
        }
        #expect(documents.allSatisfy { !$0.isFinal })
    }
}
