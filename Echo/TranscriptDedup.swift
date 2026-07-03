//
//  TranscriptDedup.swift
//  Echo
//
//  ADR-003: asymmetric, timing-gated, keep-on-doubt transcript deduplication.
//  Suppresses finalized mic-channel segments that are speaker bleed (acoustic
//  echo of a Team segment); Team segments are never touched. Pure logic over
//  `TranscriptSegment` values — no audio involved.
//

import Foundation

struct EchoDedupPolicy {

    // MARK: - Tunables (ADR-003: fixed empirically against the SP-001 fixture
    // suite during build; these defaults are the starting point, not requirements)

    /// How long after a Team segment *starts* an echo of it may start on the mic
    /// channel. Models the acoustic + processing echo path (speaker → mic delay,
    /// per-channel VAD endpointing skew). A user repetition later than this is
    /// structurally safe regardless of similarity.
    var echoLagWindow: TimeInterval = 2.5

    /// Minimum Jaccard similarity (over normalized token sets) between the mic
    /// candidate and the Team segment. High on purpose: below this is doubt,
    /// and doubt keeps the segment.
    var similarityThreshold: Double = 0.6

    /// Candidates with fewer normalized tokens than this are never suppressed:
    /// short acks ("yes", "ok") are indistinguishable from echo by text alone.
    var minimumTokenCount: Int = 3

    /// Returns the Team segment the candidate duplicates, or `nil` to keep it.
    /// Any doubt keeps the segment — false deletions are strictly worse than
    /// surviving duplicates (ADR-003).
    func suppressionMatch(
        for candidate: TranscriptSegment,
        against recent: [TranscriptSegment]
    ) -> TranscriptSegment? {
        // Asymmetry (ADR-003): bleed only ever flows loudspeakers → mic, so
        // only mic-channel candidates can be echoes. Team segments always pass.
        guard candidate.channel == .microphone else { return nil }

        let candidateTokens = Set(Self.tokens(candidate.text))
        guard candidateTokens.count >= minimumTokenCount else { return nil }

        for team in recent where team.channel == .system {
            // Timing gate first — it is mandatory; similarity alone never deletes.
            let lag = candidate.start - team.start
            guard lag >= 0, lag <= echoLagWindow else { continue }

            if Self.jaccard(candidateTokens, Set(Self.tokens(team.text))) >= similarityThreshold {
                return team
            }
        }
        return nil
    }

    private static func jaccard(_ a: Set<String>, _ b: Set<String>) -> Double {
        let union = a.union(b)
        guard !union.isEmpty else { return 0 }
        return Double(a.intersection(b).count) / Double(union.count)
    }

    /// Lowercased alphanumeric tokens — punctuation and casing differ freely
    /// between the two channels' independent transcriptions.
    private static func tokens(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }
}
