# ADR-019: The final pass discards decode output that lacks evidence — an honest gap beats hallucinated text

**Status:** Accepted
**Date:** 2026-08-04

## Context

[SP-007](../specs/SP-007-final-transcript-quality-v2.md): the first real-meeting comparison (2026-08-04, Echo vs Notion on the same meeting) showed the shipped final pass persisting exactly the garbage classes its filters exist to stop: hallucination trains over in-window silence ("Gracias." ×25+), and 30-second repetition loops kept after every temperature-fallback retry failed. The code causes are structural, not tuning: the per-segment noise/boilerplate filters judge each segment against `AudioStats` computed over the **whole 30 s window** (a hallucination inside a window with speech elsewhere passes on the window's stats); `temperatureFallbackCount = 3` re-decodes flagged windows but **keeps the last attempt even when it still fails the thresholds**; and the pinned WhisperKit's `noSpeechProb` is dead code (hardcoded 0 — documented in SP-005), so no model-side silence signal exists. This decision clears the bar because it inverts a principle the codebase otherwise lives by — the live path's obligation to show something, and ADR-003's keep-on-doubt — and "the pass deleted words the model produced" will be re-litigated without a record of why.

Alternatives considered:

- **Keep the last fallback attempt (today's behavior)** — the evidence says this is where the "eh, eh, eh…" windows come from. Rejected by measurement, not taste.
- **Tighten the shared thresholds** (`logProbThreshold`, filters) — the thresholds are shared with the live path, which cannot afford rejection (it has no retry and must show something); and window-level stats stay blind to in-window silence however tight the numbers. Rejected: granularity is the defect, not the constants.
- **Lean on `noSpeechThreshold`** — inert in the pinned WhisperKit (dead `noSpeechProb`). Not available.
- **LLM post-correction of suspect text** (BRN-004 idea 8) — heavier machinery to repair text we can simply decline to keep; still deferred.

## Decision

The final pass errs toward omission — it, unlike the live path, has no obligation to show something and always may leave an honest gap:

1. **Rejection over acceptance:** a decode window whose final temperature-fallback attempt still fails the quality thresholds contributes **no text**. Exhausted retries produce a gap, never the least-bad attempt.
2. **Per-segment energy evidence:** every kept segment must show speech evidence over **its own time span** (energy stats sliced from the segment's samples), not the window's. A segment decoded over an in-window silent stretch fails its own evidence and drops, whatever the window average says.
3. **Run collapse:** runs of 3+ consecutive near-identical segments (normalized text) on a channel collapse; no such run survives to the persisted transcript.
4. **Tail-pad hygiene:** segments starting at or beyond the window's real audio end (the trailing silence pad) are dropped outright; segments bleeding into the pad keep their end clamped to the window boundary. No `end < start` segment can be produced.

Ordering is fixed: these are decode-discipline filters, applied **per channel during pass assembly, before** the ADR-003 batch dedup runs over the complete set; presentation-layer merging (ADR-021) stays strictly downstream of persistence and touches nothing here.

**Empty-output guard:** a pass whose disciplined output is empty counts as success only where the energy evidence itself says nobody spoke (no speech regions selected). If speech regions existed but every segment was dropped, the pass fails and the live floor stands (ADR-016) — so a filter bug can never silently erase a good transcript.

## Consequences

- Easier: the three motivating failure classes (hallucination trains, repetition loops, tail-pad `end < start` artifacts) become structurally impossible rather than threshold-unlikely; the acceptance fixtures from the real meeting are the proof.
- Easier: the live path is untouched — the discipline is final-pass-only, so the show-something contract of live transcription and its shared thresholds don't move.
- The asymmetry with ADR-003's keep-on-doubt is deliberate and scoped: dedup arbitrates between two channels' *real* text, where a false deletion loses the user's words; this discipline asks whether decoder output is evidence-backed *at all*, where a false keep is invented words in the user's mouth. Opposite error costs, opposite defaults.
- Accepted trade-off: genuinely quiet, marginal speech may drop text the live transcript had. Bounded by measurement, not assumption: the WER harness re-runs on clean fixtures must show no regression beyond normal variance (SP-005's two-sided containment), and the per-segment evidence check reuses the live gates' calibrated floors (`GateTerm`), not new numbers.
- Follow-up: near-identity for run collapse (normalization, run length, which representative survives) is tuned during build against the retained real-meeting fixtures — the constants are a starting point, the criterion ("no 3+ run survives") is the requirement.
