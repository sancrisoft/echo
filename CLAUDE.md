# CLAUDE.md — working in Echo v2

This file is the operating manual for this repository. Read it before changing
anything. When it disagrees with code, the code is a bug or this file is stale;
fix one and say which.

## What Echo is

A macOS menu bar app (Apple Silicon, macOS 15.6+) that records a meeting from
any app, transcribes it on-device after the meeting ends, and writes a Markdown
summary grounded in the transcript. Two audio streams are kept apart for the
whole pipeline: **microphone = You, system audio = Others**. Speaker attribution
is the channel, never diarization. Everything stays on the Mac under one data
folder, `~/Library/Application Support/Echo`, which v1 and v2 share unchanged.

The v2 rebuild lives on this branch. The shipping PoC (v1) lives on `main`; read
its code with `git fetch origin main && git show origin/main:Echo/<File>.swift`
when porting, never copy it blindly. Always the remote ref, never the local
`main`: `git show` resolves a ref offline, so a local `main` left a few commits
behind hands you stale sources and says nothing — you find out when the port
disagrees with production. `docs/architecture/v2-discovery.md` §7 lists the
behaviors and measured constants a port must preserve, with their reasons.

## Repository map

```
App/                 composition root + scenes. Nothing else.
  EchoApp.swift        scenes: menu bar item, main window, ⌘, command
  AppComposition.swift builds every long-lived object; start() runs all launch side effects
  ActivationPolicy.swift · WindowOpener.swift · MenuBarMenu.swift · WindowSnapshot.swift (DEBUG)
AppTests/            hosted tests only for what needs the real app (TestHost tripwire)
Packages/<Name>/     one local Swift package per capability
  Package.swift
  Sources/<Name>/    flat: one file per concept
  Tests/<Name>Tests/
Packages/Audio/
  Sources/WebRTCAECBridge/   the one ObjC++ seam over the AEC (SPM has no
                             bridging header), public header in include/
  Vendor/                    WebRTCAPM.xcframework (the binary target) plus
                             webrtc-apm/{VERSION,licenses}; VERSION says how
                             the xcframework is regenerated
Packages/DesignSystem/
  Sources/DesignSystem/Resources/Fonts/   the two typefaces (OFL) plus their
                             licence texts; they ship inside Echo.app
  Vendor/fonts/VERSION       where each font came from, its hash, how to refresh
docs/architecture/   v2-discovery.md · v2-architecture.md · adr/
docs/design/         local only (gitignored): the redesign as a written spec
.design/             local only (gitignored): the design canvas working copy
scripts/             check_boundaries.sh · snapshot.sh · install.sh
Fixtures/            real recordings, local-only (gitignored except README.md)
Makefile             the commands
```

### Packages and what they own

