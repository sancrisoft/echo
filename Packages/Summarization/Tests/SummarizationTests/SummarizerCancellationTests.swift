//
//  SummarizerCancellationTests.swift
//  SummarizationTests
//
//  Cancellation on the two PUBLIC per-chunk seams.
//
//  `generate` is safe by construction: the only thing that cancels its
//  producer is the consumer terminating the stream, and a yield onto a
//  terminated continuation is discarded, so a truncated final document cannot
//  reach anyone. `mapChunk` and `reduceMarkdown` have no such shield — they are
//  documented for a caller to drive per chunk from its own task, and that
//  caller's cancellation must not come back as a plausible partial result.
//

import EchoCore
import Foundation
import Synchronization
import Testing

@testable import Summarization

/// Yields its deltas and then never finishes, so the only way out of the
/// consuming loop is cancellation.
private final class NeverFinishingEngine: TextGenerating {

    private let deltas: [String]
    private let started: Mutex<[CheckedContinuation<Void, Never>]>

    init(deltas: [String]) {
        self.deltas = deltas
        started = Mutex([])
    }

    /// Resumes once the summarizer has actually begun consuming.
    func waitUntilStreaming() async {
        await withCheckedContinuation { continuation in
            started.withLock { $0.append(continuation) }
        }
    }

    func stream(system: String, user: String, params: GenerationParams) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            for delta in deltas { continuation.yield(delta) }
            let waiters = started.withLock { waiters in
                let pending = waiters
                waiters.removeAll()
                return pending
            }
            for waiter in waiters { waiter.resume() }
            // Never finished on purpose: cancellation is the only exit.
        }
    }
}

private func segment(_ text: String) -> TranscriptSegment {
    TranscriptSegment(channel: .system, speaker: .teammates, text: text, start: 0, end: 4)
}

@Suite("Summarizer cancellation on the public seams")
struct SummarizerCancellationTests {

    @Test("a cancelled mapChunk throws instead of returning a truncated result")
    func cancelledMapChunkThrows() async throws {
        let ids = (0..<2).map { _ in UUID() }
        let segments = ids.map {
            TranscriptSegment(id: $0, channel: .system, speaker: .teammates, text: "A line of talk.", start: 0, end: 4)
        }
        let chunk = try #require(TranscriptChunker.chunks(from: segments).first)

        // One complete, well-formed fact line, then the stream stalls. Without a
        // cancellation check after the loop, this is exactly what a truncated
        // result looks like: real content, no error.
        let line = """
            {"type":"decision","title":"Ship it","details":"","evidence":["\(ids[0].uuidString)"]}
            """
        let engine = NeverFinishingEngine(deltas: [line + "\n"])
        let summarizer = Summarizer(modelName: "Test Model")

        let outcome = Mutex<String?>(nil)
        let task = Task {
            do {
                let result = try await summarizer.mapChunk(chunk, engine: engine)
                outcome.withLock { $0 = "returned \(result.decisions.count) decision(s)" }
            } catch is CancellationError {
                outcome.withLock { $0 = "cancelled" }
            } catch {
                outcome.withLock { $0 = "threw \(error)" }
            }
        }

        await engine.waitUntilStreaming()
        task.cancel()
        await task.value

        #expect(outcome.withLock { $0 } == "cancelled")
    }

    @Test("a cancelled reduceMarkdown throws instead of returning a truncated document")
    func cancelledReduceThrows() async throws {
        let facts = MergedFacts(decisions: [SummaryDecision(title: "Ship it", details: "")])
        let engine = NeverFinishingEngine(deltas: ["### Notes\n", "First half of a "])
        let summarizer = Summarizer(modelName: "Test Model")

        let outcome = Mutex<String?>(nil)
        let task = Task {
            do {
                let document = try await summarizer.reduceMarkdown(facts: facts, notes: [], engine: engine)
                outcome.withLock { $0 = "returned \(document.count) chars" }
            } catch is CancellationError {
                outcome.withLock { $0 = "cancelled" }
            } catch {
                outcome.withLock { $0 = "threw \(error)" }
            }
        }

        await engine.waitUntilStreaming()
        task.cancel()
        await task.value

        #expect(outcome.withLock { $0 } == "cancelled")
    }
}
