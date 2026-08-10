//
//  TranscriptDedup.swift
//  Echo
//
//  ADR-003 v2: asymmetric, overlap-linked, keep-on-doubt transcript
//  deduplication. Suppresses finalized mic-channel segments that are speaker
//  bleed (acoustic echo of a Team segment); Team segments are never touched.
//
//  v1 assumed the two channels were cut on comparable boundaries: it gated on
//  a signed start lag (0…2.5 s) and scored mutual Jaccard similarity. Neither
//  assumption survives per-channel segmentation — each channel's cutter places
//  boundaries at its own silences, so starts drift in BOTH directions (lags of
//  −8.7 s were measured on real audio) and a long mic segment dilutes a
//  symmetric score with its own extra words. Measured result: 8 bleed segments
//  on the fixture meeting, 0 suppressed.
//
//  v2 replaces both: segments LINK by interval overlap (drift-immune) and are
//  scored by DIRECTIONAL containment (what fraction of the mic segment's words
//  the teammates already said). Energy evidence, when the caller has it, only
//  ever *assists* a weak text match — it can never suppress on its own, so a
//  segment whose words are the user's own is structurally undeletable however
//  quiet it is.
//
//  Pure logic over `TranscriptSegment` values plus an optional per-segment rms
//  map — no audio, no I/O.
//

import Foundation

struct EchoDedupPolicy {

    // MARK: - Tunables
    //
    // Measured 2026-08-06 against two real dedupOnly (no-AEC) meetings; these
    // are the empirical starting point, not requirements. Every one of them is
    // a single knob, tuned on the replay harness and never on theory.

    /// How long after a Team segment *ends* an echo of it may still be
    /// running on the mic channel. Absorbs per-channel VAD endpointing skew;
    /// the acoustic path itself measured ~124 ms. A mic segment that does not
    /// overlap `[team.start, team.end + echoTailPad]` is never that segment's
    /// echo, whatever it says.
    var echoTailPad: TimeInterval = 2.5

    /// Containment at or above which the text alone is proof of bleed
    /// (Tier A). High on purpose: below this is doubt.
    var textOnlyContainment: Double = 0.6

    /// Containment floor for an energy-assisted suppression (Tier B). Text is
    /// still mandatory here — this is the *weak* match that cross-channel
    /// level evidence is allowed to resolve, not a bypass of it.
    var assistedContainment: Double = 0.35

    /// Tier B's level test: over the candidate's own window, the mic channel's
    /// rms divided by the system channel's. Bleed measured 0.05–0.43 on real
    /// audio; the user's own voice sits at ≳ 1, far outside this.
    var assistedMaxRmsRatio: Float = 0.5

    /// Candidates with fewer normalized tokens than this are never suppressed:
    /// short acks ("yes", "ok") are indistinguishable from echo by text alone.
    var minimumTokenCount: Int = 3

    /// An uninterrupted stretch this long of the candidate's own channel
    /// out-carrying the other one means the user genuinely spoke inside this
    /// segment, and the segment is kept whole — whatever its text says.
    ///
    /// Segments are the unit of suppression but not the unit of speech: the
    /// pass cuts at silences, and when a teammate's audio runs continuously
    /// underneath a reply there is no silence to cut at, so one segment ends
    /// up holding both. Measured on the fixtures, 10 of 19 suppressed rows
    /// carried 1.1–6.6 s of the user's own voice alongside the echo. Deleting
    /// those loses words that exist nowhere else; leaving the echo in loses
    /// nothing. A full second of sustained dominance is far more than the
    /// crossover flicker of an echo's own modulation.
    var ownVoiceRescueSeconds: TimeInterval = 1.0

    /// Two tokens with this many leading characters in common count as the
    /// same word. The channels are transcribed independently, so endings drift
    /// ("escanear" / "escanea") while stems do not.
    static let fuzzyPrefixLength = 5

    // MARK: - Verdict

    /// Which evidence carried a suppression — recorded so the replay harness
    /// can show *why* a segment went, not just that it did.
    enum Tier: String, Sendable {
        /// Text alone: containment ≥ `textOnlyContainment`.
        case text
        /// Weak text match resolved by cross-channel level evidence.
        case assisted
    }

