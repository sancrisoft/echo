# ADR-020: Final-pass language is decided per window on voiced evidence, with an alternate-language re-decode as backstop

**Status:** Accepted — amended 2026-08-05 after the first kept-fixture field measurements (see Amendment at the end)
**Date:** 2026-08-04

## Context

[SP-007](../specs/SP-007-final-transcript-quality-v2.md): the 2026-08-04 real meeting exposed covert translation — the user's Spanish sentences persisted as approximate English, unrecoverable downstream. The shipped `FinalPassLanguageTracker` defaults to "en", lets the first confident detection set the session language, and requires a two-window streak to switch; detection runs on the silence-padded clip of the whole window. On a microphone channel dominated by short English-detecting backchannel ("Mm-hmm", "Okay"), the tracker locks English, every pending switch streak is broken by the next backchannel window, and the user's full Spanish sentences decode with `language=en` — which Whisper renders as translation, not transcription. No energy filter can catch the result: it is fluent, plausible, and wrong. This clears the ADR bar because the language policy shapes every window's decode and the design space has real, defensible alternatives — the hysteresis design being replaced was itself a reasoned SP-005 decision.

Alternatives considered:

- **Keep session hysteresis, lower the streak** — still a whole-channel lock; a backchannel-dominated channel still starves the streak. The failure is the lock itself, not its constant.
- **Dual decode of every window in both whitelist languages** — 2× decode cost on every window for a decision most windows don't need. Rejected on cost; kept as the *backstop* for flagged windows only.
- **Per-channel default from system locale** — a guess about the user, not evidence from the audio; wrong for exactly the mixed-language meetings this exists for.
- **Widen or drop the language whitelist** — out of scope (SP-005 register); the whitelist is orthogonal to how a language is *chosen* within it.

## Decision

The final pass replaces the session lock with per-window decisions grounded in what was actually voiced:

1. **Detection evidence is the voiced span.** Language detection runs on the window's speech-region samples — never on the trailing silence pad, never diluted by in-window silence.
2. **A confident in-whitelist detection decides its own window.** The window decodes in the detected language, full stop — no streak, no session lock. The session-informed language (most recent confident detection) survives only as the fallback for windows with *no* confident in-whitelist detection.
3. **Flagged windows get an A/B re-decode.** A window whose decode still fails the quality thresholds after temperature fallback is re-decoded once in the other whitelist language; the result with the better model-reported confidence is kept (and remains subject to ADR-019's discipline — both may lose).
4. **The prompt chain resets on a decode-language change**, so prior-text conditioning in one language can never drag the next window's decode toward it.

## Consequences

- Easier: mixed es/en meetings decode each window in its spoken language — the covert-translation class disappears at its root, verified by the real-meeting excerpt fixture.
- Easier: backchannel stops being load-bearing — short acknowledgment windows can detect however they like without deciding the fate of full sentences elsewhere on the channel.
- A single-window misdetection now mis-decodes one window instead of poisoning a session — and a mis-decode bad enough to matter flags on quality thresholds, where the A/B backstop catches it. Whipsaw, the hysteresis design's original fear, is harmless once decisions are per-window: alternating languages per window *is* the correct output for a mixed meeting.
- Accepted trade-off: up to one extra decode (plus detection on voiced spans) per flagged window — post-meeting time SP-005 already declared affordable; the pass-duration NFR ("well under the meeting's own duration") is the fence.
- Accepted trade-off: the A/B backstop is designed for a 2-language whitelist. A wider whitelist makes it combinatorial — revisit this ADR before widening.
- Follow-up: "confident detection" needs a concrete floor (the pinned WhisperKit reports detection probabilities); pinned during build against the mixed-language fixtures.

## Amendment (2026-08-05 — measured on the first kept real-meeting fixture)

Two behaviors this ADR described changed after replay-harness measurements on real audio (fixture A5021FAC; diagnostic trail in its `replay-*.json` files), plus one implementation fact worth recording:

1. **Detection probabilities are log-space.** The pinned WhisperKit's `detectLangauge` returns log-softmax values (≤ 0), not linear probabilities. The decisive/uncertain floors operate on linear probabilities after an explicit conversion owned by the language tracker — the original build compared floors against log values, making every window "uncertain."
2. **"Better model-reported confidence" excludes text-free output.** The A/B verdict compares mean avgLogprob over segments with real text only; a decode that produced no text has no confidence and loses to any real-text decode (both empty keeps the primary, and empty winners never update the session prior). Measured motivation: Whisper occasionally returns a single empty whole-window segment with default metrics (logprob 0.0) that otherwise "won" every comparison and erased windows of real speech.
3. **The prompt chain is consumed only by decisive windows, and a prompted decode that collapses to no real text is re-decoded once promptless.** Uncertain windows therefore A/B-compare like with like (both promptless), and chained-decode collapse over real speech (measured on the fixture) self-heals instead of erasing the window. The quality-flagged A/B on decisive windows deliberately keeps the chained primary in the comparison — with empty-never-wins the measured harm is gone, and strict fairness there would cost a third decode.

ADR-019's rejection thresholds were measured innocent in the same investigation (zero rejection drops on real speech across both replays) and are untouched.
