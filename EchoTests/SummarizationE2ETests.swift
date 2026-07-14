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
}
