# ADR-016: Live transcript is the floor; the final pass replaces it atomically; retained audio marks pending finalization

**Status:** Accepted — converged-failure clause superseded by [ADR-024](ADR-024-terminal-draft-keeps-audio-manual-retry.md) (2026-08-04): terminal convergence now **keeps** the retained audio and offers a manual Retry, and audio presence is disambiguated (pending vs. terminal draft) by recorded provenance. The floor, the atomic replacement, bounded retries within a cycle, and audio-presence as the pending marker for the non-terminal case all stand.
**Date:** 2026-07-30

## Context

[SP-005](../specs/SP-005-transcript-accuracy.md): the persisted transcript feeds every downstream consumer (detail view, summary grounding, future RAG index), and the final pass introduces the first code path that ever *rewrites* a saved meeting's transcript. The failure to make impossible is a meeting that ends up with a worse-than-live or half-replaced transcript — or none. The decision clears the bar because the replacement semantics and the "pending finalization" state are the seam crash-resume, summary sequencing, and backfill gating all build on, and because the state-marker choice is non-obvious with real alternatives (a status field is the intuitive answer and the wrong one).

Alternatives considered:

- **Merge/patch final segments into the live transcript** — mixes two decodes' segment boundaries and timestamps in one file; a partial failure leaves a chimera no one can reason about; dedup and ordering invariants would have to hold across the mix. Rejected: replacement must be all-or-nothing.
- **Write the final transcript beside the live one** (`transcript-final.json`) — every reader (store, detail view, summarizer, RAG, word counts) grows a which-file-wins rule, and the wrong-file bug class lives forever. Rejected: one `transcript.json`, one meaning.
- **A `finalizationState` field in `meta.json` as the pending marker** — a second source of truth that can desync from the retained-audio files it describes (crash between audio deletion and meta write yields "pending" with no audio, or audio with "done"). Rejected for the same reason ADR-011 rejected persisted trigger state: derive state from what is actually on disk.
- **Chosen:** atomic whole-file replacement, gated on full success, with retained-audio presence as the sole pending marker.

## Decision

The live transcript is persisted at stop exactly as today (SPEC-03's crash-safety order) and is the **floor**: no code path may ever leave the meeting without it. A fully successful final pass replaces `transcript.json` **atomically** (the store's existing temp-file-plus-rename write) with the complete final segment set — a reader sees the old transcript or the new one, never a mixture — and re-derives the meta fields that describe it (segment count, word count) in the same step. Any failure leaves the live transcript byte-identical.

**Pending finalization is defined by presence of retained audio in the meeting folder** — no separate state file or meta flag. Success deletes the audio (the meeting becomes final); a crash or quit leaves it (next launch finds it and resumes); meeting deletion removes the folder and the state with it. Retries are bounded; **converged failure is terminal**: the retained audio is deleted, the live transcript stands with an honest notice, and the summary generates from the floor. A meeting pending finalization is not eligible for summary generation or backfill — its summary would otherwise be grounded in a transcript about to be replaced.

## Consequences

- Easier: crash-resume is a directory scan, not a state machine — a meeting folder containing retained audio *is* the work queue, and it cannot desync from itself.
- Easier: every downstream consumer keeps reading one `transcript.json` with unchanged shape; finalization changes the words, never the contract.
- Easier: "the transcript can only get better, never lost" becomes structural: the floor is written first, the replacement is atomic, and the only deletion target is audio, never transcript.
- Accepted trade-off: no incremental checkpointing — a pass interrupted at 90% restarts from the retained audio on next launch. Accepted for v1: the audio is the checkpoint, and per-window resume is complexity the failure rate hasn't earned yet.
- Accepted trade-off: terminal convergence means a meeting whose pass repeatedly failed keeps its live transcript forever (re-finalization is out of scope once audio is gone). The alternative — indefinite retention pending a someday-fix — breaks the bounded-retention promise (ADR-013).
- Follow-up: `transcript.json` and `meta.json` are two files, so the meta re-derivation is not in the same atomic unit as the transcript swap; the write order (transcript first, meta after, mirroring MeetingStore's existing meta-last discipline) keeps the stale-meta window benign — display-only fields. If a future consumer makes meta load-bearing, revisit.
- Follow-up: when the RAG sidecar (SPEC-06) merges, its index must be rebuilt from the final transcript — sequence it after finalization the same way the summary is.
