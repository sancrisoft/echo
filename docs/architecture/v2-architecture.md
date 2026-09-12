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
| **ModelDelivery** | Getting multi-GB models onto disk honestly: resumable transfer, byte-weighted progress, the one progress clamp, stall watchdog and retry, snapshot manifest and completeness, Hugging Face snapshot download, retired-model cleanup, disk-space floor. | EchoCore | swift-transformers (`Hub`), which pins swift-huggingface 0.9.0 |
| **Meetings** | The library on disk and in memory: `MeetingStore` (actor, the only thing that touches `Meetings/`), `MeetingMeta`/`MeetingRecord`, the legacy `summary.json` decoder, audio name families and their classification, trash, preserved recordings, storage measurement, `MeetingLibrary` (observable façade), export and copy formatting. | EchoCore | — |
| **Recording** | The meeting lifecycle behind one observable: `RecordingSession` (phase, live levels, notices, current meeting, start/stop/retry), permission priming, wiring Audio into retention and levels, the finalization machine that schedules transcription passes and gates summaries, the summary scheduler and backfill policy. | EchoCore, Audio, Transcription, Summarization, ModelDelivery, Meetings | — |
| **CallDetection** | Which apps are on a call: the mic-activity monitor over Core Audio process metadata, the curated app catalog, the installed-browser catalog, the disabled-apps filter, and `CallSessionMachine` (debounce, grace, faces as pure output). Produces `CaptureScope` values. | EchoCore, Audio | — |
| **Updates** | Version arithmetic, the GitHub release feed, the daily checker, and the updater that hands off to the install script. | EchoCore | — |
| **DesignSystem** | Semantic color tokens for light and dark, the type scale over the two bundled typefaces, spacing, radii and control geometry, the durations and curves the design states (`EchoMotion`), and the primitives every surface repeats: buttons, chips, property rows, tab strips, list rows, meta strips, status badges, level gauge, empty state. No product logic. | — | — |
| **Workspace** | The main window: sidebar with meetings grouped by date, the document (summary and transcript), trash, the settings screen, first-run banners, search, the Markdown renderer, `WorkspaceModel` (selection, section, search, sort — the window's single navigation truth), display-state resolution. | EchoCore, Meetings, Recording, ModelDelivery, Updates, CallDetection, DesignSystem | — |
| **Island** | The floating panel: the shell's geometry per screen (`ScreenGeometry`, `IslandMetrics` — the cutout read from the screen, never a constant, and the no-notch pill fallback), the shell itself (its outline with the two concave flares, the ears either side of the cutout, the one-row expansion), `IslandController` (the non-activating `NSPanel`, which face the shell wears, where the window goes, and the one report detection needs about the session), the faces. | EchoCore, CallDetection, Recording, DesignSystem | — |
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
- `AudioConstants` (`sampleRate` 16 kHz, `channels` 1, `captureFormat`), `AudioLevelMeter.level(from:)`, `AudioDownmixer.toMono(_:)`, `BufferResampler`. The names are the PoC's, not this document's earlier sketch of `AudioFormat.canonical`: they are what the ported tests and the measured comments refer to. `captureFormat` is an `AVAudioFormat?` rather than a force-unwrapped value, and `AudioConstants.sampleRate` is deliberately a second declaration of the 16 kHz that `TranscriptionPass.sampleRate` also carries — EchoCore takes something only when three packages need it, and today two do. Recording is the third; that is when to lift it.
- `MicrophoneCapture(onSamples:onLevel:onRawBuffer:)` with `start() async throws` / `stop()` / `requestPermission()`, and `SystemAudioCapture(onSamples:onLevel:)` with `start(scope:) throws` / `stop()` / `primePermission()` / `deliveryStats()` / `DeliveryStats` / `CaptureError`. The callbacks are constructor parameters, not settable properties: both classes are `Sendable` and their callbacks run on the AVAudioEngine render thread and the Core Audio IO queue, so what those threads read has to be immutable. `SystemAudioCapture.start` is synchronous — the PoC's `async` came from a protocol requirement, and the protocol is gone (see below). `onRawBuffer` is the pre-downmix hook the DEBUG fixture recorder needs.
- `CaptureScope` (`.everything` | `.app(ProcessSelector)`) with `scopedApp`, `ProcessSelector` (display name + ONE bundle-ID prefix + `scopeable` + `matches(bundleID:appBundleID:)`), `ScopedProcessResolution` (`ProcessEntry`, `includeSet(for:in:)`, `followUpdate(for:current:processes:)`). `ProcessSelector` is the capture-side half of the PoC's `CallApp`, which cannot come down here because `CallDetection` sits above this package; detection maps its catalog onto selectors, and the matcher stays one implementation so detection and scoping cannot disagree about what an app is. One prefix, not a list — the PoC matches on one and so does the catalog. `CaptureScope` has NO `indicatorLabel`: "Everything" / "Zoom only" is copy, `Meetings.CaptureScopeRecord.scopedDisplayLabel` already renders the persisted form, and the live label belongs to whichever surface draws it (ADR-003). The `CaptureScope` → `CaptureScopeRecord` mapping needs both packages, so it belongs to Recording.
- `AECStage` (the seam: `processMicSamples`, `feedFarEnd`, `reset`), `PassthroughAECStage`, `WebRTCAECStage` (`isHealthy`, `onEngineEvent`, `init(failedEngine:)`), `SwitchingAECStage` (`currentMode`, `setMode(_:)`). `SwitchingAECStage` is what this document earlier called `EchoCanceller`; the protocol is kept because the switching stage genuinely consumes `any AECStage`. Both stages hold their state behind a `Mutex` rather than an actor: the mic path must return its processed samples to the same real-time callback that handed them over, which an actor hop cannot do.
- `OutputRouteClass`, `EchoHandlingMode`, `EchoModeMachine` (+ `Event`, `Effect`), `EchoDegradationNotice`, `EchoBleedProbe` (+ `Verdict`). The offline echo-cancellation pre-pass is NOT here: it reads `Transcription.EnergyEnvelope` as well as this package's AEC stage, and no package below `Recording` sees both, so putting it here would mean a second copy of a measured type. It is disabled and unfinished in any case.
- `InputDeviceMonitor(onDefaultInputChange:)` (+ `currentDefaultInputDevice()`, `start()`, `stop()`), `InputDeviceLifecycleMachine` (+ `Event`, `Action`, `DeviceID`), `InputDeviceNotice`; `OutputRouteMonitor(onRouteChange:onDefaultOutputDeviceChange:)` (+ `currentRoute()`, `start()`, `stop()`), `OutputRouteClassifier`. Both monitors register their Core Audio listeners on their own serial queues; the PoC used the main queue and `MainActor.assumeIsolated`, both artefacts of its main-actor default isolation.
- `InputHealthClassifier` (+ `Event`, `Effect`, the tunable thresholds), `InputHealthTracker(onEffect:)` (+ `beginSession(generation:)`, `endSession()`), `InputHealthNotice`, `FanOutGateDiagnosticsSink`; `GateTerm`, `GateVerdict`, `GateDecisionRecord`, `GateDiagnosticsSink`, `OSLogGateDiagnosticsSink`; `LiveInputMonitor` (actor: `start`, `stop`, `ingest(_:from:)`, `noteCaptureGap(seconds:on:)`), `AudioStats`. The gate-diagnostics types arrive with the monitors because the classifier and the live monitor are both built on them. The classifier emits notices as VALUES and never touches the audio path — structurally, since `Effect` has no case that could; where a notice is shown is #118's decision, not this package's.
- `CaptureGapTracker` (`beginEpisode(now:)`, `noteDelivery(batchDuration:now:)`), `RetainedAudioWriter` (actor: `append`, `noteGap`, `finish`, `discard`, `currentAccounting`, `isDisabled`), `AppBundleIdentity`. `CaptureGapTracker` was lifted out of the PoC's `RecordingController`, which this rebuild replaces. `RetainedAudioWriter.init(directory:fileName:)` takes the retained file's name as a seam because the audio name families belong to `Meetings`, which sits above this package; Recording passes `MeetingStore.retainedAudioFileName`.
- `FixtureRecorder` (actor, `#if DEBUG`) with `FixtureScenario`, `FixtureInfo`, `InputDeviceFacts`, `InputDeviceFactsReader`, and both `writeWAV` overloads — the one sanctioned way to record a fixture, with no AEC in its path on purpose. The PoC's `@Observable @MainActor` is gone: phase changes leave through a callback, because an engine package has no views.
- **Not here, and where each goes.** The capability boundary cuts through several PoC files, and the audio→transcript direction is the common reason: this package may not import a sibling, so anything that needs Audio *and* Transcription belongs to `Recording`, the lowest package that sees both.
  - The offline echo-cancellation pre-pass → `Recording` (see the echo-handling entry above). `EchoBleedProbe`, its first step, is here.
  - `AECAcceptanceTests` → `Recording`, under `.acceptance`. It replays fixtures through `SwitchingAECStage` and then asserts on the segments the Parakeet pass produces; strip the transcription and no assertion is left.
  - `ExternalInputMeasurementTests` → `Recording`. It transcribes fixtures for the same reason.
  - `MicActivityMonitor` → `CallDetection`, per §2 and the boundary allowlist, even though issue #95 names it with the other monitors. Its process-enumeration technique is duplicated on both sides by necessity, since `Audio` cannot depend on `CallDetection`; both sides say so.
  - `ScopeSelection` and `ScopeSelectionTests` → `Island` (phase 2). They derive a selection from `CallDetection`'s state, which is above this package; `CaptureScope` itself stays here.
  - `WaveformView`, `GlidingLevel` and their tables (`WaveformAmplitudeTests`, `GlidingLevelTests`) → `DesignSystem`, arriving with `Recording`. The level meter is a rendered primitive; this package only produces the numbers, per callback and never pre-averaged, so a consumer can window them in seconds.
- No `AudioCaptureSource` protocol. The PoC declared one and nothing ever consumed it polymorphically; its only effect was to force the two capture sources to share a surface they do not share.
- No `@Observable` and no `@MainActor`. The observable façade over a session is `RecordingSession`, in Recording.

**Transcription**
- `ParakeetModel` (actor; `state`, `initialize(deferWhile:)`, `readyModelDirectory()`, the identity constants `modelID`/`modelDisplayName`/`modelDisplaySize`/`attribution`, `modelDirectory(in:)` and `resolvedModelDirectory(in:)`). Built with an injected `modelsRoot` plus optional `modelsPresent`/`downloader`/`deferPollInterval` seams, so the lifecycle is testable without a 480 MB download. The two directory accessors differ on purpose: FluidAudio discards the last component of the directory it is handed and appends its own `Repo.folderName`, so `modelDirectory(in:)` is what the library is passed and `resolvedModelDirectory(in:)` is where the bytes land.
- `TranscriptionPass.run(retainedFiles:model:shouldYield:onProgress:onEvent:) -> [TranscriptSegment]`, plus the shaping surface the tables exercise (`segments(from:text:duration:channel:silenceStarts:)`, `spanLevels(of:envelopes:)`, `readSamples(at:)`, `canStartSegment`, `carriesAWord`, `wordBoundary`) and the measured constants (`sampleRate`, `segmentGapSeconds`, `silenceSplitSeconds`, `maxSegmentSeconds`, `yieldPollInterval`).
- `PassProgress` (the one clamped, monotonic fraction), `EnergyEnvelope` (`rms`, `silenceStarts`, `longestDominantRun`, `frameSeconds`, `silenceFloor`), `TranscriptionError`.
- `PassEvent` — the structured replay sink (`channelDecoded`, `segmentProduced`, `segmentSuppressed`), carrying ids, spans and scores only. It replaces the PoC's `(String) -> Void` diagnostic sink, whose every line contained transcript text by construction; a harness that wants words reads them from the segments it already holds.
- `EchoDedupPolicy` (also used by tests and diagnostics).
- **Recorded, not compensated.** Defects the port carried across unchanged, because fixing any of them changes dedup or shaping output and the constants were tuned with them present (ADR-006). Measure with `ECHO_ACCEPTANCE=1 make test-package P=Transcription` before touching one. `spanLevels` measures `own` over the whole segment span but `other` only over what the shorter channel covers, because `EnergyEnvelope.rms` clamps to its own frame count: it breaks the same-window invariant `SpanLevels` documents and can suppress real speech near a shorter channel's end, which is the false deletion the whole policy exists to prevent and the worst of these. A channel under 0.3 s (4 800 samples) throws FluidAudio's `ASRError.invalidAudioData` unmapped, aborting the pass and discarding the other channel's finished transcript; only `samples.isEmpty` is guarded. `readSamples` validates `commonFormat` but never the sample rate, though 16 kHz is hard-coded for envelope framing, silence instants and model input. The block read advances by the requested count rather than `buffer.frameLength`, so a short read shifts the rest of that channel's timeline. Model download reports through one unstructured `Task` per progress callback (~10^4 for 480 MB), nearly all of them discarded by the forward-only guard.

**Summarization**
- `TextGenerating` (the seam: `stream(system:user:params:) -> AsyncThrowingStream<String, Error>`, raw deltas, and terminating the stream cancels the generation) and `GenerationParams` with its three presets — the NDJSON defaults, `.markdownSummary`, `.caption`. The penalty WINDOW is not on the params: all three penalties run over 64 tokens and that lives in `MLXTextEngine`, because it is a property of the runtime and applies to every generation.
- `Summarizer(modelName:)` (actor): `generate(from:using:onProgress:) -> AsyncThrowingStream<SummaryDocument, Error>`, `mapChunk(_:engine:language:)`, `mergeMapResults(_:)` (nonisolated), `reduceMarkdown(facts:notes:engine:language:)`, `caption(for:using:) -> String?`, `detectedLanguage(of:)`, `estimatedTokens(of:estimator:)`, `singlePassBudget`. The signature differs from this document's earlier sketch of `generate(from:language:)` on purpose: the language is DETECTED, never supplied, because a caller who can pass one can invent one, and detection across the whole transcript with a 0.6 floor is a defended behavior. It is exposed as `detectedLanguage(of:)` for tests and diagnostics.
- `SummaryDocument` (markdown, facts snapshot, detected language, model name, `isFinal`) and `SummaryPhase` (`mapping(part:of:)`, `reducing`, `finished`). `isFinal` marks the ONE element a caller may persist; a cancelled or failed generation emits none, and the stream throws instead. Its markdown is never blank on a final document — an empty reduce with grounded facts renders them through `MergedFacts.markdown`, and an empty reduce with no facts throws. Progress is a typed phase rather than a sentence, for the reason `ModelDelivery` reports a phase and a fraction.
- `SummaryDecision`/`SummaryActionItem`/`SummaryOpenQuestion`/`SummaryRisk`, `ChunkMapResult`, `MergedFacts` (`isEmpty`, `markdown`), `SummaryMerge.merge`, `SummaryDedup`, `SummaryLimits`, `NDJSONLineValidator.isValid` (never throws; wider than any live phase on purpose).
- `SummaryModel` (actor; `modelID`/`modelDisplayName`/`modelDisplaySize`/`idleTimeout`/`snapshotSpec`, `state`, `refreshState()`, `snapshotExists()`, `partialDownloadBytes()`, `ensureReady()`, `ensureDownloaded()`, `withEngine(_:)`, `acquireEngine()`/`releaseEngine()`, `pauseDownload()`/`resumeDownload()`/`isDownloadPaused`, `unload()`), `SummaryModelState`, `SummaryEngineLoader`/`SummaryModelDownloader`, `IdleReleaseScheduling`/`TaskIdleReleaseScheduler`, `SummaryModelError`. Built with a required `modelsRoot` and `pauseStateFile` plus optional loader, downloader, existence, partial-bytes, scheduler, timeout and pause-store seams, so the lifecycle is testable without a 3.3 GB download, a Metal device or a real clock. `ensureReady` and `ensureDownloaded` differ on the pause and must not be unified: the eager fetch honors a paused intent, a summary the user set in motion does not. `state` owns the paused-versus-failed distinction, keyed on the persisted intent rather than on a `CancellationError` that cannot be told apart at the catch site; `refreshState` resolves `ready > failed > paused > partiallyDownloaded`, so a failure notice outlives a refresh.
- `SummarizationError` (`emptyTranscript`, `modelUnavailable`, `emptyModelResponse`). No cancelled case, and transport failures arrive as `ModelDeliveryError` unwrapped — the disk floor, the stall and the integrity check are that package's, and so is their copy.
- `TranscriptChunk`, `ChunkAssembler`, `TranscriptChunker`, `ChunkingConfig`, `TokenEstimating`/`HeuristicTokenEstimator`. Ownership resolved as §2 always had it: chunking is the map route's input stage and its only consumer is the summarizer. The Transcription port landed it there first because issue #87 grouped it with dedup as one shaping layer, and a sibling cannot be imported, so the file moved here when this package opened rather than the graph gaining an edge for one struct. Routing shares this estimator rather than a copy of its arithmetic, so the route boundary and the chunk boundary cannot disagree about what a transcript costs.
- **Recorded, not compensated.** `ChunkAssembler.runningTokens` counts the seeded overlap head, so `minChunkTokens` and `targetTokens` can be satisfied by mostly duplicate content. It arrived with the chunker from the Transcription port, and changing it reshapes every chunk boundary the routing budget was measured against (ADR-006).
- No `@Observable` and no `@MainActor`. `SummaryModel.state` is the truth, on the actor; a UI-facing observable over it belongs to whichever package renders it, and must not become a second copy (ADR-003).

**ModelDelivery**
- `SnapshotDownloader(modelsRoot:spec:diskFloor:)`: `snapshotDirectory`, `manifestFileURL`, `partialDownloadDirectory`, `snapshotExists()`, `partialDownloadBytes()`, `download(progress:)`; `SnapshotSpec` (repo id, weight/config globs, manifest and partial-directory names), `SnapshotDownloadPhase`.
- `ResumableFileDownload`: `fetch(from:expectedBytes:into:progress:)`, `resumeDecision(partialBytes:expectedBytes:)`, `Resume`, `byteCount(at:)`.
- `DownloadProgress` (the one clamp), `DownloadRetry.withStallRetry(attempts:stallTimeout:watchdogInterval:onRetry:operation:)`.
- `SnapshotDownloadBudget`, `SnapshotDownloadTally`, `SnapshotManifest`.
- `DownloadPauseStore` (protocol) and `FileDownloadPauseStore(fileURL:)`, `RetiredModelCleanup.run(retiredRepoIDs:retiredFileNames:modelsRoot:remove:)`, `DiskSpace`, `ModelDeliveryError`.
- **Recorded, not compensated.** Three defects inherited from the PoC, left as they stand because fixing them changes behaviour and only a real multi-GB download can measure the change (ADR-006). An uppercase etag would read as corruption — `isSHA256` accepts any hex case, `sha256Hex` emits lowercase, and `commitWeightFile` compares with `==` — so a good weight file would be deleted and fetched again forever; the Hub returns lowercase today, and `SnapshotIntegrityTests` pins the current behaviour with a comment. `SnapshotDownloadTally.noteWeightBytes` keeps a high-water `max`, which discards the legitimate restart from zero after a 416 heal or a 200 answer to a Range request: the fraction freezes until the re-download passes the old mark, and that fraction is also the stall watchdog's heartbeat, so the heal path can be cancelled as a stall. A nil `metadata.size` is absorbed as `0`, so the budget can fall to zero, the fraction never moves, and the already-committed skip can never fire; `missingFileMetadata` would be the honest response.
- No `@Observable` and no `@MainActor`: progress leaves as a phase and a fraction, and the model's observable state belongs to the package that owns the model. The pause gate and the shared download task live with that owner too.

**Meetings**
- `MeetingStore` (actor): `save`, `listMetas`, `loadMeta`, `loadRecord`, `updateMeta`, `delete`, `replaceTranscript`, `recordTerminalProvenance`, `attachSummary(markdown:caption:modelName:to:)`, `removeSummaryArtifacts`, `migrateLegacySummaries`, the audio name families and their classification, adoption, preservation, cloning and deletion.
- `MeetingLibrary` (`@Observable @MainActor`): `metas`, `trashedMetas`, `storage`, `refresh()` (reads only), `foldLegacySummaries()`, `purgeExpiredTrash()`, `backfillWordCounts()`, `loadRecord`, `rename`/`trash`/`restore`/`deletePermanently`/`emptyTrash`, preserved-audio queries and deletions, `measureStorage()`; `store` for the pipeline.
- `MeetingMeta`, `MeetingRecord` (`summaryMarkdown: String?`), `TranscriptProvenance`, `CaptureScopeRecord`, `LegacyMeetingSummary`, `StorageBreakdown.measure`, `MeetingExport` (markdown / plain text / standalone summary), `MeetingListSelection` (pure keyboard rules), `MeetingStoreError`.

**Recording**
- `RecordingSession` (`@Observable @MainActor`): `phase` (`idle` | `recording(startedAt:scope:)` | `stopping` | `finalizing(meetingID:progress:)` | `summarizing(meetingID:)`), `levels`, `notices`, `currentMeetingID`, `queuedMeetingIDs`, `terminalFailureMeetingIDs`, `start(scope:)`, `stop()`, `retryTranscription(_:)`, `retranscribe(_:)`, `requestSummary(_:)`, plus the two the composition root calls at launch: `resumePendingFinalizations()` and `kickSummaryBackfill()`.
  - `phase` is COMPOSED, not assigned. Three owners contribute to it — this object drives capture, `FinalizationDriver` publishes the running pass, `SummaryScheduler` publishes the meeting being summarized — and assigning one field from three places is how a phase ends up briefly wrong. The specific wrongness it avoids is a flash of `.idle` between a pass finishing and its summary starting, which is exactly the gap that made "summarizing" invisible in the PoC (issue #94). Capture wins the precedence: whatever post-stop work is in flight, a live recording is what the user is doing. `recording`'s `scope` is the EFFECTIVE coverage, so a scoped tap that failed reads `.everything` and the widening is visible.
  - `queuedMeetingIDs` and `terminalFailureMeetingIDs` are published by the driver, not re-derived here — the exception ADR-003 allows for state the owner exposes, and what the display resolver needs to offer a Retry.
  - `levels` is computed at read time, because staleness is a function of *now*: a channel whose device disappeared has to fall to the resting line without a callback arriving to push it there.
- `RecordingPhase`, `RecordingNotice` (`Kind` declaration order IS render order, so a health notice can never displace an active device-lost one), `CaptureLevels`.
- `FinalizationMachine` (pure; exposed for the display resolver and tests), `SummaryBackfillPolicy` (pure).
- Internal: `FinalizationDriver`, `SummaryScheduler`, `FinalizationPreemptionSignal`, `LevelWindow`/`ChannelFrameCounter`, `CaptureScopeRecord.init(capturing:)`.
- **The seams live here, not in `Audio`.** `MicCapturing`, `SystemCapturing`, `InputDeviceWatching`, `OutputRouteWatching` and `EchoCancelling` are Recording's protocols over Audio's concrete classes, plus `TranscriptionPassRunning`, `SummaryGenerating`, `CaptionGenerating` and a permission primer, all bundled as init parameters. `Audio` dropped the PoC's `AudioCaptureSource` because nothing consumed it polymorphically; Recording IS that consumer, since no package test may open a microphone, start a process tap, raise a TCC prompt or load a 480 MB model. Two capture protocols rather than one, because the starts genuinely differ (`start()` awaits a permission check; `start(scope:)` is synchronous and takes coverage), and the callbacks are outside the protocols because every one of those classes takes them at `init`.
- **Ported, not rewritten** (ADR-006): `FinalizationMachine` and `FinalizationPreemptionSignal` (from `FinalizationCoordinator.swift`), `SummaryBackfillPolicy` and `ChannelFrameCounter` (from `RecordingController.swift`), and the level window's two constants and its prune (from `RecordingState.swift`). Isolation is the only change: `nonisolated` goes, and the signal's `NSLock` becomes a `Mutex`, the swap `Audio` made to `CaptureGapTracker`. Their PoC suites came with them and passed unmodified, which is the acceptance criterion.
- **Rewritten**: everything else. `RecordingController` (1 821 lines) had no injection seams and therefore no tests for any orchestration; `FinalizationCoordinator` (542) had settable `var` seams that no test ever set. What survives is the ORDER of things, because that is where the measurements are. The orderings that are not obvious from the code they call, each with its reason in the source: the AEC reference tap comes up before the scoped tap; `deliveryStats()` is read before `stop()`, which clears the fields it reports from; `LiveInputMonitor.stop()` runs before `InputHealthTracker.endSession()`, or the session's last chunks classify into an inert tracker; a capture callback's gap and samples travel in ONE task; `stop()` is called on any failed tap start, because `SystemAudioCapture`'s global path does not unwind its own half-built topology; and the persist order is finish → save → adopt, because `save` creates the folder that `adopt` moves into.
- **`RecordingState` is gone.** Its `isRecording`/`startedAt`/`captureScope` described one lifecycle from three angles and became `phase`; its live-transcript half had nothing to hold, since nothing transcribes during a recording.
- **Staleness** is two named predicates over one `sessionGeneration` — `isCurrentSession` for post-stop work that must outlive the phase, `isCapturing` for anything that may only touch a live session — replacing the PoC's eight inline conjunctions (§6).
- **`EchoCancellationPrePass` is not ported, and that is closed.** Measured 2026-08-10 across the nine meetings on disk holding a kept audio pair, replayed with the stage on and off: the probe fires on four and correctly skips the five with no speaker path, and where it fires only 75–84 % of the user's own vocabulary survives, against the ≥ 90 % the plan set as its gate — while the bleed it removes runs from most of it, to none, to worse than before. The near-end ratio is not the lever: swept 0.50 → 0.05 over two replays, preservation moved 0.622 → 0.671 and 0.820 → 0.848, so a tenfold change buys five points. The lost words fail the silence floor beneath the guard, not the guard. Losing the user's own words is also the worse failure, because the summary is grounded in the transcript: a word deleted here is gone from the notes, while surviving bleed is only misattributed and the teammate's row still carries it. Reopening this needs a new sweep clearing the gate, and the lead is the floor, not the ratio.
- **Recorded, not compensated.** Inherited defects Recording must not "fix" without a measurement: summary Markdown is not monotonic (it shrinks across the map→reduce boundary and across the internal retry); the single-pass route yields no facts, so `document.facts` is empty for every short meeting; `SummaryModel.unload()` deliberately leaves `state` at `ready` and `refreshState()` deliberately keeps `.failed` sticky; and `ModelDelivery`'s progress tally can freeze the fraction that is also the stall watchdog's heartbeat, so a healthy from-scratch download can arrive here as `.failed(downloadStalled)` — unmeasured, and not this package's to fix. Compensated on purpose, because it is a reporting gap rather than a measured behavior: the long summary route does not emit `SummaryPhase.finished` on its failure paths, so the scheduler clears its state on stream completion-or-throw and never on `.finished`. Audio's own open items are recorded in its entry above; the two that reach this package's wiring are that a failed tap start must be stopped explicitly, and that the AEC health hook reports transitions only, so a route round trip can leave the engine down with no degradation notice.
- **One behaviour was fixed rather than carried**, because the scheduler is a rewrite and not a port: the PoC consumed `requestedSummaryID` before asking the policy, so an explicit request whose meeting happened to be ineligible at that instant was silently lost — a user could press Generate and have nothing happen. It now survives to the next trigger.
- **Left for phase 2**: the display resolver over `phase` + `MeetingMeta` + the machine, the preserved-recording bar, the level meter in `DesignSystem` (this package produces the numbers, per callback and never pre-averaged, and windows them in seconds), the island's record trigger, and the launch-time model acquisition — `ParakeetModel.initialize(deferWhile:)` and the eager summary fetch are not wired into `start()` yet, so a fresh install downloads nothing until a recording's own prefetch runs. Also unresolved, and not this package's to settle alone: `ParakeetModel.state` and `SummaryModel.state` live on actors, so no view can observe them. The first surface that renders model readiness has to decide how, and it must not keep a second copy (ADR-003).

**CallDetection**
- `CallAppCatalog`: `apps` (the curated table, in attribution order), `match(bundleID:appBundleID:browsers:)`, `matchedApps(from:disabledNames:browsers:)`, `detectableDisplayNames(browsers:)`, `uniqueDisplayNames`. The entries are `Audio.ProcessSelector` values, not a `CallApp` of this package's own: the app the island names is the app a scoped tap narrows to, and one matcher for both is what keeps detection and scoping from disagreeing about what an app is. `matchedApps` is the disabled-apps filter at the single matcher call site — filtered here, so an app the user silenced is invisible to the island, the scope dropdown and auto-scope alike.
- `BrowserCatalog.installed()`: every browser LaunchServices registers for `https`, deduped, in its order, cached for 60 s behind a `Mutex` (the callers are threads, not actors — `AppBundleIdentity`'s reason). Display names are the bundle's file name, never `CFBundleDisplayName`, because the disabled-apps setting is keyed on that string and it has to survive an OS language change.
- `MicCaptureClient` (pid + both identities), the vocabulary the monitor produces and the catalog reads. A value type rather than one nested in the monitor, so the pure half of this package is complete without it.
- `CallSessionMachine` (pure struct: `Phase`, `Event`, `Action`, `handle(_:) -> [Action]`, and the observable-by-tests state `enabled`/`phase`/`currentApp`/`isRecording`/`dismissedThisCall`/`keptRecordingLatch`/`face`), `CallDetectionTiming` (3 s debounce, 30 s grace, one 10 s retract for every face that retracts — the product owner's decision, and `startRetractTimer` carries no interval so the faces cannot drift apart again), `IslandFace` (the PoC's four faces; the redesign's six are the island's work).
- Two product lines are structural, not review comments: `requestStartRecording` is emitted from exactly one handler, so no sequence of detection or timer events can start capture; and every path out of `endGrace` either stops the recording or is the user's deliberate choice to keep it. Both are swept over every 4-event sequence in the tests.
- `Action.openDashboardToSavedMeeting` is `openWindowToSavedMeeting` here: v2 has a main window, not a dashboard. That is the only rename the port makes.
- `MicActivityMonitor(onClientsChanged:)` (`Sendable`): `start()`, `stop()`, `currentClients()`. The thin Core Audio shim — the process-object list plus one wildcard listener per process, 80 ms-coalesced, reported only on a real diff, Echo's own process excluded. The wildcard address is not decoration: registering the exact `isRunningInput` address on a process object succeeds and then never delivers, so the exact address means detection silently never fires. Its listeners run on the monitor's own serial queue, not the main queue as in the PoC. The PoC's `ECHO_MIC_DUMP` probe (a 2 s poll of the whole process table) does NOT come across: it was the instrument for the FaceTime and Safari questions, both answered and now table-tested, and it would cost a `LaunchEnvironment` flag nothing reads. The per-change diff log stays, identifiers only.
- `CallDetector` (`@Observable @MainActor`): `face`, `graceDeadline`, `appsInCall`, `start()`/`stop()`, the two pieces of news from above (`recordingChanged(_:)`, `hoverChanged(_:)` — the pointer is the island's to see, the retract it suspends is the machine's to decide), and the five taps. It owns the monitor, the machine and the three timers, and holds no policy — every decision arrives as an `Action`.
- `CallDetectionRequests` (`@MainActor`): `startRecording(CaptureScope)`, `stopRecording() async`, `openSavedMeeting()`. Starting and stopping belong to `Recording` and the panel belongs to `Island`, both ABOVE this package, so detection asks with exactly three verbs and whoever wired it acts. `stopRecording` is `async` because "Meeting saved" must not lie: the actions after a stop request are applied on the far side of it, so the face follows persistence. `recordingChanged(_:)` is pushed in for the same reason — this package cannot observe a session it sits below.
- Internally three seams the tests drive: the watcher factory (its callback is main-actor isolated, so the hop off the monitor's queue is the live factory's business and a test can deliver a report synchronously), the installed-browser reader, and `TimerArming` — which arms a one-shot timer and returns its cancellation. The tests assert which timer was armed and for how long and fire it by hand; what firing MEANS is the machine's table, tested there. No test sleeps.
- **Not composed at launch.** `AppComposition` does not build a `CallDetector` yet. Detection with no panel would count down and auto-stop a recording with nothing on screen to say so, which is exactly the surprise the countdown exists to prevent. The island's shell wires it.
- **Inherited wrinkle, recorded not compensated**: `cancelGraceTimer` clears `graceDeadline` while the `endGrace` face is still up, so for as long as the stop takes to persist, that face has no number to render. The PoC behaves the same way. Whichever surface draws the countdown decides what a deadline-less end-grace face looks like.

**Updates**
- `UpdateChecker` (`@Observable @MainActor`), `ReleaseVersion`, `GitHubReleaseFeed`, `UpdateInstaller`.

**DesignSystem**
- `EchoColor` (semantic tokens for both appearances: surfaces, the two hairlines `divider` and `border`, the text steps, accent and its wash, recording) and `EchoColor.Island` (the island's own palette, pinned in both appearances because the shell is black in both), `EchoFont` (the scale over the two bundled typefaces, and the launch-time registration the composition root calls), `EchoSpacing`, `EchoRadius`, `EchoLayout` (the window's fixed dimensions), `EchoControl` (the controls' own geometry), the window's primitives (`EchoButtonStyle` roles, `StatusBadge`, `PropertyRow`, `TabStrip`, `MetaStrip`/`MetaItem`, `EmptyState`, `SelectableRowChrome`) and the island's (`IslandButtonStyle` roles, `IslandIconButtonStyle`, `ValueChip`, `LevelGauge`), `DesignGallery` (DEBUG). The token enums are `nonisolated`. The island's controls are a separate family from the window's while DEC-4 is open.

**Workspace**
- `WorkspaceWindow(dataRoot:)` (root view), `WorkspaceModel` (`@Observable @MainActor`: `section`, `selectedMeetingID`, `selectedTrashedID`, `documentTab`, `searchText`, `sortOrder`, the selection rules), `MeetingSortOrder`, `MeetingFilter`, `MeetingDateGroup`, `MeetingStatus.resolve`, `MarkdownDocument.parse`, `MarkdownRendering`, `MarkdownView`.

**Island**
- `ScreenGeometry` (one screen's frame, visible frame, `safeAreaInsets.top`, the
  two auxiliary top areas and the status bar's thickness, read off `NSScreen`
  once so the geometry below is a pure function a test can state; plus
  `underPointer()`, which picks the screen the user is looking at), and
  `IslandMetrics` (`Shell.notch(cutout:)` or `Shell.pill`, `centerX`,
  `topEdge`, `collapsedHeight`, `frame(for:)`). Both `nonisolated` value types.
  The cutout is derived from the gap the two auxiliary areas leave between
  them — `safeAreaInsets.top` gives only its height — because it differs by
  machine: measured 185 × 32 on a 14" M4 Pro.
- `IslandShellFace` (the six faces the design draws, as silhouettes;
  `resolve(detection:phase:)` composes detection's face with the session's
  phase, and `expandsOnItsOwn(detection:)` says which open with no pointer on
  them) and `IslandShellGeometry` (shell size, the margin the flares or the
  pill's shadow need inside the window, radius, cutout width, and
  `panelFrame(on:)` — which rounds, because a window origin is whole points and
  the cutout's centre is not).
- `IslandShellShape` (square at the top, rounded at the bottom, a concave flare
  outside each top corner) and `IslandShell` (the chrome: the black, the two
  ears and the row).
- `IslandController` (`@Observable @MainActor`: `face`, `isExpanded`,
  `metrics`, `start()`/`stop()`), `IslandPanel`. The controller is also the one
  place detection and the session meet — neither package can observe the other
  — so it reports `recordingChanged` and `hoverChanged` down, once per change
  each.
- `IslandHoverView` (internal: the `NSTrackingArea` that is the only mechanism
  by which a panel that never becomes key learns about the pointer — spike #69
  measured `acceptsMouseMovedEvents` delivering nothing at all) and
  `HoverGrace` (internal: crossings into presence, with the design's grace on
  the way out). Hover is crossings only; where the pointer is inside the island
  is not knowable and nothing is built on it.
- `IslandWindowTransition` (internal: the window is not part of the spring, so
  it takes the union of where the shell is and where it is going, and is
  trimmed when the spring settles — a window cut to the shell would clip the
  animation at its own edge).
- `IslandGallery` (DEBUG): every face, collapsed and expanded, on one sheet.

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
| Island face, deadline | `CallDetector` (CallDetection), composed by `IslandController` (Island) | Detection's face is the machine's output and its deadline is the real one a countdown renders. The island composes that face with the session's phase into the silhouette it wears — a pure resolver, not a second copy. |
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
      builds SwitchingAECStage, monitors, gap trackers, RetainedAudioWriter (staging dir)
      MicrophoneCapture / SystemAudioCapture callbacks:
         levels  → RecordingSession (main actor)
         mic     → SwitchingAECStage.processMicSamples (sync) → RetainedAudioWriter (actor)
         system  → RetainedAudioWriter (actor), and a read-only copy to feedFarEnd
                   (a scoped session runs a second, global tap for that copy alone)
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
   `Packages/Audio/Vendor/WebRTCAPM.xcframework`, declared as a binary target;
   the one ObjC++ seam becomes the `WebRTCAECBridge` C target, which reads both
   upstream header roots from inside the xcframework so the repository carries
   one copy of the headers and one of the archive. `Vendor/webrtc-apm` keeps
   `VERSION` and `licenses/`, and the root `Vendor/` directory is deleted).
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
