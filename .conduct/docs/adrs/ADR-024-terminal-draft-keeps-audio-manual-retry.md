# ADR-024: Terminal finalization failure keeps the retained audio and offers a manual Retry

**Status:** Accepted
**Date:** 2026-08-04

## Context

[SP-007](../specs/SP-007-final-transcript-quality-v2.md), second refinement round: the first round resolved the draft/retry ambiguity by keeping ADR-016 intact — terminal convergence deletes the audio, retries are automatic-only, the draft is permanent. The user overruled that resolution explicitly (2026-08-04): a final pass that converged to failure while they were away — a full disk, a corrupted model download, a bug this very spec exists because of — must not permanently cost the better transcript. They want a **manual Retry on the draft state, with the retained audio kept**, and they accept the privacy and disk consequence. This clears the bar three times over: it amends an accepted ADR (ADR-016's converged-failure clause), it changes the retention posture ADR-013 promised, and it forces a redesign of the pending-marker semantics ADR-016 built the launch scan on.

Alternatives considered:

- **Keep ADR-016 as accepted** (bounded automatic retries, delete on convergence, draft is final) — the first-round position. Rejected by product decision, recorded here so it is not re-proposed as "simpler."
- **Indefinite automatic retry instead of a button** — the retry loop ADR-016 rightly refused; a permanently failing meeting would burn a pass attempt on every launch forever. Retries stay bounded per cycle; only the *user* starts a new cycle.
- **Keep the audio but with no retry surface** (recover via some future re-finalize feature) — kept audio plus ADR-016's presence-means-pending scan is an automatic infinite retry across launches, and without the scan change it is incoherent; with the scan change but no button, the audio is dead weight. Rejected: keeping the audio only makes sense with the affordance that uses it.

## Decision

**Converged (terminal) finalization failure keeps the meeting's retained audio** and the meeting presents its live-floor transcript as a draft **with a manual Retry**. Retry is user-initiated and user-paced: it re-enqueues the meeting's pass with a **fresh bounded attempt budget**, front-running the deferred queue (the user-request discipline SP-005 already uses); recording still preempts; a cycle that converges again returns to the draft with the Retry still available. The loop is bounded within every cycle and driven only by the user across cycles — never automatic.

**The kept audio is deleted by exactly three paths:** a later successful pass (the draft becomes final), deletion of the meeting (folder removal, as ever), or an explicit **"Keep draft"** action that accepts the draft as the meeting's final transcript and releases the audio — the user's way to end retention without deleting the meeting. (The action is included on privacy grounds — local-first demands a user-controlled way out of retention — but it is a borderline product call, flagged in the spec's open questions.)

**Pending-marker disambiguation:** retained-audio presence now means *pending* or *terminal draft*, so it can no longer be the sole marker (amending ADR-016). The disambiguating bit lives in recorded provenance (ADR-022, amended to sanction exactly this): terminal convergence's single atomic meta write records transcript source `liveFloor`. The launch scan classifies a folder with retained audio by that field — **no transcript provenance → pending, auto-resume; `liveFloor` → terminal draft, never auto-resumed, waits for the user; `finalPass` → the orphan of a success whose cleanup crashed, swept (audio deleted), never re-run.** The terminal transition is one atomic write: the delete-plus-write desync pair ADR-016 feared at this transition no longer exists, and a crash *before* the write re-enters pending and simply converges again — self-healing in the safe direction.

## Consequences

- Easier: a transient-cause terminal failure is recoverable forever — the user retries after fixing the disk, the model, or updating the app; the 2026-08-04 class of defect meeting stays replayable *in production*, not just under the DEBUG flag.
- **Privacy and disk, honestly:** a terminally failed meeting's audio stays on disk **indefinitely, until the user acts** — a deliberate, user-accepted exception to SP-005's "failure never becomes indefinite retention" and to ADR-013's strictly-temporary posture, scoped to exactly this state. The audio still lives inside the meeting's own folder (deletion-safe by construction) and never leaves the device. ADR-013's and ADR-016's Status sections record the amendment.
- ADR-016's other clauses stand untouched: the floor, atomic replacement, audio-presence as the pending marker for the non-terminal case, and bounded retries *within* a cycle.
- Provenance gains one load-bearing bit, promoted explicitly rather than quietly (ADR-022 amended); any further scheduling use of provenance still requires its own decision.
- Accepted trade-off: draft meetings accumulate retained audio (tens of MB per hour per channel) with no cap — the user's own action is the bound. If accumulation becomes real, the answer is a nudge on the draft surface, never an automatic deletion.
- Follow-up: Retry and "Keep draft" copy (English, honest, confirmation for the irreversible release) per the SP-005 open-question-5 register; the pending-display function and launch-scan classification gain the new rows in SP-007's Testing Decisions.