| Package | Owns | May depend on |
|---|---|---|
| `EchoCore` | `TranscriptSegment`/`Speaker`/`AudioChannel`, `TranscriptUtterance`, `DataRoot`, `ErrorTrace`, `AppSettings`, `LaunchEnvironment`, `TestHost`, `AppIdentity`; `EchoCoreTestSupport` (fixtures root, `.acceptance` trait, `TemporaryDirectory`) | — |
| `Meetings` | `MeetingStore` (the only thing that touches `Meetings/`), `MeetingLibrary`, `MeetingMeta`/`MeetingRecord`, `LegacyMeetingSummary`, `StorageBreakdown`, `MeetingExport`, `MeetingListSelection` | EchoCore |
| `DesignSystem` | `EchoColor` (+ `EchoColor.Island`), `EchoFont` (the scale over the bundled Onest and DM Mono, and their launch-time registration), `EchoSpacing`/`EchoRadius`/`EchoLayout`/`EchoControl`, the window's primitives (`EchoButtonStyle`, `StatusBadge`, `PropertyRow`, `TabStrip`, `MetaStrip`, `EmptyState`, `SelectableRowChrome`) and the island's (`IslandButtonStyle`, `IslandIconButtonStyle`, `ValueChip`, `LevelGauge`), `DesignGallery` | — |
| `Workspace` | the main window: `WorkspaceWindow`, `WorkspaceModel`, sidebar, document, trash, settings screen, `MarkdownDocument`/`MarkdownView`, `MeetingGrouping`, `MeetingStatus`, `MeetingActions` (panels, pasteboard, Finder) | EchoCore, Meetings, Recording, ModelDelivery, Updates, CallDetection, DesignSystem |
| `Audio` | `MicrophoneCapture`/`SystemAudioCapture` (`Sendable` classes, callbacks at init), `AudioConstants`/`AudioLevelMeter`/`AudioDownmixer`/`BufferResampler`, `CaptureRateGuard`, `CaptureGapTracker`, `CaptureScope`/`ProcessSelector`/`ScopedProcessResolution`, `AppBundleIdentity`, `RetainedAudioWriter` (actor, file naming injected), `AECStage`/`PassthroughAECStage`/`WebRTCAECStage`/`SwitchingAECStage`, `OutputRouteClass`/`EchoHandlingMode`/`EchoModeMachine`/`EchoDegradationNotice`, `EchoBleedProbe`, `InputDeviceMonitor`/`InputDeviceLifecycleMachine`/`InputDeviceNotice`, `OutputRouteMonitor`/`OutputRouteClassifier`, `InputHealthClassifier`/`InputHealthTracker`/`InputHealthNotice`/`FanOutGateDiagnosticsSink`, `GateTerm`/`GateVerdict`/`GateDecisionRecord`/`GateDiagnosticsSink`, `LiveInputMonitor`/`AudioStats`, `FixtureRecorder` (DEBUG); vendored WebRTC APM | EchoCore |
| `ModelDelivery` | `SnapshotDownloader`/`SnapshotSpec`, `ResumableFileDownload`, `DownloadProgress` (the one clamp), `DownloadRetry`, `SnapshotDownloadTally`/`SnapshotDownloadBudget`, `SnapshotManifest`, `DownloadPauseStore`, `RetiredModelCleanup`, `DiskSpace` | EchoCore, swift-transformers (`Hub`) |
| `Transcription` | `ParakeetModel` (identity, readiness, download), `TranscriptionPass` (the post-stop batch pass, segment shaping, `spanLevels`), `EnergyEnvelope`, `PassProgress`, `PassEvent`, `TranscriptionError`, `EchoDedupPolicy` | EchoCore, ModelDelivery, FluidAudio |
| `Summarization` | `TextGenerating`/`GenerationParams` (the engine seam and its presets), `Summarizer` (routing, prompts, NDJSON facts, caption), `SummaryDocument`/`SummaryPhase`, `SummaryFacts` (`ChunkMapResult`/`MergedFacts`/`SummaryMerge`), `NDJSONLineValidator`, `TranscriptChunking`, `MLXTextEngine`, `SummaryModel` (identity, state, download/pause/load/unload), `SummarizationError`/`SummaryModelError` | EchoCore, ModelDelivery, mlx-swift-lm, mlx-swift, swift-transformers (`Tokenizers`) |
| `Recording` | `RecordingSession` (`@Observable @MainActor`: `phase`, `levels`, `notices`, `currentMeetingID`, `queuedMeetingIDs`, `terminalFailureMeetingIDs`, `start`/`stop`, `retryTranscription`/`retranscribe`/`requestSummary`, `resumePendingFinalizations`/`kickSummaryBackfill`), `RecordingPhase`, `RecordingNotice`, `CaptureLevels`, `FinalizationMachine`, `SummaryBackfillPolicy`; internally `FinalizationDriver`, `SummaryScheduler`, `LevelWindow`/`ChannelFrameCounter`, the `CaptureScope` → `CaptureScopeRecord` mapping, and the capture/pass/summary seams the tests drive | EchoCore, Audio, Transcription, Summarization, ModelDelivery, Meetings |
| `CallDetection` *(pending)* | mic-activity monitor, catalogs, `CallSessionMachine` | EchoCore, Audio |
| `Updates` *(pending)* | release feed, checker, updater | EchoCore |
| `Island` *(pending)* | the floating panel and its controller | EchoCore, CallDetection, Recording, DesignSystem |

