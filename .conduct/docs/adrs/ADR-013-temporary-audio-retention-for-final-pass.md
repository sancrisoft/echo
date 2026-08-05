# ADR-013: Temporary compressed audio retention is the finalization mechanism

**Status:** Accepted — the converged-failure deletion path is superseded by [ADR-024](ADR-024-terminal-draft-keeps-audio-manual-retry.md) (2026-08-04): on terminal finalization failure the audio is now kept until the user retries to success, accepts the draft, or deletes the meeting — a deliberate, user-accepted exception to "no path retains audio indefinitely," scoped to that one state. Deletion on success and with the meeting, the retained-signal definition, and the timeline invariants all stand.
**Date:** 2026-07-30

## Context

[SP-005](../specs/SP-005-transcript-accuracy.md): the live pipeline destroys audio at stop, so its accuracy compromises are unrecoverable — the live transcript *is* the final transcript. Recovering what the live path structurally loses (30 s windows, prior-text conditioning, temperature-fallback retries, window-level language decisions) requires the meeting's audio to still exist after stop. But Echo's local-first posture has so far meant *no* stored audio, and "the app quietly keeps recordings" is a costly product position to walk back — this decision fixes the privacy boundary, the meeting-folder layout, and the crash-resume semantics that ADR-016 and the whole final pass build on.

Two sub-decisions ride along and are equally load-bearing:

- **What is retained:** the *pipeline-ingested* signal — mic post-echo-cancellation, both channels post-downmix at 16 kHz mono — not the raw capture. Re-transcribing raw mic audio would resurrect the speaker bleed the AEC removed live, leaving ADR-003's dedup as the only defense and making the final transcript *worse* on echo than the live one.
- **What timeline it carries:** the same recording-relative timeline the live clock built, declared capture gaps included (SP-001's 100 ms cross-channel skew budget; SP-002's gap realignment). A retained file that packs samples end-to-end across a gap would time-shift every post-gap final segment by the cumulative gap — breaking cross-channel alignment and ADR-003's 2.5 s timing gate.

Alternatives considered:

- **Never retain; improve the live decode instead** (language hysteresis, overlap at cuts, live prompt conditioning) — cannot reach Whisper's native operating point: 1–12 s isolated low-latency chunks are structurally beneath 30 s conditioned windows, and nothing live can retry a flagged decode without stalling the transcript. Deferred as a separate spec, not a substitute (BRN-004 ideas 4–6).
- **Retain raw WAV** — ~115–230 MB/h/channel; an hour-long meeting costs half a GB of transient disk for no accuracy gain over a clean ~24 kbps mono compression of speech. Rejected on footprint.
- **Retain permanently (audio archive)** — contradicts the product decision that retention is a transient processing artifact, and turns a transcription app into an audio recorder with the trust and disk consequences that implies. Rejected by product.
- **Retain the raw capture streams** — resurrects cancelled bleed (above) and diverges from the ingested timeline (audio the pipeline dropped pre-load would exist in the file but not in the live clock). Rejected: the retained signal must be exactly what the live pipeline transcribed, or the two transcripts aren't comparable and the timeline math breaks.

## Decision

During recording, Echo additionally writes each channel's **pipeline-ingested audio** (post-AEC mic, post-downmix, 16 kHz mono) as a compressed per-channel file inside the meeting's own folder. The retained timeline is faithful to the live clock: every retained sample maps to the same recording-relative timestamp the live pipeline assigned, declared capture gaps represented (silence fill or a gap map — build detail; the invariant is the mapping, within SP-001's skew budget). Retention is bounded (compressed speech-rate audio, tens of MB per hour per channel, never raw WAV) and strictly temporary: the files are deleted when the final pass succeeds, when bounded retries converge to failure, and with the meeting when the user deletes it. No path retains audio indefinitely; nothing leaves the device.

## Consequences

- Easier: the final pass gets the one thing live tuning can never provide — the audio back — so every structural lever (full windows, chaining, retries, window-level language) becomes possible post-meeting with zero live-path risk.
- Easier: retention living inside the meeting folder makes deletion safe by construction — meeting deletion is already a whole-folder remove (MeetingStore), so retained audio can never outlive its meeting.
- Easier: the ingested-signal tap point means live and final transcripts describe the same signal — WER comparisons and dedup parity are apples-to-apples.
- Accepted trade-off: the live path gains a compression/write stage; it must be profile-inaudible (no dropped buffers, no added latency) and its failure must degrade to "no final pass for this meeting," never to a broken recording.
- Accepted trade-off: for the retention window (stop → pass success), meeting audio exists on disk. Bounded, local, and deleted without user action — but real; the spec's privacy NFRs are the fence.
- Follow-up: the compressed format must preserve seekability and timeline fidelity (SP-005 open question 3); verify decode→re-encode round-trip cost on WER before trusting a low bitrate (harness, not assumption).
