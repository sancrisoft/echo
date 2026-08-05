//
//  TranscriptUtteranceTests.swift
//  EchoTests
//
//  SP-007 S7 (ADR-021): utterance merging + backchannel filtering as pure
//  derivations over the persisted segments. Tables over
//  `TranscriptUtterance.derive`/`isStandaloneBackchannel`, plus the summary
//  pipeline's rendered line format (first-constituent IDs, `(overlap)` only
//  when every constituent is overlap). The backchannel rows are the
//  2026-08-04 real meeting's mic channel.
//

import Foundation
import Testing
@testable import Echo

/// Segment factory: the channel follows the speaker (mic = user, system =
/// teammates), matching the product attribution rule.
private func seg(
    _ text: String,
    speaker: Speaker = .teammates,
    start: TimeInterval,
    end: TimeInterval
) -> TranscriptSegment {
    TranscriptSegment(
        channel: speaker == .me ? .microphone : .system,
        speaker: speaker,
        text: text,
        start: start,
        end: end
    )
}

@Suite("TranscriptUtterance (SP-007 S7, ADR-021)")
struct TranscriptUtteranceTests {

    // MARK: - Backchannel classifier (table-driven, open question 1)

    @Suite("backchannel classifier")
    struct BackchannelClassifierTests {

        @Test("real-meeting standalone rows classify as backchannel", arguments: [
            // The 2026-08-04 meeting's mic channel, verbatim.
            "Mm-hmm.", "Uh-huh.", "Okay.", "Ok.", "Ajá.", "Ah, ok.", "Ya.",
            "Claro", "Sí.", "Bien.", "Yeah.", "Mm.", "Hmm.", "Good.",
            "Thank you.", "Gracias.",
            // Token combinations within the length bound.
            "Yeah, okay.", "Sí, claro.",
        ])
        func standaloneRows(text: String) {
            #expect(TranscriptUtterance.isStandaloneBackchannel(text))
        }

        @Test("real content never classifies as backchannel", arguments: [
            "Okay, let's do the deploy tomorrow.",
            "Sí, pero necesitamos revisar el presupuesto.",
            "Claro que puedo revisarlo mañana.",
            "Thank you for sending the report.",
            "Good point about the migration.",
            "No.",  // a bare refusal is an answer, not backchannel
            "",     // nothing there is not backchannel — it is nothing
        ])
        func contentRows(text: String) {
            #expect(!TranscriptUtterance.isStandaloneBackchannel(text))
        }
    }

    // MARK: - Merge

    @Suite("utterance merge")
    struct MergeTests {

        @Test("consecutive same-speaker segments merge into one utterance")
        func sameSpeakerRunMerges() throws {
            let a = seg("We reviewed the metrics", start: 0, end: 4)
            let b = seg("and latency looks fine.", start: 5, end: 9)
            let c = seg("Next step is the rollout.", start: 10, end: 14)
            let utterances = TranscriptUtterance.derive(from: [a, b, c])
            #expect(utterances.count == 1)
            let utterance = try #require(utterances.first)
            #expect(utterance.text
                == "We reviewed the metrics and latency looks fine. Next step is the rollout.")
            #expect(utterance.start == 0)
            #expect(utterance.end == 14)
            #expect(utterance.segmentIDs == [a.id, b.id, c.id])
            #expect(utterance.id == a.id)
            #expect(utterance.speaker == .teammates)
            #expect(utterance.channel == .system)
        }

        @Test("a speaker change breaks the run")
        func speakerChangeBreaks() {
            let a = seg("How does the timeline look?", speaker: .teammates, start: 0, end: 3)
            let b = seg("I can finish the API by Friday.", speaker: .me, start: 4, end: 8)
            let utterances = TranscriptUtterance.derive(from: [a, b])
            #expect(utterances.count == 2)
            #expect(utterances.map(\.speaker) == [.teammates, .me])
            #expect(utterances.map(\.segmentIDs) == [[a.id], [b.id]])
        }

        @Test("a gap past the merge cap breaks the run even for the same speaker")
        func gapCapBreaks() {
            let a = seg("First topic wraps here.", start: 0, end: 5)
            let b = seg(
                "New thought after a long silence.",
                start: 5 + TranscriptUtterance.maxMergeGap + 0.1,
                end: 40
            )
            #expect(TranscriptUtterance.derive(from: [a, b]).count == 2)
        }

        @Test("a gap at exactly the merge cap still merges")
        func gapAtCapMerges() {
            let a = seg("First half", start: 0, end: 5)
            let b = seg("second half.", start: 5 + TranscriptUtterance.maxMergeGap, end: 20)
            #expect(TranscriptUtterance.derive(from: [a, b]).count == 1)
        }

        @Test("a standalone backchannel neither appears nor breaks the other speaker's merge")
        func backchannelDoesNotBreakRun() throws {
            let a = seg("The budget review moved to Thursday", speaker: .teammates, start: 0, end: 4)
            let ack = seg("Mm-hmm.", speaker: .me, start: 4.2, end: 4.6)
            let b = seg("so please update the invite.", speaker: .teammates, start: 5, end: 8)
            let utterances = TranscriptUtterance.derive(from: [a, ack, b])
            #expect(utterances.count == 1)
            let utterance = try #require(utterances.first)
            #expect(utterance.segmentIDs == [a.id, b.id])
            #expect(!utterance.segmentIDs.contains(ack.id))
            #expect(!utterance.text.contains("Mm-hmm"))
        }

