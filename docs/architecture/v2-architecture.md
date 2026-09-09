# Echo v2 — Architecture

Status: adopted 2026-09-08 for the v2 rebuild; reviewed after the first
feature (`review-2026-09-08-first-feature.md`). Companion documents:
`v2-discovery.md` (what the product is and what the PoC taught us) and the
ADRs under `adr/` (the decisions with real trade-offs).

The principle: **strong boundaries between modules, simple structure within
modules.** Modularity lives at the system level, in local Swift packages the
compiler enforces. Simplicity lives inside each package: flat folders,
descriptive file names, few abstractions.

---

## 1. Repository layout

```
Echo/
├── App/                      the macOS app target: composition, scenes, lifecycle
│   ├── EchoApp.swift         the scenes
│   ├── AppComposition.swift  builds every service, wires them, starts side effects
│   ├── ActivationPolicy.swift · WindowOpener.swift · MenuBarMenu.swift
│   ├── WindowSnapshot.swift  DEBUG: render a scene to a PNG (design review)
│   ├── Info.plist · Echo.entitlements · Assets.xcassets
├── AppTests/                 tests that need the real app as host (few)
├── Packages/                 one local Swift package per capability
│   ├── EchoCore/
│   ├── Audio/
│   ├── Transcription/
│   ├── Summarization/
│   ├── ModelDelivery/
│   ├── Meetings/
│   ├── Recording/
│   ├── CallDetection/
│   ├── Updates/
│   ├── DesignSystem/
│   ├── Workspace/
│   └── Island/
├── Fixtures/                 real recordings and transcripts, local-only (gitignored)
├── docs/
│   └── architecture/         this document, the discovery, adr/
├── scripts/                  install script, dev scripts, boundary check
├── .github/                  CI, installer smoke, release
├── Echo.xcodeproj            the app target + references to the local packages
├── Makefile                  build · test · lint · format · run
├── CLAUDE.md                 how to work in this repository
└── README.md
```

Every package has the same shape:

```
Packages/Meetings/
├── Package.swift
├── Sources/Meetings/         flat: one file per concept
└── Tests/MeetingsTests/
```

Folders inside `Sources/<Package>/` appear only when a package grows past the
point where a flat listing stops helping navigation. They are never created up
front, and they are never the layers `Domain/Application/Infrastructure` or the
roles `Models/Views/ViewModels/Services`.

Packages are created **when their first feature lands**, not ahead of it. The
foundation ships with `EchoCore`, `Meetings`, `DesignSystem`, `Workspace` and
`App`; the rest exist in this document as agreed boundaries and are added by
the ports that fill them (see §11).

---

## 2. Packages and ownership

Each package answers "who owns this?" for one product capability from
`v2-discovery.md` §1.2.

