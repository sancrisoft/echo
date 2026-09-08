---
name: echo-transcription
description: How Echo turns retained audio into the aligned transcript — `ParakeetPass`, `TranscriptDedup`/`EchoDedupPolicy`, `TranscriptUtterance`, `TranscriptSegment`, segment shaping and the silence cutter, `transcript.json`, what `speaker` means, and symptoms like shredded mid-word rows, bleed on the You channel, or a Spanish meeting transcribed in English.
---

## `speaker` is the channel. There is no diarization.

`Speaker(defaultFor:)` is the product's source of truth: `.microphone` → `.me`, `.system` → `.teammates` (`TranscriptModels.swift:52-58`). Parakeet emits no speaker (`ASRResult` carries text/confidence/duration/tokenTimings/metrics/ctcTerms) and Echo never constructs FluidAudio's `Diarizer`. The channel is the only thing that knows who spoke, and it is the one thing Echo has that a single-stream note-taker does not — do not add diarization to derive it, and do not let a mixed stream in.

Persisted spellings are `"me"` / `"teammates"` (ADR-023) with a tolerant decode falling back to the channel; display names are `"You"` / `"Others"` and are free to change independently.

## One post-meeting pass, no live ASR

`ParakeetPass.run` decodes each retained channel once after the meeting (`parakeet-tdt-0.6b-v3` via FluidAudio, `AsrModels.load`, `encoderPrecision: .int8`). Recording never waits for a model and there is no live transcript. A pass that exhausts retries marks the meeting terminal, keeps its audio, shows Retry, and gets no summary.

Two config flags are load-bearing and both must stay set (`ParakeetPass.swift:395-397`):

```swift
ASRConfig(melChunkContext: false, dualDecodeArbitration: true)
```

`melChunkContext: true` makes the 80 ms mel prepend drift the SOS-primed decoder back to its English prior (FluidAudio #594) — a fully Spanish call came out English in long stretches. `dualDecodeArbitration` removes the batch path's stitching artifacts on heterogeneous-confidence files; measured, English function words on the You channel fell 17% → 10%. It costs 2.3× decode time (documented 1.1-1.5×), accepted.

`language: nil` is deliberate (`ParakeetPass.swift:668-672`). **`language: .spanish` does nothing for es/en** — FluidAudio's `TokenLanguageFilter` partitions by Unicode *script* and both are Latin, so it would reject zero tokens and look like a fix. (A stale comment at that line still calls `.spanish` "the first knob to try"; the longer comment at `:384-387` is the measured truth.)

## Segment shaping: audio decides THAT, tokenization decides WHERE

Segmentation is post-hoc regrouping of already-decoded tokens (`ParakeetPass.swift:579`), so it **cannot change WER** — but it wrecks readability and feeds shredded rows to dedup and the summary.

- `segmentGapSeconds` 0.6 (was 1.0): a segment is the unit of suppression, and a measured 0.7 s pause between the user finishing and the teammate's echo starting was stepped straight over by 1.0, welding real speech to bleed into one indivisible row.
- `silenceSplitSeconds` 0.3 — a silent stretch in the channel's *own* audio also ends a segment, whatever the token timings say. Token timings measurably paper over real pauses (a 0.7 s pause reported as a 0.4 s gap). Boundaries come from `EnergyEnvelope.silenceStarts` at the **START** of the silence, not its midpoint.
- `maxSegmentSeconds` 12.0.
- **Every split must land on `canStartSegment`** — a word start, or punctuation carrying no letter/digit. Consulting `isWordStart` only on the `maxSegmentSeconds` branch cut at whatever token straddled the silence and shredded words: `"bre"|"ak"`, `"Clo"|"jure"`, `"culefalt"|"ón"`. The cut is latched as `pendingCut` and spent at the next legal token (`ParakeetPass.swift:773-792`).
- Leading punctuation shifts **back** onto the previous row (a period is dated after the pause it was spoken before, so 30% of rows opened with `". Clásic te baja..."`), but only while the row keeps a word of its own — a lone `"."` stretched across a long silence IS the whole row, and welding it back would drag the previous span across the silence and lie to the dedup, whose evidence is levels over a span.

## Dedup: asymmetric, keep-on-doubt, energy never deletes alone

`EchoDedupPolicy` suppresses only mic-channel segments that duplicate a Team segment. **Team segments are never touched.** v1 gated on a signed start lag and mutual Jaccard; per-channel segmentation killed both assumptions (lags of **−8.7 s** measured, and a long mic segment dilutes a symmetric score) — result was 8 bleed segments on the fixture, 0 suppressed. Tunables, measured against two real dedupOnly meetings (`TranscriptDedup.swift:32-82`):

- Segments **link by interval overlap**, `[team.start, team.end + echoTailPad]`, `echoTailPad` 2.5 s (the acoustic path itself measured ~124 ms; the pad absorbs per-channel endpointing skew).
- Scored by **directional** containment over pooled linked Team tokens: what fraction of the mic segment's words the teammates already said.
- Tier A: containment ≥ `textOnlyContainment` 0.6, text alone. Tier B: ≥ `assistedContainment` 0.35 **plus** same-window rms ratio ≤ `assistedMaxRmsRatio` 0.5. Text is mandatory in both — energy can never suppress on its own, so a segment whose words are the user's own is structurally undeletable however quiet it is.
- `ownVoiceRescueSeconds` 1.0 runs **ahead of every tier**: 1 s of uninterrupted own-channel dominance keeps the segment whole. 10 of 19 suppressed rows carried 1.1-6.6 s of the user's real speech.
- `minimumTokenCount` 3 (short acks are indistinguishable from echo by text), `fuzzyPrefixLength` 5 (channels decode independently, so endings drift — "escanear"/"escanea").
- Missing evidence reads as "no evidence, keep" (`ParakeetPass.spanLevels` only emits a ratio when **both** channels can answer for the window).

Dedup v2 has a measured cost of its own: on the fixture where the AEC never ran, its whole delta was 17 segments / 112 words, 14 of them the user's — roughly 2.7% own-word loss. It is defence in depth, not free.

## Diagnostic traps

- **Searching for duplicated text to find echo is circular** — select spans acoustically, not textually.
- Decode is **nondeterministic run to run** (±1 token, wording variance). Diff replays by word containment, never equality.
- Attribute a regression by measuring per-channel counts, not by reading diffs: the "worse than yesterday" report was 60% cutter and 40% AEC, and the branch everyone suspected touched neither.
- A transcript "looking better" can mean it is full of bleed duplicated onto the You channel — more fluent text reads as more accurate despite wrong attribution.

## Do not add compensating heuristics

The remaining error class is out-of-vocabulary proper nouns (one name spelled six ways). No config knob reaches it and none should be invented: the model choice is the lever. `transcript.json` stays the record — do not flatten to prose. `TranscriptUtterance.derive` is the Notion-style reading view, derived at render and by the summary pipeline from the same one place, **never persisted**; segments remain the record for dedup, evidence citations, chunking, player alignment and re-transcribe. Backchannel filtering bounds **distinct** words (`maxBackchannelVariety` 3 over `Set(words)`) because repetition is how people acknowledge ("sí sí sí sí sí" is one word spent five times); the table, not the length, is what makes a row safe to drop.