        @Test("a bare Okay filters while a real sentence starting with Okay survives")
        func okayBoundary() {
            let bare = seg("Okay.", speaker: .me, start: 0, end: 1)
            let real = seg("Okay, let's do the deploy tomorrow.", speaker: .me, start: 2, end: 5)
            let utterances = TranscriptUtterance.derive(from: [bare, real])
            #expect(utterances.map(\.segmentIDs) == [[real.id]])
        }

        @Test("Spanish backchannel filters; a real Spanish sentence stays")
        func spanishRows() {
            let ack1 = seg("Ajá.", speaker: .me, start: 0, end: 0.5)
            let ack2 = seg("Claro", speaker: .me, start: 1, end: 1.4)
            let real = seg(
                "Necesitamos revisar el presupuesto antes del viernes.",
                speaker: .me, start: 2, end: 6
            )
            let ack3 = seg("Gracias.", speaker: .me, start: 7, end: 7.5)
            let utterances = TranscriptUtterance.derive(from: [ack1, ack2, real, ack3])
            #expect(utterances.map(\.segmentIDs) == [[real.id]])
        }

        @Test("inputs are never mutated and unsorted input derives in timeline order")
        func pureOverInput() throws {
            let late = seg("later text", start: 20, end: 24)
            let early = seg("earlier text", start: 0, end: 4)
            let input = [late, early]
            let snapshot = input
            let utterances = TranscriptUtterance.derive(from: input)
            #expect(input == snapshot)
            // The 16 s gap exceeds the cap, so they stay separate — but ordered.
            #expect(utterances.map(\.segmentIDs) == [[early.id], [late.id]])
        }

        @Test("empty and backchannel-only inputs derive to empty")
        func emptyInputs() {
            #expect(TranscriptUtterance.derive(from: []).isEmpty)
            let acks = [
                seg("Mm-hmm.", speaker: .me, start: 0, end: 1),
                seg("Okay.", speaker: .me, start: 2, end: 3),
            ]
            #expect(TranscriptUtterance.derive(from: acks).isEmpty)
        }

        @Test("derivation is deterministic and stable for equal starts")
        func determinism() {
            let a = seg("same start one", start: 5, end: 8)
            let b = seg("same start two", start: 5, end: 9)
            let tail = seg("tail", start: 10, end: 12)
            let input = [a, b, tail]
            let first = TranscriptUtterance.derive(from: input)
            let second = TranscriptUtterance.derive(from: input)
            #expect(first == second)
            #expect(first.map(\.segmentIDs) == [[a.id, b.id, tail.id]])
        }
    }

    // MARK: - Summary transcript rendering (the second consumer)

    @Suite("summary transcript rendering")
    struct SummaryRenderingTests {

        @Test("transcript lines carry the first constituent's ID and the merged text")
        func transcriptLineFormat() throws {
            let a = seg("We agreed on the rollout", speaker: .teammates, start: 60, end: 64)
            let ack = seg("Okay.", speaker: .me, start: 64.2, end: 64.6)
            let b = seg("starting Monday.", speaker: .teammates, start: 65, end: 68)
            let text = SummarizationPipeline.transcriptText(from: [a, ack, b])
            let lines = text.components(separatedBy: "\n")
            #expect(lines.count == 1)
            let line = try #require(lines.first)
            #expect(line == "[1:00-1:08][Team][system][id=\(a.id.uuidString)]: "
                + "We agreed on the rollout starting Monday.")
            #expect(!line.contains(b.id.uuidString))
        }

        @Test("(overlap) marks only utterances whose every constituent is overlap")
        func overlapMarking() throws {
            let o1 = seg("Overlap head first", speaker: .teammates, start: 0, end: 3)
            let o2 = seg("overlap head second.", speaker: .teammates, start: 4, end: 7)
            let n1 = seg("Fresh content continues the same run.", speaker: .teammates, start: 8, end: 12)
            let mine = seg("And here is my new answer.", speaker: .me, start: 13, end: 16)

            // Every constituent of the first utterance (o1+o2) is overlap → marked.
            let fullOverlap = TranscriptChunk(
                index: 1,
                segments: [o1, o2, mine],
                overlapSegmentIDs: [o1.id, o2.id],
                tokenEstimate: 0
            )
            let fullLines = SummarizationPipeline
                .chunkTranscriptText(for: fullOverlap)
                .components(separatedBy: "\n")
            #expect(fullLines.count == 2)
            #expect(fullLines[0].hasPrefix("(overlap) "))
            #expect(!fullLines[1].hasPrefix("(overlap) "))

            // A mixed utterance (o2 overlap + n1 new merge together) is new content.
            let mixed = TranscriptChunk(
                index: 2,
                segments: [o2, n1, mine],
                overlapSegmentIDs: [o2.id],
                tokenEstimate: 0
            )
            let mixedLines = SummarizationPipeline
                .chunkTranscriptText(for: mixed)
                .components(separatedBy: "\n")
            #expect(mixedLines.count == 2)
            #expect(!mixedLines[0].hasPrefix("(overlap) "))
            #expect(mixedLines[0].contains("[id=\(o2.id.uuidString)]"))
        }
    }
}
