# AGENTS.md

## Project Context

This project is a macOS-only local-first app for meeting transcription and summarization.

The app captures two separate audio sources:

* Microphone audio: the current user.
* System/meeting audio: teammates in the meeting.

The app should transcribe both streams locally, keep the transcript aligned by timestamp, identify the user versus teammates, and generate a useful meeting summary.

## Main Goal

The goal is to create a native macOS app that turns meetings into structured notes.

The final output should include:

* A readable transcript.
* A short summary.
* A detailed summary.
* Decisions.
* Action items.
* Open questions.
* Risks or blockers.

## Technical Direction

Use a native macOS stack:

```txt
Swift / SwiftUI
WhisperKit
SpeakerKit
ScreenCaptureKit
AVFoundation / AVAudioEngine
Local storage
```

WhisperKit should be used for local speech-to-text.

SpeakerKit should be used for speaker diarization, mainly on the system/meeting audio stream.

ScreenCaptureKit should be used for capturing system/meeting audio.

AVFoundation / AVAudioEngine should be used for microphone capture.

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
