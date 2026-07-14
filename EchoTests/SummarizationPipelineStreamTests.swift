//
//  SummarizationPipelineStreamTests.swift
//  EchoTests
//
//  Drives the full streaming path (TextGenerating seam → buffer/newline split
//  → validator → accumulator → snapshots) with a scripted fake engine, no real
//  model. Chunks are split at cruel points — mid-escape, mid-line — because
//  that is exactly how token streaming arrives.
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

@Suite("SummarizationPipeline streaming")
struct SummarizationPipelineStreamTests {

    /// The full protocol, split at hostile boundaries: inside the type name,
    /// inside a \" escape, in the middle of a UUID, and with one line spread
    /// over many one-character deltas.
    @Test("cruel chunk splits still produce correct progressive snapshots")
    func cruelSplits() async throws {
        // Evidence must cite a real segment ID or the item is dropped (SPEC-05
        // executable grounding), so the fixture segment carries this exact UUID.
        let segID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let ndjson =
            #"{"type":"short","text":"Ship v2 \"Friday\"."}"# + "\n"
            + #"{"type":"detailed","text":"The team reviewed QA and agreed."}"# + "\n"
            + #"{"type":"decision","title":"Ship v2","details":null,"evidence":["11111111-1111-1111-1111-111111111111"]}"# + "\n"
            + #"{"type":"action","task":"Update changelog","owner":null,"due":null,"evidence":["11111111-1111-1111-1111-111111111111"]}"# + "\n"

        // Split 1: mid key/escape/UUID. Split 2: char-by-char.
        var chunks: [String] = []
        let breakpoints = [12, 30, 38, 55, 90, 120, 170, 200]
        var remaining = ndjson
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
        for try await snapshot in await pipeline.generate(from: [segment("hello", id: segID)], using: engine) {
            snapshots.append(snapshot)
        }

        let final = try #require(snapshots.last)
        #expect(final.shortSummary == #"Ship v2 "Friday"."#)
        #expect(final.detailedSummary == "The team reviewed QA and agreed.")
        #expect(final.decisions.count == 1)
        #expect(final.decisions.first?.title == "Ship v2")
        #expect(final.decisions.first?.evidenceSegmentIDs == ["11111111-1111-1111-1111-111111111111"])
        #expect(final.actionItems.count == 1)
        #expect(final.actionItems.first?.owner == nil)

        // Progressive: the short summary must appear before the last snapshot
        // (char-by-char preview), and snapshots only ever grow.
        #expect(snapshots.count > 3)
        #expect(snapshots.first?.decisions.isEmpty == true)
        let shortAppearsEarly = snapshots.prefix(snapshots.count - 1).contains { !$0.shortSummary.isEmpty }
        #expect(shortAppearsEarly)
    }

    @Test("malformed lines are dropped, valid ones survive")
    func malformedLinesDropped() async throws {
        let segID = UUID()
        let chunks = [
            "{\"type\":\"short\",\"text\":\"Valid.\"}\n",
            "total garbage, not json\n",
            "{\"type\":\"decision\",\"title\":\"No evidence key\"}\n",
            "{\"type\":\"detailed\",\"text\":\"Also valid.\"}\n",
            "{\"type\":\"risk\",\"risk\":\"Real risk\",\"details\":null,\"evidence\":[\"\(segID.uuidString)\"]}\n",
        ]
        let engine = ScriptedEngine(scripts: [chunks])
        let pipeline = SummarizationPipeline()

        var final: MeetingSummary?
        for try await snapshot in await pipeline.generate(from: [segment("hi", id: segID)], using: engine) {
            final = snapshot
        }

        let summary = try #require(final)
        #expect(summary.shortSummary == "Valid.")
        #expect(summary.detailedSummary == "Also valid.")
        #expect(summary.decisions.isEmpty)       // malformed decision dropped
        #expect(summary.risks.count == 1)
        #expect(engine.calls == 1)
    }

    @Test("single-pass drops items whose evidence cites no real segment")
    func singlePassEvidenceGrounding() async throws {
        let realID = UUID()
        let fakeID = UUID()   // not part of the transcript
        let chunks = [
            "{\"type\":\"short\",\"text\":\"S.\"}\n",
            "{\"type\":\"detailed\",\"text\":\"D.\"}\n",
            // Grounded: cites the real segment → kept.
            "{\"type\":\"decision\",\"title\":\"Real\",\"details\":null,\"evidence\":[\"\(realID.uuidString)\"]}\n",
            // Hallucinated evidence only → dropped.
            "{\"type\":\"decision\",\"title\":\"Fake\",\"details\":null,\"evidence\":[\"\(fakeID.uuidString)\"]}\n",
            // Empty evidence → dropped.
            "{\"type\":\"risk\",\"risk\":\"Empty\",\"details\":null,\"evidence\":[]}\n",
        ]
        let engine = ScriptedEngine(scripts: [chunks])
        let pipeline = SummarizationPipeline()

        var final: MeetingSummary?
        for try await snapshot in await pipeline.generate(from: [segment("hi", id: realID)], using: engine) {
            final = snapshot
        }

        let summary = try #require(final)
        #expect(summary.decisions.count == 1)
        #expect(summary.decisions.first?.title == "Real")
        #expect(summary.decisions.first?.evidenceSegmentIDs == [realID.uuidString])
        #expect(summary.risks.isEmpty)   // empty-evidence risk dropped
    }

    @Test("a stream with no valid short/detailed retries exactly once")
    func retriesOnceThenSucceeds() async throws {
        let garbage = ["I am a chatty model and refuse to emit JSON.\n"]
        let good = ["{\"type\":\"short\",\"text\":\"Second try.\"}\n{\"type\":\"detailed\",\"text\":\"Worked.\"}\n"]
        let engine = ScriptedEngine(scripts: [garbage, good])
        let pipeline = SummarizationPipeline()

        var final: MeetingSummary?
        for try await snapshot in await pipeline.generate(from: [segment("hi")], using: engine) {
            final = snapshot
        }

        #expect(engine.calls == 2)
        #expect(final?.shortSummary == "Second try.")
        #expect(final?.detailedSummary == "Worked.")
    }

    @Test("two garbage generations end in emptyModelResponse")
    func emptyAfterRetry() async {
        let engine = ScriptedEngine(scripts: [["nope\n"], ["still nope\n"]])
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