    /// Why one candidate was suppressed. `match` is the single linked Team
    /// segment the candidate duplicates most — the pooled score is what
    /// decides, this is what a human reads.
    struct SuppressionVerdict {
        let match: TranscriptSegment
        let tier: Tier
        /// Fraction of the candidate's tokens found across ALL linked Team
        /// segments pooled.
        let containment: Double
        /// `own ÷ other` over the candidate's own window. Nil when the caller
        /// supplied no evidence for this segment.
        let rmsRatio: Float?
        /// How close this row came to the own-voice guard that would have kept
        /// it — zero without evidence. Reported so a replay shows the margin,
        /// not just the outcome.
        let ownVoiceSeconds: TimeInterval
    }

    /// One segment's level on BOTH channels over its own time span — the
    /// measured bleed discriminator (mic vs system on the same window). It has
    /// to be the same window on both channels: comparing a segment's level
    /// against some *other* segment's span compares two different moments and
    /// stops discriminating as soon as either channel's loudness moves, which
    /// is constantly.
    struct SpanLevels: Sendable, Equatable {
        /// The channel the segment came from, over the segment's span.
        let own: Float
        /// The opposite channel, over that same span.
        let other: Float
        /// Longest uninterrupted stretch, in seconds, where `own` out-carries
        /// `other` inside the span — an echo of the other channel cannot
        /// produce one, so it is positive proof the speaker was here.
        let ownVoiceSeconds: TimeInterval

        nonisolated init(own: Float, other: Float, ownVoiceSeconds: TimeInterval = 0) {
            self.own = own
            self.other = other
            self.ownVoiceSeconds = ownVoiceSeconds
        }
    }

    // MARK: - Decision

    /// The full verdict for one candidate, or `nil` to keep it. Any doubt
    /// keeps the segment — false deletions are strictly worse than surviving
    /// duplicates (ADR-003).
    func verdict(
        for candidate: TranscriptSegment,
        against team: [TranscriptSegment],
        spanLevels: [UUID: SpanLevels] = [:]
    ) -> SuppressionVerdict? {
        // Asymmetry (ADR-003): bleed only ever flows loudspeakers → mic, so
        // only mic-channel candidates can be echoes. Team segments always pass.
        guard candidate.channel == .microphone else { return nil }

        let candidateTokens = Set(Self.tokens(candidate.text))
        guard candidateTokens.count >= minimumTokenCount else { return nil }

        let linked = team.filter { $0.channel == .system && overlaps(candidate, $0) }
        guard !linked.isEmpty else { return nil }

        // Own-voice guard, ahead of every tier including the text-only one.
        // Text says what a segment overlaps with; this says the user was
        // actually talking inside it, and that outranks any similarity score.
        let levels = spanLevels[candidate.id]
        if let levels, levels.ownVoiceSeconds >= ownVoiceRescueSeconds { return nil }

        // Pooled: the echo of one utterance routinely lands across two Team
        // segments (independent cutters), and scoring against either alone
        // would read as half a match.
        let pooled = Self.matcher(for: linked.flatMap { Self.tokens($0.text) })
        let containment = pooled.containment(of: candidateTokens)
        guard containment >= assistedContainment else { return nil }

        // The one to name in the verdict: whichever linked segment on its own
        // accounts for most of the candidate.
        let best = linked.max { lhs, rhs in
            Self.matcher(for: Self.tokens(lhs.text)).containment(of: candidateTokens)
                < Self.matcher(for: Self.tokens(rhs.text)).containment(of: candidateTokens)
        }
        guard let best else { return nil }

        let ratio = levels.flatMap { $0.other > 0 ? $0.own / $0.other : nil }

        func verdict(_ tier: Tier) -> SuppressionVerdict {
            SuppressionVerdict(
                match: best,
                tier: tier,
                containment: containment,
                rmsRatio: ratio,
                ownVoiceSeconds: levels?.ownVoiceSeconds ?? 0
            )
        }

        if containment >= textOnlyContainment { return verdict(.text) }
        // Tier B — and ONLY here does level enter as grounds to delete. Absent
        // evidence keeps the segment: the weak text match was never enough on
        // its own.
        if let ratio, ratio <= assistedMaxRmsRatio { return verdict(.assisted) }
        return nil
    }

