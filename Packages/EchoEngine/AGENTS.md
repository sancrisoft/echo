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

`EchoTestSupport` is a tenth target, deliberately outside this table and outside
the `EchoEngine` product — it exists for test targets only. See Testing below.

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

## Testing

```sh
swift test --package-path Packages/EchoEngine      # the engine
swift build --package-path Packages/EchoUI         # the UI package still compiles
xcodebuild test -scheme EchoV2 -destination 'platform=macOS,arch=arm64'
```

CI runs all three in the `Build and test v2` job. **Never run
`xcodebuild test -scheme Echo`** — that hosts v1's suite inside the real Echo.app
against the real data folder, which on 2026-08-06 deleted a live meeting's
`meta.json` mid-recording. `xcodebuild build -scheme Echo` is fine.

### Two rules

- **Engine tests are never hosted.** They run under `swift test`, in a process
  with no app, which is the reason the package split exists. A test that needs an
  app to exist is not an engine test — it belongs in `EchoV2Tests`.
- **v2 must not read or write `~/Library/Application Support/Echo`** until the
  rewrite is finished. That is v1's live data. Not implemented yet: no code
  resolves a data folder so far, and the persistence port must not default to
  sharing this one.

### The test-host guard

`EchoCore.TestHost.isActive` is true when the process is a test runner's host
app. `xcodebuild test` launches the app under test as the host, so every launch
side effect must sit behind it — in v2 they all go through `EchoV2Launch.start()`,
which returns `.skippedForTestHost` and does nothing. It reads false under
`swift test` (SwiftPM loads only `Testing.framework`, no XCTest, no `XCTest*`
environment keys); that is correct, because a package test has no host app to
make inert. `EchoV2Tests` is what pins it to true in the hosted context.

### Fixtures

`Fixtures/` at the **repository root**, resolved from `#filePath` by
`EchoTestSupport.Fixtures` — never from a bundle. It is deliberately outside
every target: `EchoTests/` is a synchronized group that flattens into bundle
Resources, where two scenarios' `mic.wav` collide.

Fixtures are **local-only**: real recorded audio, gitignored, never in the
repository and never on CI. `Fixtures.available(_:)` asks; `Fixtures.require(_:)`
throws a message that says so. Record them per `Fixtures/README.md`.

### The acceptance gate

A suite that downloads a model or replays recorded audio tags itself and skips
with a note instead of failing:

```swift
@Suite(.acceptance) struct SomethingSlow { ... }
```

The two runners do not spell the gate the same way, because `xcodebuild` strips
the `TEST_RUNNER_` prefix before the test process sees the variable:

| runner | opens the gate | does nothing |
|---|---|---|
| `swift test` | `ECHO_ACCEPTANCE=1` | — |
| `xcodebuild test` | `TEST_RUNNER_ECHO_ACCEPTANCE=1` | `ECHO_ACCEPTANCE=1` — never reaches the test process, the suite silently skips |

`Acceptance` accepts both spellings, so the prefixed form also works under
`swift test` and neither invocation is wrong. Hosted targets get the trait by
linking the package's `EchoTestSupport` product; package test targets depend on
the target directly.
