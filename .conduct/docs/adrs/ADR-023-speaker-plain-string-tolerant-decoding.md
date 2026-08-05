# ADR-023: Speaker persists as a plain string with tolerant decoding; the schema evolves additively without a version bump

**Status:** Accepted
**Date:** 2026-08-04

## Context

[SP-007](../specs/SP-007-final-transcript-quality-v2.md): every persisted segment carries `"speaker": {"teammates": {}}` — Swift's synthesized encoding of a case-only enum — structural noise in every export and downstream consumer, encoding information fully derivable from `channel`. Cleaning it forces the first real answer to a question SPEC-03 deferred: **how does the persisted meeting schema evolve?** `MeetingMeta.schemaVersion` exists ("readers reject folders they don't understand") but no migration has ever run, and SP-007 also adds provenance fields (ADR-022) to meta.json. This clears the bar because the choice fixes the evolution register every future schema change will follow, and because the obvious alternative — bump to v2 with a migration — is the answer someone will re-propose.

Alternatives considered:

- **Bump schemaVersion to 2 + migrate old folders** — a rewrite of every meeting on disk (or dual readers keyed on version) for a cosmetic encoding change. Migration machinery is real cost and real risk against user history; save it for a change old readers genuinely must reject.
- **Drop the speaker field entirely, derive from channel** — cleanest bytes, but the field is the seam per-teammate diarization (SpeakerKit, explicitly left room for) will fill; removing it now re-breaks the schema later.
- **Keep the enum encoding and merely tolerate alternatives** — the dead weight persists in every new export; tolerance without the cleanup fixes nothing.

## Decision

`TranscriptSegment.speaker` persists as a **plain string** (`"me"` / `"teammates"`). Decoding is **tolerant**: readers accept both the legacy object form (`{"me":{}}` / `{"teammates":{}}`) and the plain string; an unrecognized speaker string decodes to the channel-derived default (mic → me, system → teammates) instead of failing the meeting — which also leaves forward room for diarization labels.

`schemaVersion` stays 1, establishing the register: **changes that widen what readers accept without invalidating existing files do not bump the version; only changes existing readers must reject do.** Old meetings load byte-untouched — no migration rewrites anything. ADR-022's provenance fields ride the same register (additive, optional, absent-tolerant).

## Consequences

- Easier: exports and every downstream consumer lose the structural noise; new transcripts encode what a reader means.
- Easier: all existing meetings keep opening with zero migration — backward tolerance is the whole mechanism.
- Accepted trade-off: **no downgrade path.** Pre-SP-007 builds cannot decode post-SP-007 transcripts (their synthesized decoder rejects the string form), and the schemaVersion gate cannot warn them — "v1" now spans both shapes. Accepted deliberately: no downgrade support was ever promised, and reserving the version bump keeps it meaningful for a change that needs it.
- Accepted trade-off: tolerant decoding means a hand-corrupted speaker value degrades silently to the channel default instead of surfacing an error — consistent with channel being the actual source of truth for attribution.
- Follow-up: the unmerged SPEC-06 RAG branch decodes `TranscriptSegment` — its rebase must pick up the tolerant decoder before it lands.
- Follow-up: the glossary's **Speaker** entry describes the enum encoding implicitly; reconcile it alongside SP-007.
