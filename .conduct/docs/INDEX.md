# Echo — Docs Index

[Glossary](GLOSSARY.md)

## Features

| #                                                    | Name                                  | Status |
| ---------------------------------------------------- | ------------------------------------- | ------ |
| [SP-001](specs/SP-001-mic-echo-cancellation.md)      | Mic Echo Cancellation (Speaker Bleed) | Approved |
| [SP-002](specs/SP-002-external-input-device-support.md) | External Input Device Support (Transcription Dropout) | Approved |
| [SP-003](specs/SP-003-model-download-recording-readiness.md) | Model Download & Recording Readiness | Draft |
| [SP-004](specs/SP-004-summary-model-downsize.md) | Summary Model Downsize (Gemma 4 12B → Qwen3.5 4B) | Draft |
| [SP-005](specs/SP-005-transcript-accuracy.md) | Transcript Accuracy: Final Re-transcription Pass | Draft |
| [SP-006](specs/SP-006-call-detection-island.md) | Call Detection Island: Automatic Start/Stop Recording Prompts ([implementation plan](specs/SP-006-implementation-plan.md)) | Draft |
| [SP-007](specs/SP-007-final-transcript-quality-v2.md) | Final Transcript Quality v2 & Final-Only Transcript UX | Draft |

## ADRs

| #                                                            | Title                                                                    | Status   |
| ------------------------------------------------------------ | ------------------------------------------------------------------------ | -------- |
| [ADR-001](adrs/ADR-001-webrtc-aec3-engine.md)                 | Vendor WebRTC audio-processing (AEC3) as the echo-cancellation engine     | Accepted |
| [ADR-002](adrs/ADR-002-aec-at-16khz-post-resample.md)         | Run AEC at 16 kHz mono on 10 ms frames, after per-stream downmix/resample | Accepted |
| [ADR-003](adrs/ADR-003-asymmetric-keep-on-doubt-dedup.md)     | Asymmetric, timing-gated, keep-on-doubt transcript deduplication          | Accepted |
| [ADR-004](adrs/ADR-004-max-magnitude-downmix.md)              | Downmix multi-channel input by per-sample max-magnitude selection         | Accepted |
| [ADR-005](adrs/ADR-005-mic-level-handling-post-aec.md)        | Constrain any mic-path level handling to post-AEC, pre-gate placement     | Accepted |
| [ADR-006](adrs/ADR-006-input-health-separate-from-mode-machine.md) | Keep input-health classification separate from the echo-handling mode machine | Accepted |
| [ADR-007](adrs/ADR-007-honest-download-progress.md)          | Honest download progress from a single fraction source                    | Accepted |
| [ADR-008](adrs/ADR-008-summary-model-memory-lifecycle.md)    | Summary-model memory lifecycle: lazy load, idle-timeout release           | Accepted |
| [ADR-009](adrs/ADR-009-recording-readiness-gate.md)          | Recording-readiness gate keys on load completion, not disk presence       | Accepted |
| [ADR-010](adrs/ADR-010-turn-template-ownership.md)           | Echo owns the summary model's turn template in code                       | Accepted |
| [ADR-011](adrs/ADR-011-retired-model-cleanup.md)             | Retired-model cleanup: delete at first launch, scoped, non-fatal          | Accepted |
| [ADR-012](adrs/ADR-012-manifest-derived-snapshot-completeness.md) | Snapshot completeness derives from the repo's manifest, not a hardcoded layout | Accepted |
| [ADR-013](adrs/ADR-013-temporary-audio-retention-for-final-pass.md) | Temporary compressed audio retention is the finalization mechanism | Accepted — deletion-on-convergence amended by ADR-024 |
| [ADR-014](adrs/ADR-014-serial-heavyweight-model-admission.md) | One heavyweight model at a time — serial post-meeting admission, recording preempts | Accepted |
| [ADR-015](adrs/ADR-015-final-pass-model-ram-tiering.md) | Final-pass model selected by RAM tier, with the live model as graceful floor | Accepted |
| [ADR-016](adrs/ADR-016-live-transcript-floor-atomic-replace.md) | Live transcript is the floor; atomic replace; retained audio marks pending finalization | Accepted — converged-failure clause superseded by ADR-024 |
| [ADR-017](adrs/ADR-017-call-detection-via-process-mic-use.md) | Detect calls by per-process mic use (Core Audio process objects) against a curated app catalog | Accepted |
| [ADR-018](adrs/ADR-018-notch-island-nonactivating-panel.md) | Call prompts render in an in-app notch island (non-activating NSPanel), not system notifications | Accepted |
| [ADR-019](adrs/ADR-019-final-pass-discard-over-keep.md) | The final pass discards decode output that lacks evidence — an honest gap beats hallucinated text | Accepted |
| [ADR-020](adrs/ADR-020-voiced-evidence-language-decisions.md) | Final-pass language decided per window on voiced evidence, alternate-language re-decode as backstop | Accepted |
| [ADR-021](adrs/ADR-021-derived-utterance-merge.md) | Utterance merging and backchannel filtering are derived views — persisted transcript stays segment-level | Accepted |
| [ADR-022](adrs/ADR-022-transcript-provenance-in-meta.md) | Meeting provenance recorded in meta.json — display-only, with one sanctioned scheduling bit (ADR-024) | Accepted |
| [ADR-023](adrs/ADR-023-speaker-plain-string-tolerant-decoding.md) | Speaker persists as a plain string with tolerant decoding; schema evolves additively | Accepted |
| [ADR-024](adrs/ADR-024-terminal-draft-keeps-audio-manual-retry.md) | Terminal finalization failure keeps the retained audio and offers a manual Retry | Accepted |

## Brainstorms

| #                                                       | Name                                   | Status |
| ------------------------------------------------------- | -------------------------------------- | ------ |
| [BRN-001](brainstorms/BRN-001-mic-echo-cancellation.md) | Mic Echo Cancellation (Speaker Bleed)  | Ready  |
| [BRN-002](brainstorms/BRN-002-external-input-device-support.md) | External Input Device Support (Transcription Dropout) | Ready  |
| [BRN-003](brainstorms/BRN-003-model-download-recording-readiness.md) | Model Download & Recording Readiness | Ready  |
| [BRN-004](brainstorms/BRN-004-transcript-accuracy.md) | Transcript Accuracy Improvement | Ready  |
