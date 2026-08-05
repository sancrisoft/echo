# ADR-022: Meeting provenance is recorded in meta.json as a display-only record of completed outcomes — never a state marker

**Status:** Accepted
**Date:** 2026-08-04

## Context

[SP-007](../specs/SP-007-final-transcript-quality-v2.md): the 2026-08-04 defect meeting could not be diagnosed from its own data — a pass that fell back from the 947 MB model to the live turbo looks identical to a full-tier pass, and nothing records whether the persisted transcript is final-pass or live-floor output. Worse, the terminal-failure notice is in-memory by ADR-016's own design (`terminalFailureIDs`), so after a relaunch a floor-final meeting is indistinguishable from a finalized one — SP-007's persistent Draft badge has nothing to key on. The decision clears the bar because it sits in apparent conflict with ADR-016, which explicitly rejected a `finalizationState` field in `meta.json`; without a recorded reconciliation, this will be either re-litigated as a violation or quietly abused as one.

Alternatives considered:

- **Keep provenance in memory only (today)** — the Draft badge and the fallback distinction evaporate on relaunch; a quality complaint about last week's meeting stays undiagnosable. This is the gap, not an option.
- **A separate provenance sidecar file** — another file per meeting with a which-file-wins rule and its own staleness questions; meta.json already exists, is already re-derived on transcript replacement, and already tolerates optional fields (`wordCount`, `oneLineDescription`).
- **Derive it from retained-audio presence** — impossible: success deletes the audio at exactly the transition provenance must record, and at terminal convergence (which now keeps the audio, ADR-024) presence alone cannot tell a draft from a pending meeting.

## Decision

`meta.json` gains **additive, optional provenance fields** describing what produced the meeting's *current* persisted artifacts: the transcript's source (final pass vs. live floor), the speech checkpoint that produced it with its tier and a fallback flag (a full-tier machine served by the live model records as a fallback), and the summary model that wrote the notes. Model names follow the naming-honesty register (real checkpoint names, SP-005).

Each field is written **in the same step that writes the artifact it describes**: the atomic transcript replacement already re-derives meta (ADR-016's transcript-first, meta-after order) and now includes transcript provenance; terminal convergence records `live floor`; attaching a summary records the summary model. A meeting never finalized (retention failed or was unavailable) records `live floor` when that outcome is known.

Provenance is **display and diagnostics only, with one explicitly sanctioned scheduling use** ([ADR-024](ADR-024-terminal-draft-keeps-audio-manual-retry.md)): the transcript-source field disambiguates a folder with retained audio in the launch scan — no transcript provenance means pending (auto-resume), `liveFloor` means terminal draft (waits for the user's Retry), `finalPass` means the orphan of a crashed success cleanup (swept). Beyond that one bit, nothing schedules off provenance; pending finalization otherwise remains audio presence (ADR-016). Absent fields — every pre-SP-007 meeting — render as "unknown," never as an error.

## Consequences

- Easier: a quality complaint about any meeting is diagnosable from its own folder — which model, which tier, fallback or not, final or floor.
- Easier: SP-007's Draft badge survives relaunch honestly — it keys on persisted provenance (`live floor`), not on the in-memory terminal set.
- The ADR-016 reconciliation, recorded: ADR-016 rejected meta as a **state marker driving the work queue** — a second source of truth that desyncs from the audio files it describes. Provenance is a **record of a completed outcome**, written after the fact alongside the artifact it describes. The one scheduling use ADR-024 sanctions is safe precisely because the desync pair ADR-016 feared doesn't exist there: the terminal transition is a single atomic meta write (no audio deletion beside it), and a crash before it re-enters pending harmlessly.
- Accepted trade-off: two writers of truth about "what transcript is this" exist (file contents vs. provenance field) with a benign inconsistency window. Provenance was promoted to one load-bearing bit **once, explicitly, in ADR-024** — any further scheduling use requires its own decision, never a quiet promotion.
- Follow-up: exposing provenance in the UI beyond the Draft badge ("Transcribed with…") is deliberately out of SP-007's scope (its open question 3); the fields are designed to make that surface a rendering exercise.
