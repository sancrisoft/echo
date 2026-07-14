//
//  SummarizationE2ETests.swift
//  EchoTests
//
//  Acceptance-gated (ECHO_ACCEPTANCE=1): real model download (once, into
//  ~/Library/Application Support/Echo/Models), real MLX generation, grounding
//  asserts on the output. Constructed *text* segments are the sanctioned
//  fixture style for LLM tests (workflow §0.5); no audio involved.
//

import Foundation
import Testing
@testable import Echo

private let acceptanceEnabled = ProcessInfo.processInfo.environment["ECHO_ACCEPTANCE"] == "1"

// .serialized: this suite now has two model-driven tests. Swift Testing
// parallelizes tests within a process by default (even with
// -parallel-testing-enabled NO), and two generations sharing the Metal device
// contend; run them one at a time.
@Suite("Summarization E2E", .enabled(if: acceptanceEnabled), .serialized)
struct SummarizationE2ETests {

    /// A short product meeting with unmistakable decisions, one owned action,
    /// one action with NO owner (the grounding trap: the model must emit
    /// owner == null, not invent one), an open question, and a risk.
    private static func fixtureTranscript() -> [TranscriptSegment] {
        let lines: [(Speaker, String)] = [
            (.teammates, "Okay, let's review the Atlas dashboard launch."),
            (.me, "Sure. QA finished the regression pass yesterday, everything green."),
            (.teammates, "Great. Then we are agreed: we ship the Atlas beta this Friday."),
            (.me, "Agreed, Friday it is."),
            (.teammates, "Second topic: the database. Staying on SQLite is not holding up."),
            (.me, "Right. Let's decide it here: we migrate the backend to Postgres next sprint."),
            (.teammates, "Yes, decision made, Postgres next sprint."),
            (.me, "I'll prepare the release notes before Thursday."),
            (.teammates, "Thanks. The onboarding guide also needs to be updated for the new sidebar."),
            (.me, "True, that's still pending — nobody has picked that up yet."),
            (.teammates, "One thing I couldn't confirm: which regions get the beta first?"),
            (.me, "No idea yet, marketing hasn't answered."),
            (.teammates, "Also flagging a risk: the analytics vendor contract is still unsigned."),
            (.me, "Yes, if legal doesn't sign it this week the usage metrics won't be ready."),
            (.teammates, "Understood. That's everything, see you Friday."),
        ]
        return lines.enumerated().map { index, line in
            TranscriptSegment(
                channel: line.0 == .me ? .microphone : .system,
                speaker: line.0,
                text: line.1,
                start: TimeInterval(index * 6),
                end: TimeInterval(index * 6 + 5)
            )
        }
    }

