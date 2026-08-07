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

    /// Tier B's level test: the candidate's span rms over the loudest linked
    /// Team span's rms. Bleed measured 0.05–0.43 on real audio; the user's own
    /// voice on the same mic sits at ≳ 1, far outside this.
    var assistedMaxRmsRatio: Float = 0.5

    /// Candidates with fewer normalized tokens than this are never suppressed:
    /// short acks ("yes", "ok") are indistinguishable from echo by text alone.
    var minimumTokenCount: Int = 3

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
        /// Candidate span rms ÷ loudest linked Team span rms. Nil when the
        /// caller supplied no evidence for these segments.
        let rmsRatio: Float?
    }

    // MARK: - Decision

    /// The full verdict for one candidate, or `nil` to keep it. Any doubt
    /// keeps the segment — false deletions are strictly worse than surviving
    /// duplicates (ADR-003).
    func verdict(
        for candidate: TranscriptSegment,
        against team: [TranscriptSegment],
        spanRms: [UUID: Float] = [:]
    ) -> SuppressionVerdict? {
        // Asymmetry (ADR-003): bleed only ever flows loudspeakers → mic, so
        // only mic-channel candidates can be echoes. Team segments always pass.
        guard candidate.channel == .microphone else { return nil }

        let candidateTokens = Set(Self.tokens(candidate.text))
        guard candidateTokens.count >= minimumTokenCount else { return nil }

        let linked = team.filter { $0.channel == .system && overlaps(candidate, $0) }
        guard !linked.isEmpty else { return nil }

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

        let ratio = rmsRatio(for: candidate, linked: linked, spanRms: spanRms)

        if containment >= textOnlyContainment {
            return SuppressionVerdict(
                match: best, tier: .text, containment: containment, rmsRatio: ratio
            )
        }
        // Tier B — and ONLY here does energy enter. Absent evidence keeps the
        // segment: the weak text match was never enough on its own.
        if let ratio, ratio <= assistedMaxRmsRatio {
            return SuppressionVerdict(
                match: best, tier: .assisted, containment: containment, rmsRatio: ratio
            )
        }
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
    /// `spanRms` is optional cross-channel evidence keyed by segment id — the
    /// rms of each segment's own span on its own channel. Supplying it enables
    /// Tier B and nothing else; omitting it leaves a pure, table-testable
    /// text policy. `onSuppression` receives every verdict, in input order.
    ///
    /// Order-preserving; Team segments always pass (the policy's asymmetry).
    func dedupe(
        final segments: [TranscriptSegment],
        spanRms: [UUID: Float] = [:],
        onSuppression: ((TranscriptSegment, SuppressionVerdict) -> Void)? = nil
    ) -> [TranscriptSegment] {
        let team = segments.filter { $0.channel == .system }
        guard !team.isEmpty else { return segments }
        return segments.filter { candidate in
            guard let verdict = verdict(for: candidate, against: team, spanRms: spanRms) else {
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

    /// The candidate's level relative to the loudest Team span it echoes.
    /// Nil whenever the evidence is incomplete or degenerate — an unknown
    /// ratio must never read as a quiet one.
    private func rmsRatio(
        for candidate: TranscriptSegment,
        linked: [TranscriptSegment],
        spanRms: [UUID: Float]
    ) -> Float? {
        guard let candidateRms = spanRms[candidate.id] else { return nil }
        let loudestTeam = linked.compactMap { spanRms[$0.id] }.max()
        guard let loudestTeam, loudestTeam > 0 else { return nil }
        return candidateRms / loudestTeam
    }

    // MARK: - Normalization

    /// Lowercased alphanumeric tokens — punctuation and casing differ freely
    /// between the two channels' independent transcriptions.
    private static func tokens(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }
}