| Package | Owns | Depends on | External |
|---|---|---|---|
| **EchoCore** | The vocabulary every package shares: `TranscriptSegment`, `AudioChannel`, `Speaker`, utterance derivation; the data root and its paths; `ErrorTrace`; `AppSettings` (persisted preferences); `LaunchEnvironment` (debug flags, one reader); `TestHost`; `AppIdentity` (bundle id, log subsystem, version). Plus a `EchoCoreTestSupport` product: fixtures root, acceptance gate, temp roots. | — | — |
| **Audio** | Both capture sources (mic via `AVAudioEngine`, system via Core Audio process taps, global or scoped), the canonical audio format, downmix and resampling, the sample-rate guard, echo cancellation (the vendored WebRTC AEC3 as a binary target plus its one ObjC++ seam, the mode machine, the switching stage), output-route and input-device monitors, input-health classification, capture-gap accounting, retention encoding to AAC, `CaptureScope`/`ProcessSelector`, `AppBundleIdentity`. | EchoCore | WebRTC APM (vendored xcframework) |
| **Transcription** | Parakeet: model identity, readiness and download (through FluidAudio), the post-stop batch pass, energy envelopes, segment shaping, echo dedup. Produces `[TranscriptSegment]` from retained audio files. | EchoCore, ModelDelivery | FluidAudio |
| **Summarization** | Qwen through MLX: the text-generation seam, the model's download/load/unload lifecycle, the pipeline (routing, prompts, streaming, NDJSON facts, deterministic merge), transcript chunking, language detection, the row caption. Produces a Markdown `SummaryDocument`. | EchoCore, ModelDelivery | mlx-swift, mlx-swift-lm, swift-transformers, swift-huggingface |
| **ModelDelivery** | Getting multi-GB models onto disk honestly: resumable transfer, byte-weighted progress, the one progress clamp, stall watchdog and retry, snapshot manifest and completeness, Hugging Face snapshot download, retired-model cleanup, disk-space floor. | EchoCore | swift-huggingface (`Hub`) |
| **Meetings** | The library on disk and in memory: `MeetingStore` (actor, the only thing that touches `Meetings/`), `MeetingMeta`/`MeetingRecord`, the legacy `summary.json` decoder, audio name families and their classification, trash, preserved recordings, storage measurement, `MeetingLibrary` (observable façade), export and copy formatting. | EchoCore | — |
| **Recording** | The meeting lifecycle behind one observable: `RecordingSession` (phase, live levels, notices, current meeting, start/stop/retry), permission priming, wiring Audio into retention and levels, the finalization machine that schedules transcription passes and gates summaries, the summary scheduler and backfill policy. | EchoCore, Audio, Transcription, Summarization, ModelDelivery, Meetings | — |
| **CallDetection** | Which apps are on a call: the mic-activity monitor over Core Audio process metadata, the curated app catalog, the installed-browser catalog, the disabled-apps filter, and `CallSessionMachine` (debounce, grace, faces as pure output). Produces `CaptureScope` values. | EchoCore, Audio | — |
| **Updates** | Version arithmetic, the GitHub release feed, the daily checker, and the updater that hands off to the install script. | EchoCore | — |
| **DesignSystem** | Semantic color tokens for light and dark, the type scale, spacing and radii, and the primitives every surface repeats: buttons, chips, list rows, meta strips, status badges, level meter, empty state. No product logic. | — | — |
| **Workspace** | The main window: sidebar with meetings grouped by date, the document (summary and transcript), trash, the settings screen, first-run banners, search, the Markdown renderer, `WorkspaceModel` (selection, section, search, sort — the window's single navigation truth), display-state resolution. | EchoCore, Meetings, Recording, ModelDelivery, Updates, CallDetection, DesignSystem | — |
| **Island** | The floating panel: `IslandController` (applies `CallSessionMachine` actions to `RecordingSession`, owns timers), the non-activating `NSPanel`, the faces. | EchoCore, CallDetection, Recording, DesignSystem | — |
| **App** (target) | Composition root, scenes, activation policy, the menu bar item, launch tasks gated by `TestHost`. Nothing else. | every package it composes | — |

The UI packages are built towards an internal design that is not in the
repository (see `CLAUDE.md`, "Design"); its written spec is the reference for
every value, state and copy in `DesignSystem`, `Workspace` and `Island`.

### 2.1 Dependency graph

```
                         App
          ┌───────────────┼──────────────┐
      Workspace         Island        Updates
          │  \            │  \
          │   \    CallDetection ── Audio
          │    \          │           │
          │     └──── Recording ──────┤
          │           /   │   \       │
      Meetings ──────┘    │    \      │
          │       Transcription  Summarization
          │            │              │
          │            └── ModelDelivery
          │                     │
          └──────── EchoCore ───┴───────────   DesignSystem (leaf, UI only)
```

Rules the graph encodes:

- **Downward only.** `App → UI packages → Recording → engine packages → EchoCore`.
  No package imports a package above it. No cycles. SwiftPM refuses a cycle; the
  boundary script in `scripts/check_boundaries.sh` refuses `SwiftUI`/`AppKit`
  imports in engine packages and refuses any package importing `App`.
- **Engine packages never import SwiftUI or AppKit.** Engine = EchoCore, Audio,
  Transcription, Summarization, ModelDelivery, Meetings, Recording,
  CallDetection, Updates. (`AppKit` is allowed in exactly two engine files that
  need `NSWorkspace`/`NSRunningApplication` for process identity; the script
  allowlists them by path.)
- **UI packages never touch disk, network, audio or models directly.** They read
  observable state from the engine and call its methods.
- **Sibling engine packages do not import each other** except through the
  explicit edges above (`Transcription`/`Summarization → ModelDelivery`,
  `CallDetection → Audio`). `Meetings` knows nothing about audio capture,
  transcription or summarization: it stores what it is given.
- **EchoCore is an allowlist, not a bucket.** Something enters it only if at
  least three packages need it, it has no UI, and it is not a capability of its
  own. Anything else stays with its owner even if two packages use it.
- **DesignSystem has no dependencies and no product knowledge.** It does not
  know what a meeting is.

### 2.2 Why these twelve and not fewer

- `Meetings` is below `Recording` because the pipeline persists into it; the
  meetings *UI* is above `Recording` because it renders session state. Fusing
  storage and UI into one "Meetings" package would force the cycle
  `Meetings → Recording → Meetings`.
- `ModelDelivery` is its own package because two engines share ~1 000 lines of
  transport, progress and manifest code with their own tests and their own
  external dependency, and because "first run: honest model download" is a
  product surface that spans both models.
- `CallDetection` is separate from `Island` because one is Core Audio process
  metadata and a pure machine, the other is an `NSPanel`; they change for
  different reasons and only the second needs `Recording`.
- `Recording` is a package, not app code, because the orchestration holds the
  most delicate invariants in the product and must be testable with fakes and
  without a host app.
- `Updates` is a package because it has network and process side effects and
  its own tests; in the app target those tests would be hosted.

### 2.3 Why not more

There is no `Networking`, `Persistence`, `Logging`, `Utils` or `Models`
package. Networking exists in exactly two places (`ModelDelivery`, `Updates`)
and each owns its client. Persistence is `Meetings` for meetings and `EchoCore`
for `settings.json`. Logging is `ErrorTrace` in `EchoCore`. There is no shared
"models" package: `TranscriptSegment` is in `EchoCore` because it is the
product's vocabulary; `MeetingMeta` belongs to `Meetings`; `SummaryDocument`
belongs to `Summarization`.

---

## 3. Public APIs between packages

Each package exposes a small `public` surface; everything else is `internal`
(tests use `@testable import`). The surfaces below are the contract; file
names inside a package are free to change.

**EchoCore**
- `TranscriptSegment`, `AudioChannel`, `Speaker`, `TranscriptUtterance.derive(from:)`, `TranscriptSegment.wordCount(of:)`.
- `DataRoot`: `appSupport`, `meetings`, `models`, `logs`, `settingsFile`, `summaryDownloadStateFile`. No accessor creates directories; owners do.
- `ErrorTrace.record(_:error:category:metadata:)`, `ErrorTraceLog` (prune, reader for tests).
- `AppSettings` (`@Observable @MainActor`): typed read-only properties plus one mutator per preference.
- `LaunchEnvironment.current`: typed debug flags (`dataRootOverride`, `opensWindowAtLaunch`, `appearanceOverride`, `snapshotPath`, `snapshotScene`, `keepsRetainedAudio`, `installedVersionOverride`), populated only in DEBUG.
- `TestHost.isActive`.
- `AppIdentity`: `bundleIdentifier`, `logSubsystem`, `version` (`short`, `build`, `display`).

**Audio**
- `AudioFormat.canonical` (16 kHz mono Float32) and buffer helpers.
- `MicrophoneCapture`, `SystemAudioCapture`: `start(...)`, `stop()`, `onSamples`, `onLevel`, `requestPermission()`/`primePermission()`, `DeliveryStats`.
- `CaptureScope` (`.everything` | `.app(ProcessSelector)`), `ProcessSelector` (display name + bundle-ID prefixes + scopeable).
- `EchoCanceller` (the switching stage), `EchoHandlingMode`, `EchoModeMachine`, `OutputRouteMonitor`, `OutputRouteClass`.
- `InputDeviceMonitor`, `InputDeviceLifecycleMachine`, `InputHealthTracker`, `InputHealthNotice`.
- `CaptureGapTracker`, `RetainedAudioWriter`, `AppBundleIdentity`.

**Transcription**
- `ParakeetModel` (actor; `state`, `initialize(deferWhile:)`, `readyModelDirectory()`).
- `TranscriptionPass.run(retainedFiles:model:shouldYield:onProgress:) -> [TranscriptSegment]`, `PassProgress`, `TranscriptionError`.
- `EchoDedupPolicy` (also used by tests and diagnostics).

**Summarization**
- `SummaryModel` (actor; `state`, download/pause/resume, `withEngine`).
- `Summarizer.generate(from:language:) -> AsyncThrowingStream<SummaryDocument, Error>`, `SummaryDocument` (markdown, facts snapshot, model name), `Summarizer.caption(for:)`, `SummarizationError`.

**ModelDelivery**
- `SnapshotDownloader`, `ResumableFileDownload`, `DownloadProgress` (the one clamp), `DownloadRetry.withStallRetry`, `SnapshotManifest`, `RetiredModelCleanup`, `DiskSpace`.

**Meetings**
- `MeetingStore` (actor): `save`, `listMetas`, `loadMeta`, `loadRecord`, `updateMeta`, `delete`, `replaceTranscript`, `recordTerminalProvenance`, `attachSummary(markdown:caption:modelName:to:)`, `removeSummaryArtifacts`, `migrateLegacySummaries`, the audio name families and their classification, adoption, preservation, cloning and deletion.
- `MeetingLibrary` (`@Observable @MainActor`): `metas`, `trashedMetas`, `storage`, `refresh()` (reads only), `foldLegacySummaries()`, `purgeExpiredTrash()`, `backfillWordCounts()`, `loadRecord`, `rename`/`trash`/`restore`/`deletePermanently`/`emptyTrash`, preserved-audio queries and deletions, `measureStorage()`; `store` for the pipeline.
- `MeetingMeta`, `MeetingRecord` (`summaryMarkdown: String?`), `TranscriptProvenance`, `CaptureScopeRecord`, `LegacyMeetingSummary`, `StorageBreakdown.measure`, `MeetingExport` (markdown / plain text / standalone summary), `MeetingListSelection` (pure keyboard rules), `MeetingStoreError`.

**Recording**
- `RecordingSession` (`@Observable @MainActor`): `phase` (`idle` | `recording(startedAt:scope:)` | `stopping` | `finalizing(meetingID:progress:)` | `summarizing(meetingID:)`), `levels`, `notices`, `currentMeetingID`, `start(scope:)`, `stop()`, `retryTranscription(_:)`, `retranscribe(_:)`, `requestSummary(_:)`.
- `FinalizationMachine` (pure; exposed for the display resolver and tests).

**CallDetection**
- `CallDetector` (`@Observable @MainActor`): `appsInCall`, `isEnabled`, `start()`/`stop()`, `onMachineActions`.
- `CallSessionMachine` (pure), `CallApp`, `CallAppCatalog`, `BrowserCatalog`, `CallDetectionTiming`.

**Updates**
- `UpdateChecker` (`@Observable @MainActor`), `ReleaseVersion`, `GitHubReleaseFeed`, `UpdateInstaller`.

**DesignSystem**
- `EchoColor` (semantic tokens for both appearances), `EchoFont` (the scale), `EchoSpacing`, `EchoRadius`, `EchoLayout`, primitives (`EchoButtonStyle` roles, `StatusBadge`, `MetaStrip`/`MetaItem`, `EmptyState`, `SelectableRowChrome`), `DesignGallery` (DEBUG). The token enums are `nonisolated`. A level meter arrives with Recording.

**Workspace**
- `WorkspaceWindow(dataRoot:)` (root view), `WorkspaceModel` (`@Observable @MainActor`: `section`, `selectedMeetingID`, `selectedTrashedID`, `documentTab`, `searchText`, `sortOrder`, the selection rules), `MeetingSortOrder`, `MeetingFilter`, `MeetingDateGroup`, `MeetingStatus.resolve`, `MarkdownDocument.parse`, `MarkdownRendering`, `MarkdownView`.

**Island**
- `IslandController` (`@Observable @MainActor`), `IslandPanel`.

---

## 4. State ownership

One owner per kind of state. Nothing is mirrored.

| State | Owner | Notes |
|---|---|---|
| Session (phase, levels, notices, current meeting) | `RecordingSession` (Recording) | The only truth about a session. Window, island and menu bar all read it. Levels come from real capture only. |
| Library (metas, trash, storage) | `MeetingLibrary` (Meetings) | Disk is the source; the library is a main-actor cache that re-reads after mutations it performs. Reading never writes: trash purge is an explicit `purgeExpiredTrash()` the composition root schedules. |
| Model readiness (per model) | `ParakeetModel`, `SummaryModel` | Each exposes one observable state with one clamped fraction. |
| Detection (apps in call, machine state) | `CallDetector` (CallDetection) | `appsInCall` is derived from the machine's attribution; not a second matcher. |
| Updates | `UpdateChecker` (Updates) | |
| Preferences | `AppSettings` (EchoCore) | `settings.json`, key-by-key decode, additive. Consumers read the property at the moment they act. |
| Launch at login | `SMAppService` (read through Workspace's settings screen) | The OS is the source of truth; never mirrored. |
| Window navigation (section, selection, opened document, tab, search, sort) | `WorkspaceModel` (Workspace) | One object; the PoC's triple-tracked selection and dead `MeetingLibrary.selection` do not return. |
| Island face, deadline | `IslandController` (Island) | Face is the machine's output; the countdown renders the controller's real deadline. |
| Transient UI (hover, confirmation dialogs, focus) | `@State` in the view | |
| Derived (a meeting's display status) | Pure resolver in Workspace over `MeetingMeta` + `RecordingSession` + `FinalizationMachine` state | Computed, never stored. |

Persisted state is exactly: the data root's files. There is no `UserDefaults`.

Observation: `@Observable` classes are created by `AppComposition` and injected
with `.environment(_:)`. Views read what they render inside `body`. Cross-object
reactions (a stop finishing a summary, a setting turning detection off) are
methods called by the owner, not observation chains.

---

## 5. Data flow: from a click to notes

```
click Record (menu bar · window · island)
  → RecordingSession.start(scope:)
      primes permissions (mic, then system) on the first gesture
      builds EchoCanceller, monitors, gap trackers, RetainedAudioWriter (staging dir)
      MicrophoneCapture / SystemAudioCapture callbacks:
         levels  → RecordingSession (main actor)
         samples → EchoCanceller (sync) → RetainedAudioWriter (actor)
click Stop
  → RecordingSession.stop()
      tears capture down in order; writer.finish()
      MeetingStore.save(meta only) ; adoptRetainedAudio → Meetings/<id>/retained-*.m4a
      phase = .finalizing ; returns
  → FinalizationMachine admits the pass (not recording, no summary in flight)
      TranscriptionPass.run(retainedFiles) → [TranscriptSegment]
      MeetingStore.replaceTranscript(+provenance) ; preserve or delete audio
  → if auto-summaries and SummaryModel is on disk
      Summarizer.generate(from:) streams SummaryDocument snapshots
      MeetingStore.attachSummary(markdown, modelName, caption)
      phase = .idle
Workspace observes MeetingLibrary + RecordingSession and renders the truth.
```

Crash at any step: the next launch scans `Meetings/` — retained audio with no
provenance is pending and resumes; `finalPass` provenance with leftover audio is
an orphan and is cleaned; `audio-*` is preserved and untouched.

---

## 6. Concurrency model

Adopted in ADR-002. Swift 6 language mode in every package.

- **UI packages** (`DesignSystem`, `Workspace`, `Island`) and `App` use
  `defaultIsolation(MainActor.self)`. Everything is main-actor unless it says
  otherwise.
- **Engine packages** use the default (nonisolated) and state isolation
  explicitly: `actor` for anything that owns a resource with serialized access
  (`MeetingStore`, `RetainedAudioWriter`, `ParakeetModel`, `SummaryModel`,
  `Summarizer`, `ErrorTraceLog`), `@MainActor` only for the observable façades
  the UI reads (`RecordingSession`, `MeetingLibrary`, `CallDetector`,
  `UpdateChecker`, `AppSettings`), and value types otherwise.
- **Audio threads are first-class.** A capture source is a `Sendable` final
  class whose callbacks are `@Sendable`; state touched from the render thread or
  the IO queue lives behind a lock (`Mutex` from Synchronization) or is confined
  to that queue by construction. The IO-queue invariant is upheld: mutations of
  the tap format and resampler happen on the IO queue, and the main actor reads
  snapshots. No class is implicitly main-actor while running on an audio thread.
- **Hand-offs from audio to actors** batch samples per callback into one task
  per callback with gap + samples together, exactly as measured in the PoC;
  never one task per operation.
- **Cancellation and staleness** are structural: `RecordingSession` holds one
  `sessionGeneration`; every continuation after an `await` checks it once in a
  helper, not eight times inline.
- **No manual locks where an actor works;** locks only on real-time paths where
  an actor hop is not acceptable (AEC frame processing, level tallies).
- **No `Task.detached`** except the launch-time cleanups the composition root
  fires at utility priority, and the summary backfill that must outlive a window.

---

## 7. Error handling

Adopted conventions, not a framework:

- Every package defines its own error enums (`CaptureError`,
  `TranscriptionError`, `SummarizationError`, `ModelDeliveryError`,
  `MeetingStoreError`, `UpdateError`), `LocalizedError` where the text can reach
  a user.
- **Three tiers, decided per site:**
  1. *Subordinate side effects* (retention, diagnostics, caches) never fail the
     operation they attach to: they disable themselves, trace, and continue.
  2. *Expected failures* become state on the owning observable
     (`SummaryModel.state = .failed(message)`, `RecordingSession.notices`), with
     copy the UI can show and an action where one exists (Retry, Resume).
  3. *Unexpected failures* are traced with `ErrorTrace.record` and surface as a
     generic failed state; they never crash the app and never print.
- `ErrorTrace.record(message, error:, category:, metadata:)` is the only way an
  error is logged. It mirrors to `os.Logger` (one subsystem, one category per
  file) and appends NDJSON under `Logs/`. `catch { print(error) }` and empty
  `catch {}` do not exist in v2.
- Errors that carry user data (transcript text) never reach the log; only the
  diagnostics sink a test explicitly passes.
- Progress and completion are never inferred from an error: pause is a state
  recorded before cancellation, not a `CancellationError` read back.

---

## 8. Configuration

- **Paths**: `EchoCore.DataRoot`. One root, `~/Library/Application Support/Echo`,
  injectable for tests. Owners create their own directories.
- **Identity**: `EchoCore.AppIdentity` (bundle id `com.sancrisoft.Echo`, log
  subsystem, version from the bundle; CI injects `MARKETING_VERSION` and
  `CURRENT_PROJECT_VERSION` from the tag).
- **Preferences**: `EchoCore.AppSettings` from `settings.json`.
- **Debug flags**: `EchoCore.LaunchEnvironment` is the single reader of `ECHO_*`
  environment variables, compiled out of release builds. No other file reads
  `ProcessInfo.processInfo.environment` (the boundary script checks).
- **Model identity**: `static let` contracts in their packages
  (`ParakeetModel.modelID`, `SummaryModel.modelID`), never display strings.
- **Measured constants**: `static let` next to the code they tune, each with the
  comment that records the measurement. They are not configuration.
- **Secrets**: none exist. Hugging Face and GitHub are accessed anonymously; the
  boundary script rejects `hf_`/`ghp_` patterns.

---

## 9. Testing strategy

Adopted in ADR-004.

- **Swift Testing everywhere.**
- **Package tests run without a host** (`swift test --package-path
  Packages/<Name>`, `make test`). They cover pure logic (tables), integration
  against temp roots (stores, writers, downloads against a local server), and
  gated acceptance (real models and fixtures). Because no app hosts them, they
  cannot touch the real data folder unless a test deliberately does — and the
  only tests allowed to are the acceptance suites that already needed a
  downloaded model.
- **`EchoCoreTestSupport`** (a product of `EchoCore`) gives every test target
  the fixtures root (`Fixtures/` at the repo root, resolved from `#filePath`),
  the `.acceptance` trait (`ECHO_ACCEPTANCE=1`, also `TEST_RUNNER_` prefixed
  under `xcodebuild`), temp-root helpers, and the rule that missing fixtures
  skip with instructions rather than fail.
- **App tests (`AppTests`)** are hosted and exist only for what needs the host:
  the `TestHost` tripwire and launch smoke. Inits across the codebase are
  side-effect free; `AppComposition.start()` is the one door side effects go
  through and it checks `TestHost.isActive` once.
- **UI tests**: none by default. Design review uses a DEBUG gallery in
  `DesignSystem` and the `LaunchEnvironment` snapshot flags; correctness of view
  logic is tested through the pure resolvers and `WorkspaceModel`.
- **End-to-end**: the acceptance suites replay real fixtures through the real
  pass and the real model; a parity check opens a v1 library and asserts every
  meeting loads unchanged.
- **What a test may not do**: write into the source tree, read
  `~/Library/Application Support/Echo` outside an acceptance suite, sleep for
  timing, or depend on wall-clock performance on a shared runner.

---

## 10. Tooling

- `make build` — `xcodebuild` the `Echo` scheme (Debug, arm64, ad-hoc).
- `make test` — `swift test` for every package, then the hosted `AppTests`.
- `make test-package P=Meetings` — one package.
- `make lint` — `swift format lint --strict --recursive` (the toolchain's
  formatter, configured in `.swift-format`) plus `scripts/check_boundaries.sh`.
- `make format` — `swift format --in-place --recursive`.
- `make run` — build and open the app.
- `scripts/snapshot.sh [scene…]` — render the main window's scenes to PNGs
  against a copy of the real library (`ECHO_SNAPSHOT_PATH`,
  `ECHO_SNAPSHOT_SCENE`), the design-review tool; pixels cannot be captured from
  outside a window on this macOS.
- CI (`.github/workflows/ci.yml`): lint, package tests, app build and hosted
  tests, on pull requests and pushes to `main` and `v2`. Release and installer
  workflows are unchanged: the app target is still named `Echo`.

---

## 11. Transition from the PoC

The v2 branch does not carry the PoC sources. `main` keeps shipping and receiving
hotfixes; `git fetch origin main && git show origin/main:Echo/<File>.swift` is how
a port reads the original — the remote ref, so a stale local `main` cannot
silently feed a port the wrong sources.

Order of work after the foundation (each item creates its package and brings the
PoC's tests for that module with it):

1. **Foundation + first feature**: `EchoCore`, `Meetings`, `DesignSystem`,
   `Workspace`, `App`. The library opens the existing data folder.
2. `ModelDelivery`, then `Transcription` and `Summarization` (engine ports;
   pure machines and measured constants carried as-is, isolation fixed).
3. `Audio` (the vendored WebRTC library moves from `Vendor/webrtc-apm` into
   `Packages/Audio/Vendor/WebRTCAPM.xcframework` with its headers in a C target;
   the root `Vendor/` directory is deleted then).
4. `Recording` — the session facade; at this point the app records,
   transcribes and summarizes.
5. `CallDetection`, `Updates`, `Island`.
6. Workspace surfaces from the redesign (document, search, first run), then the
   close-out parity checklist.

Until the corresponding package lands, `THIRD_PARTY_NOTICES.md` describes more
than v2 bundles; it is updated at the merge, together with `NOTICE`.

---

## 12. Principles, restated as rules

1. Code lives with its owner. Ask "who owns this?", never "what kind of file is
   this?".
2. A package is a capability with its own tests and a small public API. No
   package is created for a single type or a utility.
3. Start flat. Add a folder when the listing stops helping.
4. Abstractions appear to isolate an external dependency, to make something
   testable, or to separate a public API from an implementation. Not before.
5. Side effects are easy to find: they live in actors and in `start()`-style
   methods, never in initializers or views.
6. One owner per state; derived state is computed.
7. Errors are typed, traced once, and shown as state.
8. Measured constants travel with their reasons.
9. The compiler enforces the boundaries; the script catches what it cannot.
10. An agent should be able to open `Packages/<Name>/` and change that
    capability without reading the rest of the app.