    @Test("real model produces a grounded streamed summary")
    func groundedSummary() async throws {
        let manager = SummaryModelManager()
        let engine = try await manager.ensureReady { phase, fraction in
            print("[E2E] \(phase) \(Int(fraction * 100))%")
        }
        #expect(await manager.cachedModelExists())

        let transcript = Self.fixtureTranscript()
        let validIDs = Set(transcript.map { $0.id.uuidString.lowercased() })
        let pipeline = SummarizationPipeline()

        var snapshots = 0
        var final: MeetingSummary?
        for try await snapshot in await pipeline.generate(from: transcript, using: engine) {
            snapshots += 1
            final = snapshot
        }

        let summary = try #require(final)
        print("[E2E] snapshots=\(snapshots) decisions=\(summary.decisions.count) actions=\(summary.actionItems.count) questions=\(summary.openQuestions.count) risks=\(summary.risks.count)")
        print("[E2E] short=\(summary.shortSummary)")

        // Streaming actually streamed (many progressive snapshots, not one blob).
        #expect(snapshots > 1)

        // Prose present.
        #expect(!summary.shortSummary.isEmpty)
        #expect(!summary.detailedSummary.isEmpty)

        // At least one decision, and at least one decision's evidence points at
        // real segment IDs copied verbatim from the transcript.
        #expect(!summary.decisions.isEmpty)
        let decisionWithRealEvidence = summary.decisions.contains { decision in
            decision.evidenceSegmentIDs.contains { validIDs.contains($0.lowercased()) }
        }
        #expect(decisionWithRealEvidence)

        // Grounding: the onboarding-guide action has no owner in the
        // transcript, so any action item about it must carry owner == nil.
        // (If the model skipped that action entirely, the check is vacuous —
        // that's fine; what's forbidden is inventing an owner.)
        let onboardingActions = summary.actionItems.filter {
            $0.task.lowercased().contains("onboarding")
        }
        #expect(onboardingActions.allSatisfy { $0.owner == nil })

        // No hallucinated evidence anywhere: every evidence ID across all
        // sections either matches a transcript segment or is dropped by the
        // UI — but the model was told to copy verbatim, so require that at
        // least half of all cited IDs are real to catch systematic drift.
        let allEvidence = (summary.decisions.flatMap(\.evidenceSegmentIDs)
            + summary.actionItems.flatMap(\.evidenceSegmentIDs)
            + summary.openQuestions.flatMap(\.evidenceSegmentIDs)
            + summary.risks.flatMap(\.evidenceSegmentIDs))
        if !allEvidence.isEmpty {
            let real = allEvidence.filter { validIDs.contains($0.lowercased()) }
            #expect(real.count * 2 >= allEvidence.count)
        }
    }

    /// A long meeting (>20K tokens) that forces the map-reduce route (SPEC-05
    /// §5.6). Meaningful decisions/actions/questions/risk are sprinkled through
    /// a long body of filler so the notes must cite timestamps from the whole
    /// duration, not just the opening. The grounding trap (an owner-less action)
    /// still holds, and we assert the route actually was map-reduce via the
    /// per-part progress callback.
    private static func longTranscript() -> [TranscriptSegment] {
        // Filler is real conversational text carrying no facts. Each filler
        // segment is a few sentences (~90 tokens) so 300 segments clear 20K
        // tokens, and a long gap every 25 segments makes chunks close at natural
        // seams (several map chunks, not two giant ones).
        let sentences = [
            "So, moving on, I think we should keep the momentum going on this workstream.",
            "Right, and I looked at the numbers again over the weekend just to be sure of them.",
            "Yeah, the dashboards are mostly green, though there are a couple of yellow spots.",
            "Let me share my screen for a moment so everyone can follow along with the charts.",
            "Okay, that makes sense, thanks for walking us through all of those details there.",
            "I agree the trend is encouraging, but I don't think we should get complacent yet.",
            "Good point, let's keep an eye on the latency graph during the peak traffic hours.",
            "Someone asked about the mobile rollout timing earlier, we can circle back to it.",
            "Sure, I will paste the link to the shared document in the chat right after the call.",
            "Understood, that all sounds perfectly reasonable to me from the data side of things.",
            "We can revisit the staffing plan next week once the new headcount is confirmed.",
            "The customer feedback has been broadly positive, with a few small usability notes.",
        ]
        func filler(_ index: Int) -> String {
            // Six sentences, rotated by index → ~90 tokens, varied per segment.
            (0..<6).map { sentences[(index + $0 * 5) % sentences.count] }.joined(separator: " ")
        }

        // (index, speaker, text). Facts spread across the whole meeting; the
        // decision lines are unmistakable and the onboarding action is left
        // explicitly unassigned (the owner-null grounding trap).
        let signals: [(Int, Speaker, String)] = [
            (18,  .teammates, "Decision confirmed: we will ship the Atlas beta this Friday. Everyone on the call agreed to that date."),
            (70,  .me,        "Action item for me: I will prepare the release notes before Thursday. I own that task."),
            (130, .teammates, "The onboarding guide still needs to be updated for the new sidebar layout."),
            (131, .me,        "Right, nobody has picked that up yet, so that one stays unassigned for now."),
            (150, .teammates, "Decision made: we will migrate the backend database from SQLite to Postgres next sprint."),
            (205, .teammates, "Open question we could not resolve: which regions get the beta first? Marketing has not answered."),
            (255, .me,        "Risk to flag: the analytics vendor contract is still unsigned as of this week."),
            (256, .teammates, "Final decision: we cut the reporting module from scope so we can hit the launch date."),
        ]
        let signalByIndex = Dictionary(uniqueKeysWithValues: signals.map { ($0.0, ($0.1, $0.2)) })

        let total = 300
        var start = 0.0
        return (0..<total).map { index in
            // A 30s silence every 25 segments — a natural chunk boundary.
            if index > 0, index.isMultiple(of: 25) { start += 30 }
            let segStart = start
            let segEnd = start + 8
            start = segEnd + 1   // 1s gap between ordinary turns

            if let signal = signalByIndex[index] {
                return TranscriptSegment(
                    channel: signal.0 == .me ? .microphone : .system,
                    speaker: signal.0, text: signal.1, start: segStart, end: segEnd)
            }
            let speaker: Speaker = index.isMultiple(of: 2) ? .me : .teammates
            return TranscriptSegment(
                channel: speaker == .me ? .microphone : .system,
                speaker: speaker, text: filler(index), start: segStart, end: segEnd)
        }
    }

