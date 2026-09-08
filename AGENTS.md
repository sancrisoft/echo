# AGENTS.md

## Project Context

This project is a macOS-only local-first app for meeting transcription and summarization.

The app captures two separate audio sources:

* Microphone audio: the current user.
* System/meeting audio: teammates in the meeting.

The app should transcribe both streams locally, keep the transcript aligned by timestamp, identify the user versus teammates, and generate a useful meeting summary.

Echo is written by AI agents. The skills in `.claude/skills/echo-*` hold what was learned by measuring real calls — read the one that covers what you are about to touch, and see `.claude/README.md` for the setup.

## Main Goal

The goal is to create a native macOS app that turns meetings into structured notes.

The final output should include:

* A readable transcript.
* One Markdown document of notes, shaped to fit the meeting: an Action Items checklist first when commitments were actually made, then a section per topic discussed, and generic sections (key decisions, open questions, risks or blockers) only where the transcript earns them. Never an empty section or a "(none)" placeholder.

The fixed schema this list used to prescribe — a short summary, a detailed summary, then one array per category — is retired. Those fields survive in `MeetingSummary` only so summaries written before the change still decode.

## Technical Direction

Use a native macOS stack. This is what the code uses today, not a plan:

```txt
Swift / SwiftUI
AVFoundation / AVAudioEngine (microphone capture, audio files)
Core Audio process taps (system audio capture)
Vendored WebRTC audio processing (echo cancellation)
FluidAudio / Parakeet TDT 0.6B v3 (speech-to-text)
MLX / mlx-swift-lm (summarization)
Plain files on disk (storage)
```

Microphone capture is `AVAudioEngine` (`Echo/MicrophoneCapture.swift`).

System audio comes from Core Audio process taps, deliberately not ScreenCaptureKit (`Echo/SystemAudioCapture.swift`): a tap does not start a screen recording, so there is no purple indicator and protected playback keeps working. A recording started from the call island narrows the tap to that app's own processes where macOS allows it, and falls back to the global shape where it does not.

Speech-to-text is `parakeet-tdt-0.6b-v3` through FluidAudio (`Echo/ParakeetPass.swift`, `Echo/ParakeetModelManager.swift`). It runs once after the meeting stops, over the retained per-channel audio; there is no live transcript. If quality disappoints, the model choice is what changes — never a compensating heuristic below the pass.

There is no diarization anywhere. `Speaker` is derived from the capture channel (`Echo/TranscriptModels.swift`), which is what makes the assumption below a fact instead of a guess.

Summaries run a local LLM in-process through MLX (`Echo/MLXTextEngine.swift`, `Echo/SummaryModelManager.swift`). The weights load when needed and are released after a short idle.

Echo cancellation is a vendored WebRTC audio-processing library behind an ObjC++ bridge (`Echo/AEC/`), taking the meeting's playback out of the microphone track.

Storage is plain files under `~/Library/Application Support/Echo`, one folder per meeting. No UserDefaults, and nothing written outside that folder.

Tests are hosted in `Echo.app` and share its data folder, so never run them while a real Echo is recording. The suites that replay real audio need fixtures that are not in the repository and skip without them; recording your own is documented in `Fixtures/README.md`.

## Core Product Assumption

The app should keep microphone audio and system audio separate.

```txt
Microphone audio = User
System audio = Teammates
```

This is important because the app should not rely only on diarization to know who is speaking.

## Local-First Principle

The app should be local-first by default.

Audio, transcripts, and summaries should stay on the user's device unless an explicit external provider is added later.

## Summary Behavior

The summary should be grounded in the transcript.

Do not invent:

* Decisions.
* Action item owners.
* Due dates.
* Risks.

If an owner or due date is unclear, leave it empty/null.

## Product Principle

This is not just a transcription app.

The app should help the user quickly understand:

* What was discussed.
* What was decided.
* What needs to happen next.
* What is still unclear.
* What may block progress.