    /// Returns the Team segment the candidate duplicates, or `nil` to keep it.
    /// The evidence-free entry point (`RecordingState.append`): Tier A only.
    func suppressionMatch(
        for candidate: TranscriptSegment,
        against recent: [TranscriptSegment]
    ) -> TranscriptSegment? {
        verdict(for: candidate, against: recent)?.match
    }

    /// SP-005: the SAME policy re-run over a complete final segment set (the
    /// final pass re-segments both channels, so ADR-003's guarantees must be
    /// re-established on the new boundaries). Every mic segment is checked
    /// against the batch's whole Team set — which makes batch dedup only ever
    /// stronger than live: a Team counterpart that live transcribed too late
    /// to be in the "recent" window at the mic segment's arrival is present
    /// and matchable here.
    ///
    /// `spanLevels` is optional cross-channel evidence keyed by segment id —
    /// both channels' rms over that segment's own window. Supplying it enables
    /// Tier B and nothing else; omitting it leaves a pure, table-testable
    /// text policy. `onSuppression` receives every verdict, in input order.
    ///
    /// Order-preserving; Team segments always pass (the policy's asymmetry).
    func dedupe(
        final segments: [TranscriptSegment],
        spanLevels: [UUID: SpanLevels] = [:],
        onSuppression: ((TranscriptSegment, SuppressionVerdict) -> Void)? = nil
    ) -> [TranscriptSegment] {
        let team = segments.filter { $0.channel == .system }
        guard !team.isEmpty else { return segments }
        return segments.filter { candidate in
            guard let verdict = verdict(for: candidate, against: team, spanLevels: spanLevels) else {
                return true
            }
            onSuppression?(candidate, verdict)
            return false
        }
    }

    // MARK: - Linking

    /// Does the candidate run at any point inside the Team segment's echo
    /// window? Boundaries touch-inclusive; direction-free by design, because
    /// which channel's cutter placed a boundary first carries no information.
    private func overlaps(_ candidate: TranscriptSegment, _ team: TranscriptSegment) -> Bool {
        candidate.start <= team.end + echoTailPad && team.start <= candidate.end
    }

    // MARK: - Containment

    /// A Team token pool prepared for matching: exact tokens plus their
    /// `fuzzyPrefixLength` stems, so a lookup is O(1) instead of a scan.
    private struct TokenMatcher {
        let exact: Set<String>
        let stems: Set<String>

        /// Fraction of `candidate`'s tokens this pool accounts for.
        func containment(of candidate: Set<String>) -> Double {
            guard !candidate.isEmpty else { return 0 }
            let found = candidate.filter(contains).count
            return Double(found) / Double(candidate.count)
        }

        /// Exact hit, or a shared stem. Tokens shorter than the prefix length
        /// have no stem: for them "5 characters in common" can only mean
        /// equality, which the exact set already answers.
        private func contains(_ token: String) -> Bool {
            if exact.contains(token) { return true }
            guard token.count >= EchoDedupPolicy.fuzzyPrefixLength else { return false }
            return stems.contains(String(token.prefix(EchoDedupPolicy.fuzzyPrefixLength)))
        }
    }

    private static func matcher(for tokens: [String]) -> TokenMatcher {
        var exact: Set<String> = []
        var stems: Set<String> = []
        for token in tokens {
            exact.insert(token)
            if token.count >= fuzzyPrefixLength {
                stems.insert(String(token.prefix(fuzzyPrefixLength)))
            }
        }
        return TokenMatcher(exact: exact, stems: stems)
    }

    // MARK: - Evidence

    // MARK: - Normalization

    /// Lowercased alphanumeric tokens — punctuation and casing differ freely
    /// between the two channels' independent transcriptions.
    private static func tokens(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }
}