    @Test("long meeting routes through map-reduce and stays grounded")
    func longMeetingMapReduce() async throws {
        let manager = SummaryModelManager()
        let engine = try await manager.ensureReady { phase, fraction in
            print("[E2E] \(phase) \(Int(fraction * 100))%")
        }

        let transcript = Self.longTranscript()
        let validIDs = Set(transcript.map { $0.id.uuidString.lowercased() })
        let estimator = HeuristicTokenEstimator()
        let tokens = transcript.reduce(0) { $0 + estimator.estimate($1.text) }
        #expect(tokens > 20_000)                                  // genuinely long
        #expect(tokens > SummarizationPipeline.singlePassBudget)  // forces map-reduce

        let pipeline = SummarizationPipeline()
        var phases: [String] = []
        var snapshots = 0
        var final: MeetingSummary?
        for try await snapshot in await pipeline.generate(
            from: transcript, using: engine, progress: { phases.append($0) }) {
            snapshots += 1
            final = snapshot
        }

        let summary = try #require(final)
        print("[E2E long] tokens=\(tokens) snapshots=\(snapshots) phases=\(phases.count)")
        print("[E2E long] decisions=\(summary.decisions.count) actions=\(summary.actionItems.count) questions=\(summary.openQuestions.count) risks=\(summary.risks.count)")

        // Route was map-reduce: per-part progress fired.
        #expect(phases.contains { $0.hasPrefix("Summarizing part 1/") })
        #expect(snapshots > 1)

        // Prose present and grounded.
        #expect(!summary.shortSummary.isEmpty)
        #expect(!summary.detailedSummary.isEmpty)
        #expect(!summary.decisions.isEmpty)

        // Every surviving evidence ID is real (executable grounding filters the
        // rest on both routes).
        let allEvidence = summary.decisions.flatMap(\.evidenceSegmentIDs)
            + summary.actionItems.flatMap(\.evidenceSegmentIDs)
            + summary.openQuestions.flatMap(\.evidenceSegmentIDs)
            + summary.risks.flatMap(\.evidenceSegmentIDs)
        #expect(allEvidence.allSatisfy { validIDs.contains($0.lowercased()) })

        // Notes span the whole meeting: at least one item cites a segment from
        // the back half (the Postgres/regions/risk/scope-cut signals live there).
        let backHalfIDs = Set(transcript.suffix(transcript.count / 2).map { $0.id.uuidString.lowercased() })
        #expect(allEvidence.contains { backHalfIDs.contains($0.lowercased()) })

        // Grounding trap: the onboarding-guide action has no owner in the text.
        let onboardingActions = summary.actionItems.filter { $0.task.lowercased().contains("onboarding") }
        #expect(onboardingActions.allSatisfy { $0.owner == nil })
    }
}
