# ADR-021: Utterance merging and backchannel filtering are derived views — the persisted transcript stays segment-level

**Status:** Accepted
**Date:** 2026-08-04

## Context

[SP-007](../specs/SP-007-final-transcript-quality-v2.md): the transcript must read as a conversation (consecutive same-speaker segments merged into utterances, standalone backchannel kept out of the other speaker's paragraphs), and the summary pipeline must receive that merged, filtered form. The open question was whether merged utterances are persisted alongside (or instead of) segments, or derived at consumption time. This clears the bar because it fixes what `transcript.json` *means* — the contract ADR-016 built ("one transcript.json, one meaning") and every consumer (detail view, summary grounding, the unmerged SPEC-06 RAG branch, the WER harness, ADR-003 dedup) reads against — and because "just store the merged form" is the intuitive answer someone will reach for.

Alternatives considered:

- **Persist utterances alongside segments** (a second array or sidecar) — two representations of one transcript that can drift, a which-one-wins rule in every reader, and today's merge policy baked immutably into every meeting written under it. The merge policy is *expected* to be tuned (the backchannel token set is a build-time list seeded from one meeting); persisting its output versions the policy into the data.
- **Persist utterances instead of segments** — destroys the segment-level record: ADR-003 dedup, cross-channel timestamp alignment, per-segment summary evidence citations, and WER scoring all consume segments. Rejected outright.
- **Merge inside the final pass before the atomic replace** — same problem wearing the pass's clothes; also couples a presentation policy to ADR-019's decode discipline, which must stay about evidence, not readability.

## Decision

Utterance merging and backchannel filtering are **pure derivations computed from the persisted segments at consumption time** — the transcript view derives utterances at render, and summary-input assembly derives them (same function, one home) when generation starts. Nothing writes derived utterances to disk; the persisted transcript remains the segment-level record with unchanged meaning.

Derived utterances carry their constituent segments' IDs, so the summary's evidence grounding (SPEC-05: citations resolve to segment IDs) keeps resolving to persisted segments even though the model reads merged text.

## Consequences

- Easier: existing meetings gain the conversation rendering for free — a derivation over old segments needs no migration, and every policy tuning applies retroactively to all history.
- Easier: ADR-016's contract is untouched — dedup, RAG (SPEC-06 branch), Q&A, and the accuracy harness keep consuming exactly the file they consume today.
- Easier: the ordering constraint stays trivial to hold — ADR-003 dedup and ADR-019 discipline operate on segments before persistence; merging exists only after and outside it, so presentation can never alter the record.
- Accepted trade-off: the merge recomputes on every render/summary run — O(segments) of pure Swift, negligible against decode and generation; the "opening a meeting stays instant" NFR is the fence.
- Follow-up: the backchannel classification (token set, length bounds — SP-007 open question 1) lives in one shared home so render and summary can never disagree about what was filtered.
