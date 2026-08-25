//
//  SummaryNotionParityTests.swift
//  EchoTests
//
//  S7 — the empirical gate for the adaptive markdown summary: generate REAL
//  summaries (real 4B MLX generations) for two of the Notion reference
//  meetings and assert the distilled quality rules structurally. Each
//  generated document is also written to
//  Fixtures/meeting-samples/output-<name>.md (BEFORE the asserts, so a
//  failing run still leaves the artifact) for human side-by-side review
//  against the Notion reference summary.
//
//  Doubly gated: ECHO_ACCEPTANCE=1 (real generations, ~1-3 min each) AND the
//  local-only sample transcripts under Fixtures/meeting-samples/ (real
//  meeting content, never committed — see Fixtures/README.md). This test
//  FILE quotes nothing from the transcripts beyond short assertion markers.
//

import Foundation
import Testing
@testable import Echo

private let acceptanceEnabled = ProcessInfo.processInfo.environment["ECHO_ACCEPTANCE"] == "1"

// .serialized: real generations share the Metal device (see
// SummarizationE2ETests) — run them one at a time.
@Suite("Summary Notion parity", .enabled(if: acceptanceEnabled), .serialized)
struct SummaryNotionParityTests {

    // MARK: - Loader (sample text → transcript segments)

    /// Splits a sample transcript (blank-line-separated paragraphs) into
    /// `TranscriptSegment`s with alternating speakers and synthetic
    /// timestamps ~8 s apart. Deterministic — no randomness — so a re-run
    /// generates from the identical prompt. The first paragraph is assigned
    /// to `.teammates` (both samples open with the other party speaking);
    /// constructed *text* segments are the sanctioned fixture style for LLM
    /// tests (workflow §0.5).
    static func segments(fromSampleText text: String) -> [TranscriptSegment] {
        var paragraphs: [String] = []
        var current: [String] = []
        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                if !current.isEmpty {
                    paragraphs.append(current.joined(separator: " "))
                    current = []
                }
            } else {
                current.append(line)
            }
        }
        if !current.isEmpty { paragraphs.append(current.joined(separator: " ")) }

        return paragraphs.enumerated().map { index, paragraph in
            let speaker: Speaker = index.isMultiple(of: 2) ? .teammates : .me
            let start = TimeInterval(index * 8)
            return TranscriptSegment(
                channel: speaker == .me ? .microphone : .system,
                speaker: speaker,
                text: paragraph,
                start: start,
                end: start + 7
            )
        }
    }

    // MARK: - Structural rule helpers

    /// The document's `###` section headings, trimmed.
    private static func headings(in markdown: String) -> [String] {
        markdown.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("### ") }
    }

    /// NDJSON leftovers: whole lines that are a single JSON object — the map
    /// protocol's shape, which must never surface in the document.
    private static func ndjsonBracesLines(in markdown: String) -> [String] {
        markdown.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("{") && $0.hasSuffix("}") }
    }

    /// Empty-section placeholders the ruleset forbids: "(none)" anywhere,
    /// "N/A" as a standalone token, and a line (bare or bulleted) that is
    /// just "none". "N/A" is matched on token boundaries, not as a raw
    /// substring — legitimate compound paths like "admin/app" contain the
    /// letters "n/a" without being a placeholder.
    private static func placeholderViolations(in markdown: String) -> [String] {
        var violations: [String] = []
        let lowered = markdown.lowercased()
        if lowered.contains("(none)") { violations.append("(none)") }
        if lowered.range(of: #"(^|[^a-z0-9])n/a([^a-z0-9]|$)"#, options: .regularExpression) != nil {
            violations.append("N/A")
        }
        let bareNoneLines = markdown.components(separatedBy: "\n").filter { rawLine in
            var line = rawLine.trimmingCharacters(in: .whitespaces).lowercased()
            for prefix in ["- [ ] ", "- [x] ", "- ", "* ", "+ "] where line.hasPrefix(prefix) {
                line.removeFirst(prefix.count)
            }
            return line == "none" || line == "none."
        }
        violations.append(contentsOf: bareNoneLines)
        return violations
    }

    // MARK: - Generation + artifact plumbing

    /// Loads the sample, runs the REAL pipeline + engine, writes the finished
    /// document to `output-<name>.md` (before any assert), and returns it.
    private func generateDocument(for name: String) async throws -> String {
        let text = try Fixtures.loadMeetingSampleText(name)
        let segments = Self.segments(fromSampleText: text)
        print("[Parity] \(name): \(segments.count) segments")

        let manager = SummaryModelManager()
        let engine = try await manager.ensureReady { phase, fraction in
            print("[Parity] \(phase) \(Int(fraction * 100))%")
        }

        let pipeline = SummarizationPipeline()
        var final: MeetingSummary?
        for try await snapshot in await pipeline.generate(from: segments, using: engine) {
            final = snapshot
        }
        let summary = try #require(final)
        let document = summary.markdown

        // Artifact FIRST: a failing run must still leave the document on disk
        // for the human side-by-side review.
        let outputURL = Fixtures.meetingSampleOutputURL(name)
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try document.write(to: outputURL, atomically: true, encoding: .utf8)
        print("[Parity] \(name): wrote \(document.count) chars to \(outputURL.path)")

        return document
    }

    // MARK: - Test A: checkin-echo-2 (single-pass, the small-talk trap)

    /// ~50% of this meeting is off-topic social chat (a historical-tour
    /// story); Notion's reference summary omits it entirely. The generated
    /// document must be adaptive (several specific sections + a checkbox
    /// list), clean (no fences, no NDJSON, no placeholders), specific to the
    /// meeting's real substance, and silent about the small talk.
    @Test(
        "checkin-echo-2: adaptive notes match the Notion bar",
        .enabled(if: Fixtures.meetingSampleAvailable("checkin-echo-2"), Fixtures.meetingSampleInstructions)
    )
    func checkinEcho2AdaptiveNotes() async throws {
        let document = try await generateDocument(for: "checkin-echo-2")

        // Structure: at least two distinct specific sections and a real
        // checkbox list.
        let headings = Self.headings(in: document)
        print("[Parity] checkin-echo-2 headings: \(headings)")
        #expect(Set(headings).count >= 2)
        #expect(document.contains("- [ ]"))

        // Contract hygiene: no code fences, no NDJSON leftovers, no
        // empty-section placeholders.
        #expect(!document.contains("```"))
        #expect(Self.ndjsonBracesLines(in: document).isEmpty)
        #expect(Self.placeholderViolations(in: document).isEmpty)

        // The small-talk trap: the social story must be omitted entirely
        // (Notion's reference summary does exactly that).
        let lowered = document.lowercased()
        for banned in ["bolívar", "bolivar", "napoleon", "tuberculosis"] {
            #expect(!lowered.contains(banned), "small talk leaked into the notes: \(banned)")
        }

        // Specificity: the meeting's real substance (audio-frequency bug,
        // Samsung AirBuds, Markdown converter/renderer, the Notion target).
        let markers = ["48", "airbud", "markdown", "notion", "frequen"]
        let found = markers.filter { lowered.contains($0) }
        print("[Parity] checkin-echo-2 specificity markers found: \(found)")
        #expect(found.count >= 2)
    }

    // MARK: - Test B: checkin-gocoinvest-2 (short, messy call)

    /// A short, garbled call: density scaling says short meeting → short
    /// notes (Notion's reference has 4 sections including a context section),
    /// still specific to the real work content and free of placeholders.
    @Test(
        "checkin-gocoinvest-2: short messy call gets short adaptive notes",
        .enabled(if: Fixtures.meetingSampleAvailable("checkin-gocoinvest-2"), Fixtures.meetingSampleInstructions)
    )
    func checkinGocoinvest2ShortNotes() async throws {
        let document = try await generateDocument(for: "checkin-gocoinvest-2")

        // Structure + density scaling: sectioned, but SHORT — a thin meeting
        // must not be padded out.
        let headings = Self.headings(in: document)
        print("[Parity] checkin-gocoinvest-2 headings: \(headings)")
        #expect(headings.count >= 1)
        #expect(headings.count <= 6)

        // Specificity: the call's real work substance.
        let lowered = document.lowercased()
        #expect(["gateway", "replit", "onboarding"].contains { lowered.contains($0) })

        // Contract hygiene, same rules as Test A.
        #expect(!document.contains("```"))
        #expect(Self.ndjsonBracesLines(in: document).isEmpty)
        #expect(Self.placeholderViolations(in: document).isEmpty)
    }
}
