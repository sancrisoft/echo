//
//  TranscriptUtterance.swift
//  Echo
//
//  SP-007 S7 (ADR-021): utterance merging and backchannel filtering as pure
//  derivations over the persisted segments. This is the ONE shared home — the
//  transcript view derives utterances at render time and the summary pipeline
//  derives them when assembling model input, so the two consumers can never
//  disagree about what was merged or filtered. Nothing here is ever persisted
//  and nothing mutates its input; the segment-level record stays the source
//  of truth for dedup, Q&A, evidence citations, and the accuracy harness.
//

import Foundation

/// One conversational turn: a run of consecutive same-speaker segments merged
/// into a paragraph with a time range. Standalone backchannel segments are
/// filtered out of the derived flow (they remain untouched on disk).
nonisolated struct TranscriptUtterance: Identifiable, Hashable, Sendable {
    /// Stable identity: the FIRST constituent segment's ID. This is also the
    /// ID the summary pipeline renders into transcript lines, so a cited
    /// utterance always resolves to a real persisted segment.
    let id: UUID
    let speaker: Speaker
    let channel: AudioChannel
    /// First constituent's start (seconds relative to recording start).
    let start: TimeInterval
    /// Latest constituent's end.
    let end: TimeInterval
    /// Constituent texts joined into one paragraph.
    let text: String
    /// Every constituent persisted segment's ID, in timeline order — the
    /// evidence-grounding contract (ADR-021).
    let segmentIDs: [UUID]

    // MARK: - Tunables

    /// Maximum silence between consecutive same-speaker segments that still
    /// reads as one paragraph. The ~10 s class is conversational: decoder
    /// segments inside a continuing turn sit a breath apart (well under a few
    /// seconds), while the same speaker resuming after 10+ s of silence is a
    /// new thought. It also stays well under the chunker's 20 s hard topic
    /// seam (`ChunkingConfig.longGap`), so paragraphs never fuse across what
    /// chunking already treats as a break.
    static let maxMergeGap: TimeInterval = 10

    /// A standalone backchannel is at most this many normalized words.
    /// Anything longer carries content even when it opens with a token
    /// ("Okay, let's do the deploy tomorrow" must never filter).
    static let maxBackchannelWords = 3

    /// The build-owned backchannel table (SP-007 open question 1), seeded
    /// from the 2026-08-04 real meeting's mic channel (es + en) plus close
    /// spelling variants. Entries are `normalizedWords` forms — lowercase,
    /// punctuation stripped, hyphens/commas split words ("Mm-hmm." → "mm
    /// hmm"). Tuning the filter is editing these rows.
    static let backchannelTokens: Set<String> = [
        // English
        "mm hmm", "mm", "hmm", "mhm", "uh huh", "okay", "ok", "yeah",
        "good", "thank you", "thanks",
        // Spanish
        "ajá", "aja", "aha", "ah ok", "ah okay", "ya", "claro", "sí", "si",
        "bien", "gracias",
    ]

    // MARK: - Backchannel classifier

    /// Word-level normalization the backchannel table is written against:
    /// lowercase, split on anything non-alphanumeric (so punctuation,
    /// hyphens and apostrophes all become word breaks). Moved here from the
    /// retired live pipeline — this is its only remaining consumer.
    static func normalizedWords(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    /// True when the segment's normalized text consists ONLY of backchannel
    /// tokens within the length bound — a standalone acknowledgment that
    /// should not interrupt the other speaker's paragraph. The word sequence
    /// must partition into table entries ("ah ok" is one entry, "yeah okay"
    /// is two), so any non-token word keeps the segment in the flow.
    static func isStandaloneBackchannel(_ text: String) -> Bool {
        let words = normalizedWords(text)
        guard !words.isEmpty, words.count <= maxBackchannelWords else { return false }
        // Tiny DP over word positions (bounded by maxBackchannelWords):
        // reachable[i] means words[0..<i] partitions into table entries.
        var reachable = [Bool](repeating: false, count: words.count + 1)
        reachable[0] = true
        for index in 0..<words.count where reachable[index] {
            for endIndex in index..<words.count {
                if backchannelTokens.contains(words[index...endIndex].joined(separator: " ")) {
                    reachable[endIndex + 1] = true
                }
            }
        }
        return reachable[words.count]
    }

    // MARK: - Derivation

    /// The one shared derivation (ADR-021): persisted segments in, ordered
    /// utterances out. Pure — never mutates or persists anything; O(n) past
    /// the initial sort. The order of operations is fixed: sort by start,
    /// drop standalone backchannel FIRST, then merge same-speaker runs — so
    /// an acknowledgment never breaks the other speaker's run. A
    /// backchannel-only transcript derives to empty (the persisted record is
    /// untouched either way).
    static func derive(from segments: [TranscriptSegment]) -> [TranscriptUtterance] {
        // Stable sort: tie equal starts by input position so the derivation
        // is deterministic regardless of stdlib sort guarantees.
        let ordered = segments.enumerated()
            .sorted { ($0.element.start, $0.offset) < ($1.element.start, $1.offset) }
            .map(\.element)
            .filter { !isStandaloneBackchannel($0.text) }

        var utterances: [TranscriptUtterance] = []
        utterances.reserveCapacity(ordered.count)
        for segment in ordered {
            let piece = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let last = utterances.last,
               last.speaker == segment.speaker,
               last.channel == segment.channel,
               segment.start - last.end <= maxMergeGap {
                utterances[utterances.count - 1] = TranscriptUtterance(
                    id: last.id,
                    speaker: last.speaker,
                    channel: last.channel,
                    start: last.start,
                    end: max(last.end, segment.end),
                    text: last.text.isEmpty ? piece
                        : (piece.isEmpty ? last.text : last.text + " " + piece),
                    segmentIDs: last.segmentIDs + [segment.id]
                )
            } else {
                utterances.append(TranscriptUtterance(
                    id: segment.id,
                    speaker: segment.speaker,
                    channel: segment.channel,
                    start: segment.start,
                    end: segment.end,
                    text: piece,
                    segmentIDs: [segment.id]
                ))
            }
        }
        return utterances
    }
}
