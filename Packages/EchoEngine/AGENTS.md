# EchoEngine

Headless. Everything Echo does that is not on screen.

## The rule

The engine never imports `SwiftUI`, `AppKit`, `Cocoa` or any `EchoUI` module. It
does not know a user interface exists. `Tests/EchoEngineTests/BoundaryTests.swift`
scans `Sources/` and fails with the file and line if you break this.

If a module needs something from the screen — a selection, a setting, a
cancellation — take it as a parameter or expose state for the UI to read. Never
reach for it.

Targets are `nonisolated` by default. Declare `@MainActor`, an actor, or
`Sendable` on the type that needs it; do not set default isolation in
`Package.swift`.

## Modules

| target | owns | depends on |
|---|---|---|
| `EchoCore` | value types, errors, clock and paths every module shares | — |
| `CWebRTCAPM` | the C seam over the vendored WebRTC audio-processing library | `WebRTCAPM` |
| `EchoAudio` | capture of the two streams, mixing, levels, echo cancellation | `EchoCore`, `CWebRTCAPM` |
| `EchoModelDelivery` | downloading, caching, loading and retiring on-device models | `EchoCore` |
| `EchoTranscription` | retained audio to an aligned, deduplicated transcript | `EchoCore`, `EchoModelDelivery` |
| `EchoSummarization` | transcript to the summary sections, grounded in what was said | `EchoCore`, `EchoModelDelivery` |
| `EchoPersistence` | the on-disk meeting store: layout, reads, writes, retention | `EchoCore` |
| `EchoCallDetection` | noticing a call started or ended | `EchoCore` |
| `EchoRecording` | the only orchestrator: capture to transcript to summary to store | the five above |

`WebRTCAPM` is a `.binaryTarget` on `Vendor/WebRTCAPM.xcframework`.
`Vendor/VERSION` records what it is and how it was built.

## Where new code goes

- A type only one module uses lives in that module.
- A type two modules pass between them goes to `EchoCore`. Do not add a
  dependency edge to the table above to avoid moving a type down.
- Sequencing across modules belongs in `EchoRecording`. No other module drives
  another module's work.
- A new third-party dependency arrives with the port that needs it, declared on
  the one target that uses it — not on the package.
- No `.unsafeFlags`.

Add a module only when it owns a distinct part of the pipeline. New target:
`.swiftLanguageMode(.v6)`, a row in the table, and its name in the `EchoEngine`
product and the test target's dependencies.
