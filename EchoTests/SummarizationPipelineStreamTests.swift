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
/// array of raw chunks) and replays it. Thread-safe so the pipeline can call
/// it from any isolation.
private final class ScriptedEngine: TextGenerating, @unchecked Sendable {
    private let lock = NSLock()
    private var scripts: [[String]]
    private(set) var callCount = 0

    init(scripts: [[String]]) {
        self.scripts = scripts
    }

    func stream(system: String, user: String, params: GenerationParams)
        -> AsyncThrowingStream<String, Error>
    {
        lock.lock()
        callCount += 1
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
        return callCount
    }
}

private func segment(_ text: String, id: UUID = UUID(), at start: TimeInterval = 0) -> TranscriptSegment {
    TranscriptSegment(
        id: id, channel: .microphone, speaker: .me, text: text, start: start, end: start + 4
    )
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
