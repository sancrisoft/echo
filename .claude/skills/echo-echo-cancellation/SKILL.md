---
name: echo-echo-cancellation
description: How Echo removes speaker bleed from the microphone channel and why the offline pre-pass is switched off — `Echo/AEC/`, `AECStage`, `SwitchingAECStage`, `WebRTCAECStage`, `APMEchoCanceller`, `EchoCancellationPrePass`, `EchoBleedProbe`, `EchoHandlingMode`, ERLE, own-word preservation, double-talk word loss.
---

## The offline pre-pass is OFF, and turning it on is a regression

`EchoCancellationPrePass.isEnabled` returns `false` in release and only `ECHO_AEC_PRE_PASS=1` in DEBUG (`EchoCancellationPrePass.swift:66-73`). Do not flip that default, and do not remove the flag — the probe, engine and near-end guard all stay live for the next measurement.

The gate is **≥0.90 own-word preservation**. Measured 2026-08-10 over all nine meetings on disk holding a kept pair: the probe correctly skips the five with no speaker path (byte-identical either way) and fires on four, where it costs a fifth to a quarter of the user's own vocabulary while its return swings from most of the bleed gone to *worse than before* (`EchoCancellationPrePass.swift:44-56`):

| meeting | delay | own words kept | bleed-shaped seconds |
|---|---|---|---|
| 1CB18219 | 215 ms | 80% | 34.1 → 19.3 |
| 583FCA7D | 278 ms | 75% | 29.8 → 5.0 |
| 65B5A4C0 | 125 ms | 84% | 12.2 → 12.1 |
| E656A3F9 | 140 ms | 77% | 9.7 → **15.1** |

**Losing the user's own words is the worse failure.** The summary is grounded in the transcript, so a word deleted here is gone from the notes; surviving bleed is only misattributed — the words are still on the teammate's row and the summary still reads them.

## The near-end ratio floor is not the lever — the silence floor is

`nearEndRatioFloor` was swept 0.50 → 0.05 over the E656 and 65B5 replays: preservation moved only 0.622 → 0.671 and 0.820 → 0.848 (`EchoCancellationPrePass.swift:115-124`). A tenfold threshold change buys five points. The frames carrying the lost words fail `near >= EnergyEnvelope.silenceFloor` (0.002, `ParakeetPass.swift:193`) — on E656 the user's voice sits under that floor while the TV's bleed does not, capping protection at 51% however low the ratio goes. If you attempt this again, the floor or the envelope beneath it is the open lead, and a sweep must clear 0.90 before the flag moves.

## 0.5 is one constant serving three places

Bleed arrives through a speaker and a room at **0.05-0.43** of the reference; the user's own voice sits at **0.52 and up**, and nothing between the two was ever measured. That single discriminator is `EchoBleedProbe.bleedRatioCeiling` (window selection), `EchoDedupPolicy.assistedMaxRmsRatio` (Tier B), and `EchoCancellationPrePass.defaultNearEndRatioFloor` (frame protection). Change one and you have silently changed a claim the other two rest on. The ratio must always be **same-window** mic/system — cross-span ratios put must-keep rows below must-suppress rows and no threshold separates them.

## Probe: what a valid verdict looks like

`EchoBleedProbe` decides from the audio alone, because the mode a meeting recorded under is nowhere in its metadata and Retry must work on meetings older than any of this. Every floor came from three real meetings on one TV and is deliberately not configurable (`EchoBleedProbe.swift:26-78`):

- 5 ms envelope frames (100 ms `EnergyEnvelope` frames are far too coarse for a delay in tens of ms), 10 s windows, at most 6 spread across the meeting.
- Only **bleed-shaped** windows count (ratio ≤ 0.5) — windows where the user is talking pollute the correlation and produced the low-coherence readings that first looked like clock drift.
- `coherenceFloor` 0.35 (real bleed reads 0.40-0.83), `agreementCount` 2, agreeing within `agreementSeconds` 0.025, `maxLagSeconds` 0.4.
- Measured echo paths sit at **125-180 ms with zero drift within a meeting** (both retained channels share the live clock). A 278 ms verdict is outside that band and was damage, not signal.
- The correlation lives in the loudness **envelope**, not the waveform — what survives a speaker, a room and a mic is the loudness contour.

Warm-up is a **60 s prefix**: measured 17.4 dB on the worst fixture against 14.9 for no warm-up and 13.8 for a full second pass, which is worse than nothing because the seam hands the engine the end of the meeting followed by its beginning and the delay estimator pays for the discontinuity.

**Never gate on ERLE alone.** ERLE cannot tell subtraction from suppression: AEC3 protects the far end, not the near one, and through double-talk it gates whatever the mic carries. On a real Discord meeting ERLE read 13.71 dB while half the user's words vanished in every overlapping span; adding the near-end guard dropped ERLE to 7.91 dB and that was the *improvement*.

## Live path: echo cancellation only

`APMEchoCanceller` configures the vendored WebRTC APM with `echo_canceller.enabled = true`, `mobile_mode = false` (full AEC3), and every other stage explicitly `false` — pre-amplifier, capture level adjustment, high-pass filter, noise suppression, transient suppression, both gain controllers (`Echo/AEC/APMEchoCanceller.mm:28-40`). They are set explicitly so an upstream default change cannot switch one on silently. Do not enable NS or AGC here.

- Frames are **160 samples = 10 ms at 16 kHz** on both paths (`APMEchoCancellerFrameSize`). `WebRTCAECStage` owns the framing and the lock; per-call output length may differ from input length because sub-frame remainders carry, but cumulative samples out equal samples in, in order.
- A failed frame emits the **raw input**, never half-processed samples. An engine that never came up passes the mic through untouched. Engine failure must never lose mic audio or end a recording.
- `reset()` drops the sub-frame carries (they belong to the pre-reset stream) and re-initializes; re-engaging the engine after a stretch without far-end feed resets first, because the buffered reference no longer lines up with the live mic.

## Modes, and why an HDMI TV breaks the route premise

`EchoModeMachine` maps route → mode: `builtInSpeakers` → `cancelling`, `headphones` → `bypassed`, `unsupported` → `dedupOnly`, and engine failure on a supported route → `degraded` (`EchoHandling.swift`). `SwitchingAECStage.feedsEngine` is true only for `cancelling` and `degraded` — Degraded keeps feeding because the engine already passes raw mic through internally and only detects recovery on continued frames. `bypassed` and `dedupOnly` must be **bit-identical** pass-through, and an idle engine must not accumulate a far-end buffer.

Ambiguity maps to `.unsupported` on purpose, but the classifier's premise — only built-in speakers bleed — is measurably false: an HDMI TV bleeds and classifies `.unsupported`, so every meeting recorded through one carries the teammate's voice on the You channel. That is exactly why the offline path asks the audio instead of trusting a stored mode. At most one degradation notice per episode; no event sequence may stop or fail a recording.
