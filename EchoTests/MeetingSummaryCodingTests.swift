//
//  MeetingSummaryCodingTests.swift
//  EchoTests
//
//  The on-disk contract for `summary.json` as the summary grows its adaptive
//  `markdown` document (ADR-023 pattern: schemas evolve additively with
//  tolerant decoding). Every summary written before the markdown era must keep
//  decoding — the field simply comes back empty — and a markdown-bearing
//  summary must round-trip losslessly.
//
//  @MainActor because `MeetingSummary`'s Codable conformance is main-actor-
//  isolated (its nested value types are not `nonisolated`); MeetingStore hops
//  the same way to encode/decode.
//

import Foundation
import Testing
@testable import Echo

@Suite("MeetingSummary coding")
@MainActor
struct MeetingSummaryCodingTests {

    @Test("a legacy summary.json without a markdown key decodes with markdown empty")
    func legacyPayloadDecodes() throws {
        // Exactly the shape MeetingStore wrote before this field existed.
        let legacy = """
        {
          "shortSummary": "Short",
          "detailedSummary": "Detailed",
          "decisions": [{"title": "Ship it", "details": "Approved", "evidenceSegmentIDs": []}],
          "actionItems": [],
          "openQuestions": [],
          "risks": []
        }
        """
        let summary = try JSONDecoder().decode(MeetingSummary.self, from: Data(legacy.utf8))
        #expect(summary.markdown == "")
        #expect(summary.shortSummary == "Short")
        #expect(summary.detailedSummary == "Detailed")
        #expect(summary.decisions.first?.title == "Ship it")
    }

    @Test("a non-empty markdown document survives an encode/decode round trip")
    func markdownRoundTrips() throws {
        let original = MeetingSummary(
            markdown: "### Action Items\n- [ ] Cut the release branch\n\n### Release Plan\nShip Friday.",
            shortSummary: "",
            detailedSummary: "",
            decisions: [],
            actionItems: [],
            openQuestions: [],
            risks: []
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MeetingSummary.self, from: data)
        #expect(decoded == original)
        #expect(decoded.markdown == original.markdown)
    }
}
