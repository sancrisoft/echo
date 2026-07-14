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

@Suite("Summarization E2E", .enabled(if: acceptanceEnabled))
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
        // Filler is real conversational text (no owners/decisions) that pads the
        // token count; ~350 chars each keeps segments realistic.
        let filler = [
            "So, moving on, I think we should keep the momentum going on this.",
            "Right, and I looked at the numbers again over the weekend to be sure.",
            "Yeah, the dashboards are mostly green, a couple of yellow spots though.",
            "Let me share my screen so everyone can follow along with the charts.",
            "Okay, that makes sense, thanks for walking us through the details there.",
            "I agree the trend is encouraging but we shouldn't get complacent yet.",
            "Good point, let's keep an eye on the latency graph during peak hours.",
            "Someone asked about the mobile rollout earlier, we can circle back.",
            "Sure, I'll paste the link to the doc in the chat after the call.",
            "Understood, that all sounds reasonable to me from the data side.",
        ]

        // (index-in-output, speaker, text). Signal lines carry the facts.
        let signals: [(Int, Speaker, String)] = [
            (5,  .teammates, "Decision: we ship the Atlas beta this Friday, everyone agreed."),
            (40, .me,        "I'll prepare the release notes before Thursday, I'll own that."),
            (80, .teammates, "The onboarding guide still needs updating for the new sidebar."),
            (81, .me,        "True, nobody has picked that up yet, it's unassigned for now."),
            (120,.teammates, "Decision made: we migrate the backend to Postgres next sprint."),
            (160,.teammates, "Open question: which regions get the beta first? Marketing hasn't said."),
            (200,.me,        "Risk: the analytics vendor contract is still unsigned this week."),
            (201,.teammates, "Decision: we cut scope on the reporting module to hit the date."),
        ]
        let signalByIndex = Dictionary(uniqueKeysWithValues: signals.map { ($0.0, ($0.1, $0.2)) })

        let total = 250
        return (0..<total).map { index in
            if let signal = signalByIndex[index] {
                return TranscriptSegment(
                    channel: signal.0 == .me ? .microphone : .system,
                    speaker: signal.0, text: signal.1,
                    start: TimeInterval(index * 12), end: TimeInterval(index * 12 + 10))
            }
            let speaker: Speaker = index.isMultiple(of: 2) ? .me : .teammates
            let text = filler[index % filler.count] + " " + filler[(index / 3) % filler.count]
            return TranscriptSegment(
                channel: speaker == .me ? .microphone : .system,
                speaker: speaker, text: text,
                start: TimeInterval(index * 12), end: TimeInterval(index * 12 + 10))
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