The dependency table above is enforced by `scripts/check_boundaries.sh`; the
rationale is in `docs/architecture/v2-architecture.md` §2 and ADR-001.

## Dependency direction

`App → UI packages (Workspace, Island) → Recording → engine packages → EchoCore`.
`DesignSystem` is a leaf UI packages import. Downward only; no cycles; UI
packages never import each other. Engine packages never import SwiftUI, and
AppKit only for process identity in files the boundary script allowlists.

`App` also imports, directly, any engine package whose launch side effect it
owns — today `ModelDelivery`, for the retired-model cleanup. That is the
arrow above, not an exception to it: the composition root is where launch
work lives (architecture §6). What it may not do is link a package it does
not itself call; everything Recording pulls in resolves through Recording's
own manifest.

## Finding code

- Ask "who owns this?" and open that package's `Sources/` folder. Files are
  named after the concept they hold (`MeetingStore.swift`, `WorkspaceModel.swift`).
- `grep -rn "public " Packages/<Name>/Sources` shows a package's API.
- Side effects: disk is in `MeetingStore` (meetings), `RetainedAudioWriter`
  (a session's staged audio), `SnapshotDownloader`/`ResumableFileDownload`
  (model files) and `ErrorTraceLog` (logs); the network is in `ModelDelivery`
  alone; audio devices are in `Audio`; the pasteboard, save panels and Finder
  are in `Workspace/MeetingActions.swift`; launch-time work is in
  `App/AppComposition.swift` — nowhere else.
- Every `ECHO_*` environment variable is a property of
  `EchoCore/LaunchEnvironment.swift`. No other file reads the environment.
- Persisted preferences are the properties of `EchoCore/AppSettings.swift`.

## Design

The v2 UI is being brought, surface by surface, to a redesign that is internal
to the company and is **not in the repository**. On a team machine it exists in
two gitignored places: `docs/design/README.md`, the written spec (palette and
type with exact values and the tokens they map to, the window layout, the
document and transcript, light mode, every island state with sizes, motion and
controls, the open decisions, and a map of what each surface still lacks), and
`.design/`, the working copy of the design canvas it was read from. Ask the
team for the canvas link if neither is present.

Rules for any visual change:
- Read the spec (or the canvas) before writing a view. If neither is
  available, stop and ask; never guess a size, color, copy or state, and never
  invent a screen the design does not draw — the `EmptyState` primitive is the
  fallback for undrawn states.
- Values go through `DesignSystem` tokens. A literal in a view is a missing
  token; add it with the design's name.
- Verify by rendering (`scripts/snapshot.sh`, both appearances) and compare
  with the design.
- Design decisions the spec marks as open are not resolved in code.
- Never commit `.design/`, `docs/design/`, exports of the canvas, or design
  details (values, copy, screenshots of the canvas) into tracked files or
  commit messages. Token values in `DesignSystem` are the exception: the app
  cannot be built without them.

## Adding or changing things

**A new feature** goes in the package that owns the capability. If none owns it
and it is a real capability (its own tests, its own external dependency or side
effect, several files), create a package — see below. Never a `Utils`, `Shared`,
`Helpers` or `Models` package.

**Modifying a feature**: change the package, run `make test-package P=<Name>`,
then `make lint`. If the change alters a public API, update every consumer in
the same commit and the table in `docs/architecture/v2-architecture.md` §3.

**A new package**:
1. `Packages/<Name>/Package.swift` copied from a neighbor: `swift-tools-version: 6.2`,
   `platforms: [.macOS("15.6")]`, `.swiftLanguageMode(.v6)`, one library product
   named like the package, one test target `<Name>Tests`. UI packages add
   `.defaultIsolation(MainActor.self)` to both targets; engine packages do not.
2. Dependencies only from the table above; add the package to
   `allowed_deps()` in `scripts/check_boundaries.sh` and to §2 of the
   architecture document.
3. Link it from `Echo.xcodeproj/project.pbxproj` only if `App` imports it
   directly (an `XCLocalSwiftPackageReference` plus an
   `XCSwiftPackageProductDependency` on the `Echo` target — copy an existing
   pair and give it fresh 24-hex ids).
4. Tests from the start; the first commit of a package includes them.

**Shared code**: something enters `EchoCore` only when at least three packages
need it, it has no UI, and it is not a capability of its own. Two packages using
the same helper is not a reason; duplicate it or move it to the one that owns
it. `DesignSystem` receives a component when two surfaces repeat it.

**Structure inside a package**: flat. Add a folder only when the flat listing
stops helping navigation, and name it after what it holds — never
`Models/Views/Services/Domain/Infrastructure`.

## State

One owner per kind of state; nothing is mirrored (ADR-003).

- Preferences → `AppSettings` (`settings.json`, decoded key by key, additive).
- Library → `MeetingLibrary` (disk is the truth; `refresh()` only reads).
- Window navigation → `WorkspaceModel` (section, selection, tab, search, sort).
- Session, models, detection, updates → their packages' observables (pending).
- Transient UI (hover, dialogs, focus) → `@State` in the view.
- Derived status → a pure resolver (`MeetingStatus.resolve`), never stored.

`@Observable` classes are created in `AppComposition` and injected with
`.environment(_:)`. Views read what they render inside `body`; cross-object
reactions are method calls by the object that knows, not observation chains.

## Data access

- Everything on disk is under `DataRoot` (`EchoCore/DataRoot.swift`). No
  accessor creates a directory; the package that owns a subtree does.
- `MeetingStore` is the only reader and writer of `Meetings/`. Writes are
  atomic and ordered (transcript, summary, `meta.json` last); deletions are
  named files, never sweeps; schemas are additive with tolerant decoding and an
  old `meta.json` must stay byte-identical after a read (ADR-005).
- No `UserDefaults`. No `~/Documents`. No caches outside the data root.
- Network exists only in `ModelDelivery` and `Updates` (pending), each owning
  its client. Nothing else makes requests.

## Errors

- Per-package error enums, `LocalizedError` when the text can reach a user.
- Three tiers: subordinate side effects disable themselves and trace; expected
  failures become state on the owning observable (`.failed(message)`, a
  notice); unexpected failures are traced and shown as a generic failed state.
- `ErrorTrace.record(message, error:, category:, metadata:)` is the only way an
  error is logged (unified log + NDJSON under `Logs/`). No `print`, no empty
  `catch`. Transcript text never goes into a log.

## Concurrency

- Swift 6 language mode everywhere. UI packages and `App` default to the main
  actor; engine packages state isolation explicitly (ADR-002).
- Resources with serialized access are `actor`s (`MeetingStore`, `ErrorTraceLog`).
  Observable façades the UI reads are `@MainActor`. Pure value types are
  neither. Token enums in `DesignSystem` are `nonisolated` so pure renderers can
  use them.
- Locks only on real-time audio paths where an actor hop is unacceptable, each
  with a comment naming the threads. No `Task.detached` except launch-time
  cleanups and utility measurements the composition root or a library owns.
- Known toolchain trap (Swift 6.3.3): passing an isolated method reference as a
  `Binding` setter crashes the compiler in IRGen; wrap it in a closure.

## Configuration

- `DataRoot.standard` or `ECHO_DATA_ROOT` (DEBUG) via `LaunchEnvironment`.
- `AppIdentity` for the bundle id, log subsystem and version.
- Model identifiers are `static let` contracts in their packages.
- Measured constants stay next to the code they tune with the comment that
  records the measurement. Changing one requires a new measurement, not an
  opinion.
- No secrets exist; anything that looks like a token fails the boundary check.

## Testing

- Swift Testing only. Package tests run with `swift test`, no host app; they
  use `TemporaryDirectory` for every path and never touch the real data folder
  (`ErrorTrace` writes nothing until the app configures it).
- `AppTests` is hosted in `Echo.app` and exists only for what needs the host.
  Inits never perform side effects; `AppComposition.start()` is the one door
  and checks `TestHost.isActive` once (ADR-004).
- Acceptance suites (real models, real recordings) carry `.acceptance` and skip
  unless `ECHO_ACCEPTANCE=1`; fixtures live in `Fixtures/` (see its README).
- A port brings the PoC's tests with it and they must pass with only import and
  API changes. No sleeps for timing, no wall-clock assertions, no writes into
  the source tree.

## Commands

```sh
make build                    # Debug Echo.app into build/
make run                      # build and launch
make test                     # every package + hosted AppTests
make test-package P=Meetings
make lint                     # swift-format --strict + scripts/check_boundaries.sh
make format
scripts/snapshot.sh [scene…]  # render library|summary|transcript|trash|settings to build/snapshots/
ECHO_DATA_ROOT=/tmp/x ECHO_OPEN_WINDOW=1 build/Build/Products/Debug/Echo.app/Contents/MacOS/Echo
```

CI (`.github/workflows/ci.yml`) runs lint, package tests and the hosted tests
on pull requests and on pushes to `main` and `v2`.

## Conventions

- Commits: Conventional Commits with the package or area as scope
  (`feat(meetings): …`, `test(core): …`, `docs(v2): …`); small and semantic;
  the body says why.
- Public API is `public` and small; everything else `internal`; tests use
  `@testable import` only when they must.
- Comments explain why, not what. A measured constant carries its measurement.
- English in code, comments, docs and UI copy.
- Formatting is `swift format` with the repo's `.swift-format`; run
  `make format` before committing.

## Forbidden

- Importing SwiftUI/AppKit in an engine package (allowlist aside), importing a
  UI package from another UI package, importing `App` from anywhere.
- A second source of truth for anything an owner already holds; a view that
  owns selection; a controller that exposes its sub-objects for views to reach
  through (`controller.library.storage…`).
- `UserDefaults`, `print`, `ProcessInfo.processInfo.environment` outside
  `LaunchEnvironment`, `catch {}` without a trace, `try!`, force unwraps.
- Side effects in initializers; work in `body` beyond deriving what to draw;
  sleeping in tests; writing into the source tree from a test.
- Layer folders (`Domain/`, `Infrastructure/`, `ViewModels/`), `*Manager`,
  `*Coordinator`, `*Repository` types created for symmetry rather than need.
- Changing a measured constant or a defended behavior without a new
  measurement; "improving" a port in passing.
- Debug harnesses inside views; a new `ECHO_*` variable read anywhere but
  `LaunchEnvironment`.
- Inventing UI the design does not draw, or a color/size/copy that is not in
  the design spec.
- Committing `.design/`, `docs/design/`, or any export or detail of the design.

## Decisions to know

ADR-001 packages as boundaries · ADR-002 Swift 6 and explicit isolation ·
ADR-003 one owner per state, one session facade · ADR-004 tests without a host
· ADR-005 the v1 data folder, no migration · ADR-006 port the measured engine,
rewrite orchestration and UI. All under `docs/architecture/adr/`.

Product rules that override convenience: never invent a decision, an owner, a
due date or a risk in a summary; never show a live transcript or a
transcript-derived number while recording; never fake a level, a percentage or
a progress bar; nothing records without an explicit click; audio, transcripts
and notes never leave the Mac.
