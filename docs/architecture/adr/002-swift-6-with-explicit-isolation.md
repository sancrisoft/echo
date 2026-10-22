# ADR-002 — Swift 6 language mode; isolation explicit in the engine, main-actor by default in the UI

Status: accepted · 2026-09-08

## Context

The PoC compiles in Swift 5 mode with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`.
That default made the capture classes (`MicrophoneCapture`, `SystemAudioCapture`,
the device and route monitors) implicitly `@MainActor` while their closures run on
the AVAudioEngine render thread and on the Core Audio IO queue. Swift 5 accepted
it; the baseline build reports 99 warnings, most of them "this is an error in the
Swift 6 language mode". Pure value types that forgot `nonisolated`
(`TranscriptChunker`, `EchoDedupPolicy`) forced `MainActor.run` hops from actors
to do arithmetic.

## Options

1. Stay in Swift 5 mode and keep the main-actor default everywhere.
2. Swift 6 mode with the main-actor default everywhere, and mark every engine
   type `nonisolated`.
3. Swift 6 mode; UI packages and the app use `defaultIsolation(MainActor.self)`;
   engine packages keep the language default (nonisolated) and state isolation
   explicitly.

## Decision

Option 3.

- Every package: `swift-tools-version: 6.2`, `.swiftLanguageMode(.v6)`.
- `DesignSystem`, `Workspace`, `Island`, `App`: `.defaultIsolation(MainActor.self)`.
  Views and their models are main-actor unless they say otherwise.
- Engine packages: no default isolation. Resources with serialized access are
  `actor`s (`MeetingStore`, `RetainedAudioWriter`, the model managers, the
  summarizer, the error log). Observable façades the UI reads are `@MainActor`
  (`RecordingSession`, `MeetingLibrary`, `CallDetector`, `UpdateChecker`,
  `AppSettings`). Everything else is a value type or a `Sendable` class.
- Audio threads are modeled, not hidden: a capture source is a `Sendable` final
  class with `@Sendable` callbacks; state touched from the render thread or the IO
  queue lives behind a `Mutex` or is confined to that queue, and the confinement
  is upheld (the PoC's "everything mutates on `ioQueue`" was violated by
  `activate()` and `stop()`).
- Locks appear only on real-time paths where an actor hop is not acceptable
  (AEC frame processing, level tallies). Everywhere else, actors.
- Staleness after `await` is checked through one generation token and one
  helper in `RecordingSession`, not repeated inline.

## Consequences

- The ports of the audio classes are not mechanical: they must state where their
  state lives. This is the work the Swift 6 diagnostics are for.
- No `@unchecked Sendable` without a comment naming the lock and the threads.
- UI code stays as simple as the PoC's: no isolation annotations in views.
- A future toolchain change to the default-isolation setting is a one-line
  `Package.swift` edit per package, not a code migration.
