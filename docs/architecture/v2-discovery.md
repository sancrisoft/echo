# Echo v2 — Discovery

Date: 2026-09-08. Source: the `main` branch at `68632af` (v0.0.13), the GitHub
issues #44–#156, the internal design (not in the repository), and the local
planning board under `.conduct/` (gitignored). Every file reference below points
at `main`; read it with `git show origin/main:<path>` after a
`git fetch origin main`, so a stale local ref cannot answer in its place.

This document separates **what the product does** from **how the PoC does it**,
so that v2 can be designed from the product and not from the code. It is not an
exhaustive tour of the legacy tree.

---

## 1. What Echo is today

Echo is a macOS menu bar app (no Dock icon) that records a meeting from any
app, transcribes it on-device after the meeting ends, and writes a Markdown
summary grounded in the transcript. Nothing leaves the Mac except two one-time
model downloads from Hugging Face and an optional daily version check against
GitHub releases.

Requirements as shipped: Apple Silicon, macOS 15.6+, Xcode 26.6 to build,
arm64 only (MLX and the vendored WebRTC library are arm64-only), ad-hoc signed,
not notarized, installed with `curl … | bash`.

### 1.1 The product axiom

The microphone is **You**. System audio is **Others**. The two streams are
captured, processed, retained, transcribed and displayed separately and are only
merged, by timestamp, into one transcript. Speaker attribution is *the channel*,
never diarization. There is no diarization anywhere in the product and SpeakerKit
was never shipped.

### 1.2 Features that actually exist

| Area | What the user gets |
|---|---|
| Capture | Mic via `AVAudioEngine`; system audio via **Core Audio process taps** (not ScreenCaptureKit: no purple indicator, DRM playback keeps working). A tap can cover everything or be scoped to one call app's process set. WebRTC AEC3 removes the meeting's playback from the mic track. Live per-channel levels. |
| Capture defenses | Bluetooth headsets that declare 48 kHz and deliver 24 kHz are detected from the audio itself and corrected gaplessly; output-route changes rebuild the tap; input-device loss degrades to Others-only with one notice; sustained unusable input raises a health notice; capture gaps are declared so the timeline never shifts. |
| Retention | During recording both channels stream to AAC files in a staging folder; gaps are written as silence so file position equals recording time. At stop the audio moves into the meeting folder and **is** the "pending transcription" marker. |
| Transcription | After stop, one batch pass per channel with **Parakeet TDT 0.6B v3** through FluidAudio (Core ML, ~480 MB). Segments are cut on audio silence and token gaps, never mid-word. Mic segments that are echo of an Others segment are suppressed (asymmetric, keep-on-doubt dedup). Both channels merge by timestamp. |
| Finalization lifecycle | A pure state machine admits passes (never while recording, never while a summary streams), retries twice per run, treats preemption as deferral not failure, converges to a terminal failure that keeps the audio for a manual retry, and resumes pending meetings at launch by scanning the folders. |
| Summary | **Qwen3.5 4B OptiQ 4-bit** through MLX (~3.3 GB). Transcripts ≤ 8 000 estimated tokens get a single pass; longer ones are chunked, mapped to NDJSON facts with evidence segment IDs, merged deterministically, then reduced to one Markdown document. Adaptive sections, an Action Items checklist, owners only when someone explicitly took the task, never invented dates, language follows the transcript, small talk omitted. Streams into the UI. `summary.md` is the store. |
| Summary scheduling | Auto after finalization (toggle), manual request, and a backfill scan (launch, each stop, dashboard open, model download completion) that summarizes one meeting at a time, newest first, only when the model is already on disk. |
| Model delivery | Byte-honest resumable download with sha256 verification, stall watchdog with three attempts, byte-weighted progress, a completeness manifest that fails safe, pause/resume persisted across relaunch, a 6 GB free-disk floor, and launch-time deletion of retired models by name. Parakeet downloads through FluidAudio with the same stall guard. Recording never waits for a model. |
| Library | One folder per meeting under `~/Library/Application Support/Echo/Meetings/<uuid>/` with `meta.json`, `transcript.json`, `summary.md` and optional preserved `audio-*.m4a`. List grouped by date, search over title/caption/date, four sort orders, rename, trash with 30-day purge, restore, permanent delete, export to Markdown or plain text, copy summary, reveal in Finder, keep/delete/re-transcribe the preserved recording, storage breakdown. |
| Call detection | Watches which processes hold the microphone (Core Audio process metadata, no permission). A curated catalog (Zoom, Teams, Slack, Discord, FaceTime's daemon, Webex, browsers) plus every installed browser (LaunchServices `https` handlers). After a 3 s debounce a floating non-activating island offers to record that app's audio. It never starts on its own. When the call ends during a recording, a 30 s grace countdown stops the recording unless the user keeps it. |
| Settings | `settings.json` (never UserDefaults): call detection on/off and per-app, keep recordings, auto-summaries, auto update check; launch at login via `SMAppService`. |
| Updates | Daily check of the latest GitHub release; "Update available" in the popover; Settings › Updates with Check, release notes and **Update Now**, which quits Echo, runs the install script and reopens. |
| Diagnostics | Every error surface goes through `ErrorTrace.record`, which mirrors to `os.Logger` and appends NDJSON to `Logs/errors-<UTC day>.ndjson`, pruned after 14 days. |
| Shell | Menu bar popover (record/stop, levels, scope picker), a dashboard window (sidebar, list, detail with Transcript/AI Summary tabs, Trash, Settings page), ⌘, lands on the Settings page, Dock/Cmd-Tab presence only while the dashboard is open. |

### 1.3 User flows

1. **Record** from the popover, the dashboard toolbar, or the island. Permissions
   are requested on the first record gesture, sequentially (mic, then system
   audio), never at launch or behind a download.
2. **Stop** returns as soon as the meeting is persisted; transcription and summary
   run afterwards and the UI shows honest states: *Recording*, *Waiting to
   finalize*, *Finalizing N%*, *Transcription failed* (Retry), *Processing*
   summary, *Processed*.
3. **Read** a meeting: Summary tab (streams while generating) and Transcript tab
   (turns merged per speaker, backchannels dropped). No live transcript ever
   exists; the footer says "Recording…", never "Transcribing…".
4. **Manage**: rename, export, copy, trash, restore, delete, re-transcribe from a
   preserved recording, delete recordings, empty trash.
5. **First run**: dismissible privacy banner; both models download in the
   background with real progress, pause/resume for the summary model; nothing
   blocks recording.

### 1.4 Redesign intent (not yet built)

A redesign of the whole surface exists as an internal design (not in this
repository; see `CLAUDE.md`, "Design") and as the GitHub epics #44–#125. In
outline: the floating island becomes the primary live surface and the menu bar
popover goes away; the main window keeps meetings in a sidebar with the document
always beside them; a design system replaces per-view styling; first run gets a
path of its own. Several design decisions are still open on the board.

---

## 2. How the PoC is built

### 2.1 Shape

- One Xcode project, two targets: `Echo` (app) and `EchoTests` (hosted in
  `Echo.app`). Sources are 71 flat files in `Echo/` (23 590 lines) plus
  `Echo/AEC/`. Tests are 81 Swift Testing files (~867 `@Test`, no XCTest).
- Swift language mode **5**, `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`,
  approachable concurrency on, strict concurrency off. The baseline build on
  this machine succeeds with 99 warnings; most are isolation violations that are
  errors in Swift 6 mode.
- External packages: FluidAudio 0.15.5, mlx-swift 0.31.6, mlx-swift-lm 3.31.4,
  swift-transformers 1.3.3, swift-huggingface 0.9.0, plus transitive deps
  (Package.resolved has 17 pins). WebRTC audio-processing v2.1 (AEC3) is
  vendored as a static library under `Vendor/webrtc-apm` and reached through
  one ObjC++ bridge (`Echo/AEC/APMEchoCanceller.mm`) via a bridging header.
- Project-level deployment target says 26.5, targets say 15.6; the targets win.
  No `.xcconfig`, no lint or format configuration anywhere.

### 2.2 The two hubs

Everything meets in two objects:

- **`RecordingController`** (1 821 lines, `@Observable @MainActor`) owns the
  capture sources, AEC, device and route monitors, gap accounting, retention,
  finalization, both model managers, the summarization pipeline, summary
  backfill, permission priming and launch tasks. It is the app's only
  environment object: every view reaches `controller.state.*`,
  `controller.library.*`, `controller.finalization.*`. Its `init` has no
  injection seams, so there are **no tests for the orchestration**; everything is
  tested one layer down.
- **`DashboardView`** (2 934 lines) holds 24 private view types, the filter and
  date-grouping logic, an AppKit event monitor, the display-state assembler, and
  ~195 lines of `#if DEBUG` screenshot harness inside `body`. Two ~150-line list
  implementations (Meetings, Trash) are near-verbatim copies.

Around them, the PoC is actually well factored into **pure, table-tested
machines**: `FinalizationMachine`, `CallSessionMachine`,
`InputDeviceLifecycleMachine`, `EchoModeMachine`, `InputHealthClassifier`,
`CaptureRateGuard`, `EchoDedupPolicy`, `TranscriptUtterance`,
`MeetingDisplayState`, `MeetingListNavigation`, `SummaryMerge`,
`ChunkAssembler`, `MarkdownDocument`, `ScopedProcessResolution`,
`ResumableFileDownload.resumeDecision`, `SnapshotManifest`. These are the parts
worth carrying forward as-is.

### 2.3 Isolation and concurrency

- Actors: `MeetingStore`, `LiveInputMonitor`, `RetainedAudioWriter`,
  `ParakeetModelManager`, `SummaryModelManager`, `SummarizationPipeline`,
  `ErrorTraceLog`.
- `@MainActor @Observable`: `RecordingController`, `RecordingState`,
  `MeetingLibrary`, `FinalizationCoordinator`, `AppSettings`,
  `CallDetectionController`, `UpdateChecker`.
- `@unchecked Sendable` + `NSLock` for anything touched from audio threads:
  `WebRTCAECStage`, `SwitchingAECStage`, `CaptureGapTracker`,
  `ChannelFrameCounter`, `InputHealthTracker`, download tallies and sinks.
- **The bug class the defaults created:** with main-actor default isolation,
  `MicrophoneCapture`, `SystemAudioCapture`, `InputDeviceMonitor`,
  `OutputRouteMonitor` and `MicActivityMonitor` are implicitly `@MainActor`, yet
  their closures run on the AVAudioEngine render thread and on the Core Audio IO
  queue. Swift 5 mode compiles this clean. `SystemAudioCapture` even documents an
  "everything mutates on `ioQueue`" invariant that `activate()` and `stop()`
  violate from the main actor. Pure value types that forgot `nonisolated`
  (`TranscriptChunker`, `EchoDedupPolicy`) force `MainActor.run` hops from
  actors to do arithmetic.
- One unstructured `Task` per capture callback (~86/s on the system channel) is
  how samples reach the actors; ordering relies on actor seriality plus keeping
  gap+ingest+append in one task.
- No Combine anywhere.

### 2.4 Persistence

Single data root `~/Library/Application Support/Echo` (decision 2026-07-13:
uninstall = delete the app + this folder; no UserDefaults, no `~/Documents`).

```
Echo/
├── Meetings/<uuid>/   meta.json · transcript.json · summary.md
│                      [summary.json legacy] · audio-{mic,system}.m4a (preserved)
│                      retained-{mic,system}.m4a (pending) · debug-kept-*.m4a
├── Meetings/.retention-staging/<session>/retained-*.m4a
├── Models/models/mlx-community/Qwen3.5-4B-OptiQ-4bit/   (HubApi layout)
├── Models/parakeet-tdt-0.6b-v3/                          (FluidAudio layout)
├── Models/summary-model-manifest.json · summary-model-download/*.partial
├── Logs/errors-YYYY-MM-DD.ndjson · update.log · update-failed.txt
├── settings.json
└── summary-download-state.json
```

`meta.json` (`MeetingMeta`): `schemaVersion` (always 1, never validated), `id`,
`title`, `startedAt`, `endedAt`, `segmentCount`, `hasSummary`, optional
`wordCount`, `oneLineDescription`, `transcriptProvenance {source, modelName,
tier, servedByFallback}`, `summaryModelName`, `captureScope {kind, appName}`,
`trashedAt`. Optional fields are `encodeIfPresent`, so untouched old files stay
byte-identical. `transcript.json` is a bare array of `TranscriptSegment {id,
channel, speaker, text, start, end}` with tolerant decoding (unknown speaker →
channel default). `summary.md` is the summary; `summary.json` is read-only
legacy that a launch task folds into `summary.md` (write first, delete after,
never delete the only artifact).

Writes are atomic and ordered (transcript → summary → meta last). Deletions are
named targets, never sweeps. The audio file *name family* is the state:
`retained-*` means pending, `audio-*` means preserved (never auto-resumed),
`debug-kept-*` is invisible to the scan.

### 2.5 Tests and fixtures

- All tests run **hosted inside the real app**. `TestHost.isActive`
  (`NSClassFromString("XCTestCase")` or any `XCTest*` env key) gates six launch
  sites. It exists because on 2026-08-06 a hosted test run booted the full launch
  path against the real data folder while a real Echo was recording and deleted
  a live meeting's `meta.json`. `TestHostGuardTests` is the single tripwire.
- Gates: `TEST_RUNNER_ECHO_ACCEPTANCE=1` (real models, `.serialized`),
  `ECHO_AEC_SPIKE`, `ECHO_REPLAY_DIR`, plus fixture presence. Missing fixture →
  skip with instructions, never a failure.
- `Fixtures/` at the repo root is gitignored (~103 MB of real dual-channel
  recordings for 11 scenarios plus two meeting transcripts). It lives at the
  root because `EchoTests/` is a synchronized group and every scenario's
  `mic.wav` would flatten onto one bundle path. `Fixtures/README.md` is cited by
  five files and does not exist.
- `~/EchoAccuracyFixtures/` (outside the repo, one machine) feeds the WER
  harness; its baseline is unreproducible elsewhere.
- CI (`macos-26`, Xcode 26.6 + Metal toolchain) builds Debug and runs the
  ~830 ungated tests serially. No caching, no lint, no UI tests, no tap
  integration test.

### 2.6 Git and process

Conventional commits since 2026-06-29 with the branch topic as scope; `build/*`
branches off `main`, `gh stack` stacks; 14 tags `v0.0.1`…`v0.0.13`; hotfix tags
rebuild inside the version they fix. Releases are ad-hoc signed zips built by CI
from tags. The public repo has an 82-ticket v2 board (#44–#125) and 20
install/OSS tickets (#126–#145); #156 asks for repository skills that encode
the measured knowledge below.

---

## 3. Code vs. legacy documentation

| Legacy document says | Code does |
|---|---|
| `AGENTS.md`/`CLAUDE.md` (symlink): WhisperKit for STT | Parakeet TDT 0.6B v3 via FluidAudio since 2026-08-06; WhisperKit caches are deleted at launch as retired models |
| SpeakerKit for diarization | No diarization exists; `Speaker` is derived from the channel |
| ScreenCaptureKit for system audio | Core Audio process taps; ScreenCaptureKit appears only in a DEBUG screenshot harness |
| Summary = short summary, detailed summary, decisions, action items, open questions, risks | Summary = one adaptive Markdown document; the fixed fields survive only as a legacy `summary.json` decoder and an in-memory facts snapshot on the long route |
| `README.md` | Accurate for install/update/uninstall and mostly accurate for the stack; says "proof of concept" |
| Test headers cite SP-00x / SPEC-0x / ADR-0xx / BRN-00x | Those documents were local-only (`.conduct/`, gitignored) and `specs/` is empty; the test headers and code comments are the only committed record |

`CLAUDE.md -> agents.md` is a symlink to a file that has been wrong about the
stack since 2026-06-29. It must not survive into v2.

---

## 4. Dependencies and integrations

| Dependency | Used for | Notes |
|---|---|---|
| FluidAudio 0.15.5 (Apache-2.0) | `AsrModels`, `AsrManager`, `ASRConfig`, `TdtDecoderState` | Batch transcription; chunks long audio internally at ~15 s windows; `melChunkContext: false` + `dualDecodeArbitration: true` fixed Spanish→English drift |
| mlx-swift 0.31.6, mlx-swift-lm 3.31.4 (MIT) | Load and run Qwen3.5 4B | Metal shaders compiled at build time (needs the Metal toolchain); `MLX.GPU.set(cacheLimit:)`; no memory ceiling exists, memory is bounded by admission |
| swift-transformers 1.3.3 (`Hub`) | Repo metadata, config snapshot, local repo layout | `HubApi` is a swift-transformers product, not a swift-huggingface one; it pulls swift-huggingface 0.9.0 transitively (`from: "0.8.1"`, so a v2 package pins it). `HubApi(downloadBase:, cache: nil)` is mandatory; the async download API never fires its delegate on this OS, which is why Echo owns its transport |
| swift-transformers 1.3.3 (`Tokenizers`) | Tokenizer for ChatML | Same package as `Hub` above. `applyChatTemplate` deliberately throws; the template is built in code |
| webrtc-audio-processing v2.1 (BSD-3) + abseil | AEC3 | Static arm64 library, one ObjC++ seam, AEC3 only with seven features explicitly off |
| Models | Parakeet (CC-BY-4.0, attribution shown in-app), Qwen3.5 4B OptiQ (Apache-2.0) | Downloaded at runtime, never redistributed |
| GitHub | Release feed, install script, Update Now | The only network endpoints besides Hugging Face |
| Core Audio, AVFoundation, `ServiceManagement`, `NaturalLanguage`, `CryptoKit` | Capture, files, launch at login, language detection, sha256 | |

Permissions: microphone (`NSMicrophoneUsageDescription`) and system audio
recording (`NSAudioCaptureUsageDescription`, prompted by running a throwaway
tap). App Sandbox is **off** because process taps return silence under it; the
app cannot ship on the Mac App Store and that is accepted.

---

## 5. Problems in the PoC

Grouped by what they cost, not by file.

1. **Orchestration is untestable and fused with UI state.** `RecordingController`
   constructs its collaborators inline; the four-path balance invariants
   (`noteRecordingStopped`/`notePostStopWorkFinished`,
   `beginSummaryWork`/`endSummaryWork`) are held by convention across 116-line
   methods; `sessionGeneration` guards are repeated at ~8 sites; three capture
   wiring methods are near-duplicates.
2. **Declared isolation lies.** Implicitly main-actor capture classes run on
   audio threads. A v2 in Swift 6 mode cannot compile this; the fix is
   structural, not annotation.
3. **The UI knows the engine's internal composition.** Three-level chains
   (`controller.library.storageBreakdown?.trashBytes`), model-manager statics
   named from views, `SettingsView` bypassing `CallDetectionController` to reach
   the catalogs directly, `CallDetectionController` missing from the dashboard
   environment, two dashboard-open paths, a retain cycle between the island panel
   and its controller.
4. **Multiple sources of truth in the UI.** `MeetingLibrary.selection` is dead;
   each list triple-tracks selection/hover/right-click; `library.section` and
   `opened` are synced by hand in two places; `selectedTab` diverges from
   `opened.tab`; search and sort reset when the view remounts; recording state is
   read three ways.
5. **Business logic in views.** The display-state assembler, filter, date
   grouping, status-pill remap, five-way idle-summary policy, trash-retention
   arithmetic, byte totals, `SMAppService` calls and three copies of the
   summary-model presentation switch all live in view files, untested.
6. **No design system.** One color token (`Color.echoIndigo`) declared in the
   waveform file; empty `AccentColor` asset; inline radii/paddings/opacities;
   24 private components in one file; duplicated formatters, gradient, menu
   labels, confirmation dialogs.
7. **Read paths that write.** `MeetingLibrary.refresh()` purges trash and
   rewrites metas; a popover render calls it. Every mutation triggers a full
   rescan plus a recursive directory-size walk.
8. **Facts are lost on reload.** `summary.md` stores only Markdown; decisions,
   actions and evidence IDs exist in memory for the generating process only, and
   the single-pass route never extracts them. `rag_index.json` is deleted but
   never written.
9. **Dead and stale code.** Live dedup in `RecordingState.append`, the
   `liveFloor`/draft UI for meetings nothing can produce, `PassthroughAECStage`'s
   "until S2 lands" comment, `AudioCaptureSource` as an unused abstraction,
   `EchoPaths.migrateLegacyWhisperKitCacheIfNeeded` (never called), NDJSON
   validator types for a retired protocol, orphan doc comments, `SettingsView`
   describing a removed scene.
10. **Debug instrumentation in production files.** Nine `ECHO_*` env vars read
    from nine files; ~195 lines of screenshot harness in `DashboardView.body`;
    a fixture recorder with `NSOpenPanel` in the popover.
11. **Model delivery is asymmetric.** The resumable transport, tally, manifest
    and disk floor are LLM-only; Parakeet gets file-count progress. The Parakeet
    `modelDirectory` constant names a folder (`…-coreml`) that never exists.
12. **Repository hygiene.** `.gitignore` line 36 concatenates two patterns
    (missing newline), so `meetings_sample/` — real meeting transcripts — and a
    generated report are **not ignored**; `.agents/` and `.claude/` are
    untracked and unignored; `Packages/EchoEngine` and `Packages/EchoUI` on disk
    are empty `.build` shells from an earlier v2 attempt; `Fixtures/README.md` is
    missing; the project-level deployment target contradicts the targets'.
13. **Unbounded or leaky side effects.** `Logs/update.log` grows forever; the
    updater script is written outside the data root; `modelsDirectory` creates
    the folder on every read; the error-trace append is fire-and-forget and can
    lose records at teardown.
14. **Open defects.** The Others channel is systematically 4–8 % short of the
    meeting (a forensic apparatus lives permanently in the stop path); the AEC
    pre-pass deletes a fifth of the user's words and is disabled; a
    `TranscriptChunkingTests` case is known red per the board; the small-talk
    omission rule holds ~2/3 of runs on the 4B model.

---

## 6. Risks for the rewrite

- **Losing measured constants.** Nearly every number in capture, dedup,
  segmenting, chunking, prompting and download was arrived at by measuring real
  calls, and the reasons live only in comments. Re-deriving them from first
  principles will be wrong. Section 7 lists them; the port must carry the
  comment with the constant.
- **Data compatibility.** v2 must open the existing library with no migration:
  same folder, same `meta.json`/`transcript.json`/`summary.md`, tolerant of
  legacy `summary.json`, legacy speaker encoding, pre-SP-007 metas, and the three
  audio name families. Writing a byte-different `meta.json` for an untouched
  meeting is a regression the PoC's tests already guard.
- **Swift 6 exposes real races.** The audio classes cannot be ported by adding
  `nonisolated`; they need an explicit threading model (a capture source is a
  `Sendable` object whose callbacks are `@Sendable` and whose state is behind a
  lock or an actor, with the IO-queue invariant actually upheld).
- **The test host.** Hosted tests once destroyed a meeting. Package tests
  (`swift test`) run in no host at all and remove the risk for everything that
  isn't the app target; the app's own tests still need the guard, and inits must
  stay side-effect free so the guard has one door.
- **macOS 26 UI traps** are paid for and undated: `NavigationSplitView`'s rigid
  fitting height, sidebar `List` rendering zero rows, `List(selection:)`
  double-painting with a custom card, `simultaneousGesture` swallowing the first
  click, non-key windows dropping accent fills, `isFloatingPanel` resetting the
  panel level, wallpaper-tinted materials under flat colors, `willClose` firing
  before the window leaves the visible set.
- **Tooling churn.** mlx-swift needs the Metal toolchain; FluidAudio pins;
  `swift-huggingface`'s delegate bug; all three can move under a rebuild.
- **Branch naming.** GitHub already has `v2/main` and `v2/bootstrap-*`; a
  branch literally named `v2` cannot coexist with them in the same ref
  namespace. Locally the old ones were renamed to `attic/v2/*`; pushing `v2`
  requires deleting or renaming the remote `v2/*` branches first.

---

## 7. Behaviors to preserve

These are product behaviors and measured defenses. Each carries a reason; the
reason must travel with the code into v2.

### Capture

- **Two streams, one timeline.** Channel is the speaker. AEC only *reads* the
  system stream as far-end reference and never writes into it. Scoped sessions
  run two taps: a scoped tap for ingest and a second global tap that feeds only
  the AEC far end.
- **Canonical format 16 kHz mono Float32** everywhere downstream of capture.
- **Bluetooth sample-rate lie (BRN-006):** measure the delivered rate against
  two clocks (delivered frames and the device sample clock); a window is judged
  only when both say the stream was continuous; tolerance is **2 %** (a Meet call
  at 512 frames/11.62 ms declared 48 kHz left Others 8 % short under 10 %);
  correction relabels the format, gaplessly, no tap rebuild; disproved rates are
  remembered so a stale notification cannot flip-flop the correction budget.
- **Global tap: never touch `isExclusive`** — flipping it inverts the process
  list semantics and the tap delivers silence.
- **Max-magnitude mono downmix**, not averaging (multi-transmitter USB receivers
  report no channel layout; averaging attenuated a lone transmitter by 6 dB).
- **No input device degrades, never crashes;** same-device events are no-ops;
  recovery from degraded restarts even to the same device ID.
- **Capture gaps are declared** to the clock (the Others tap is deaf for seconds
  during bring-up; an undeclared hole shifts every later timestamp earlier).
  Gaps are measured with `ContinuousClock`, never `Date`.
- **Retention is timeline-faithful and subordinate:** gaps written as silence;
  any write failure disables retention for the session without touching capture;
  a truncated retention file must never feed a pass.
- **AEC:** pass-through modes are bit-identical; degraded keeps the engine fed
  so it can detect recovery; re-engaging resets first; a failed frame emits the
  raw input; engine failure never ends a recording; at most one notice per
  episode. IO-cycle work is measured at 0.1 % of the 10.67 ms budget and the IO
  queue is `.userInteractive` because missing the cycle lost ~8 % of a meeting.
- **Route classification is conservative** (ambiguity → unsupported) and is
  reported before the device change so echo mode is right when the tap rebuilds.
- **Scoped capture is by process set** (never PID, never bundle ID alone);
  identity is the outermost `.app` on the executable path (Gecko helpers share no
  bundle prefix); an empty include set is legal; a failed follow-write keeps the
  last-good set; if either tap fails the session collapses to global **visibly**
  ("Everything").
- **Level meters are measured in seconds, never callbacks,** and driven only by
  real capture (never simulated).

### Transcription

- **One batch pass per channel after stop**; model loaded once per pass;
  `melChunkContext: false` and `dualDecodeArbitration: true` (Spanish decoder
  drift: English function words on You fell from 17 % to 10 %); `language: nil`.
  Whisper-era compensating heuristics (A/B verdicts, evidence gates, tail pads)
  were measured to translate Spanish into English and are gone on purpose: if
  quality disappoints, the model changes, not a heuristic.
- **Segment boundaries come from the audio:** 0.6 s token gap (a 0.7 s pause
  was real), 0.3 s silence split at the *start* of the silence, 12 s soft max at
  a word start; cuts are latched and never shear a word; leading punctuation
  moves back except a lone mark; wordless rows are dropped; silence floor 0.002
  is safe here because it only places boundaries.
- **Dedup (ADR-003 v2):** asymmetric (only mic candidates), interval-overlap
  linking with directional containment, pooled Others tokens, energy evidence
  only ever assists a weak text match, own-voice rescue checked before every tier,
  keep on doubt, every suppression logged.
- **Speaker is persisted as a plain string** with tolerant decoding and the
  legacy object form accepted forever.
- **Finalization:** never while recording or while a summary streams; a running
  pass yields within one decode window when a recording starts and that is a
  deferral, not an attempt; two attempts per run; terminal failure keeps the
  audio and needs a manual retry; crash-resume is a folder scan classified by
  audio name family and provenance; cleanup is by named file.
- **Progress is one clamped, monotonic number** (ADR-007) that resets per
  meeting-attempt.

### Summary

- **Grounding:** long route drops any fact without a real evidence ID; the
  reduce prompt introduces nothing not in the material; empty sections are never
  written; owners only when someone took the task; never an invented date;
  small talk omitted in both the shared rules and the closing reminder (the rule
  in the system prompt alone leaked 6/6); language detected across the whole
  transcript with a 0.6 floor and stated twice (the 4B drifts to English
  otherwise).
- **Routing:** ≤ 8 000 estimated tokens single pass, else map (in series, one
  engine) → deterministic merge → reduce; grounded content beats an error (an
  empty reduce keeps the facts-only summary); a cut-short stream never persists.
- **ChatML built in code** (ADR-010), thinking disabled, `<|im_end|>` as the
  stop token; penalty windows widened to 64; the Markdown preset drops the
  NDJSON penalties that punished checkbox prefixes.
- **Weights never resident without work** (ADR-008): download ≠ load; 60 s idle
  release; force-unloaded before every finalization pass; never loaded during
  recording.
- **The parser is lenient by contract:** any prefix parses, never throws,
  prefix-stable, unclosed delimiters style to end of block.
- **`summary.md` is the store;** a summary that resolves to no Markdown claims
  nothing on the meta.

### Model delivery

- Byte-honest, self-owned resumable transfer (the framework's delegate never
  fires on this OS); a 200 to a Range request truncates and restarts; file sizes
  via `FileManager`, never `URL.resourceValues`; sha256 against the etag; partials
  outside the Hub repo dir; completeness is a verified manifest that fails safe
  (missing, foreign, or empty → incomplete); progress is byte-weighted; only a
  genuine stall retries (stalled *and* our cancellation); pause is a persisted
  intent recorded before cancelling; retired models are deleted by name, never by
  sweep; disk floor 6 GB; recording never waits for a model.

### Library and settings

- Single data root; additive, tolerant, byte-stable schemas; `meta.json` written
  last; an empty transcript is not written; absent ≠ corrupt; `summary.md` wins
  over `summary.json`; one bad folder never breaks the list; trash keeps every
  file; preserved recordings are never consumed by a re-transcribe (copy, not
  rename); turning retention off never deletes existing recordings; settings are
  decoded key by key (a synthesized decoder resets every preference the first
  time a key is added); launch-at-login reads `SMAppService`, never a mirror.
- Deterministic, locale-independent titles and sorted-key JSON.

### Call detection and island

- Nothing records without an explicit click (single emission site, proven over
  all four-event sequences). A recording that overlaps a call never runs
  unbounded after the call ends. 3 s debounce, 30 s grace, 15 s prompt retract,
  8 s saved retract. Reconnect inside the grace cancels the stop silently with
  no re-debounce. A manual stop mid-call is not re-prompted. "Meeting saved" is
  shown only after `stop()` has persisted. Off means off (no listener).
- Detection is *not* "any app touching the mic"; an empty bundle ID never
  matches; native apps outrank browsers; FaceTime's capturing process is the
  `avconferenced` daemon and is not scopeable; browsers come from LaunchServices
  with locale-stable display names; the wildcard Core Audio listener address is
  required (the exact address never delivers on macOS 26); 80 ms coalescing.
- Panel: non-activating, all Spaces, above fullscreen, `level` set **after**
  `isFloatingPanel`, placed on the screen under the pointer, falls back to the
  menu bar thickness when the bar auto-hides, `orderFrontRegardless`, hand-painted
  controls because non-key windows drop accent fills, countdown from the
  controller's real deadline.

### Shell

- Closing the last window never terminates the app; Dock/Cmd-Tab presence
  tracks the dashboard window; no window restoration; the dashboard never opens
  at launch; ⌘, selects the section before opening; permissions on the record
  gesture; launch cleanups detached at utility priority; the test host must be
  inert; no live transcript is ever shown and no transcript-derived numbers
  appear while recording; a yielding pass reads as *waiting*, never a fake bar;
  a partial download never shows a byte figure; no `UserDefaults`; sandbox off.

---

## 8. Decisions we can discard

- The **PoC's file layout, target layout and two hub objects.** v2 has package
  boundaries and a session facade; `RecordingController` and `DashboardView` are
  not ported.
- **Swift 5 language mode and main-actor default isolation for engine code.**
- **The live-transcript remnants**: `RecordingState.append` dedup,
  `liveFloor`/draft UI, `LiveInputMonitor` as a chunker (it survives only as the
  input-health signal source and can be reduced to that).
- **The offline AEC pre-pass and bleed probe** (~570 lines, disabled, measured to
  delete 20–25 % of the user's words). Keep the measurement table in this
  document; do not port the code.
- **The fixed summary schema as a persisted format.** v2 persists Markdown; the
  legacy `summary.json` decoder is kept only to read old folders.
- **NDJSON validator types for the retired prose protocol** (`short`,
  `detailed`).
- **`EchoPaths.migrateLegacyWhisperKitCacheIfNeeded`** (never called) and the
  Whisper-era provenance fields beyond what tolerant decoding needs.
- **Debug harness in production views** (screenshot loop, env-var probes). v2
  centralizes launch flags in one configuration type and keeps UI probes out of
  `body`.
- **The popover as a surface** (per the redesign) — the menu bar item stays.
- **`CLAUDE.md` as a symlink to `AGENTS.md`**, and the legacy `AGENTS.md`.
- **Hosted unit tests as the default.** Package tests run without a host.
- **Recording accounting scaffolding in the stop path** (the 4–8 % shortfall
  investigation) — keep the *diagnostic counters* available, but as an
  explicit diagnostics hook, not permanent production metadata.

---

## 9. Measured constants (carry with their reasons)

| Constant | Value | Why |
|---|---|---|
| Canonical audio format | 16 kHz mono Float32 | what capture downmixes to, retention writes, the model consumes |
| Mic tap buffer | 4096 requested, 4800 delivered (100 ms @ 48 kHz) | macOS clamps; measured 2026-08-12 |
| System IO cycle | ~512 frames @ 48 kHz ≈ 10.67 ms | ~86–94 callbacks/s; queue must be `.userInteractive` |
| Rate-guard tolerance | 2 % | 10 % called an 8 % lie a match |
| Level window / stale | 0.06 s / 0.5 s | shorter than the mic cadence so averaging adds no latency |
| AEC frame | 160 samples (10 ms @ 16 kHz) | WebRTC APM frame size |
| Retention | AAC-LC mono 16 kHz 32 kbps | small, timeline-faithful |
| Segment gap / silence split / max | 0.6 s / 0.3 s / 12 s | measured pauses; latched cuts |
| Silence floor | 0.002 | true silence .0004–.0008, quietest bleed .003, speech > .02 |
| Dominance smoothing | ±300 ms | raw 100 ms frames cross constantly |
| Dedup | echo tail 2.5 s, text containment 0.6, assisted 0.35, rms ratio 0.5, min tokens 3, own-voice rescue 1.0 s | ADR-003 v2 fixtures |
| Backchannel merge | 10 s gap, ≤ 3 distinct words | vocabulary, not repetition |
| Single-pass budget | 8 000 tokens | matches `hardMaxTokens`; lost-in-the-middle beyond |
| Chunking | target 6 000, hard max 8 000, overlap 600, long gap 20 s, turn gap 8 s, min 800 | SPEC-02 |
| Generation (Markdown) | temp 0.4, topP 0.95, max 4096, rep 1.05, freq 0, pres 0, penalty window 64 | checkbox prefixes were being penalized |
| Generation (NDJSON) | temp 0.3, topP 0.9, max 3072, rep 1.1, freq 0.6, pres 0.3 | |
| Caption | max 64 tokens, temp 0.2, source stripped before a 1 200-char cap | |
| Language detection | stride ~3 000 chars across the meeting, confidence ≥ 0.6 | greeting must not mislabel the meeting |
| Idle release | 60 s | ADR-008 |
| Disk floor | 6 GB | sized for the 4B, not the retired 12B |
| Download retry | 3 attempts, 60 s stall, 5 s watchdog, request timeout 120 s | |
| Call detection | debounce 3 s, grace 30 s, prompt retract 15 s, saved retract 8 s, coalesce 80 ms, browser cache 60 s | |
| Trash retention | 30 days | |
| Log retention | 14 days, UTC rotation | |
| Update check | 30 s after launch, then every 24 h, 15 s request timeout | |
| Island motion | spring response 0.38, damping 0.86 | |

---

## 10. What this means for v2

1. The product is the twelve capabilities in §1.2, not the two hubs in §2.2.
   Those capabilities are the candidate package boundaries.
2. The pure machines and the measured constants port; the orchestration and the
   UI are rewritten against one session facade and a design system.
3. Swift 6 language mode from the first line, with isolation stated explicitly
   in engine code and main-actor by default only in UI packages.
4. Package tests replace hosted tests wherever the app is not needed; the app's
   own tests keep the host guard, and side effects start only from the
   composition root.
5. v2 reads and writes the same data folder as v1 with no migration; parity on
   an existing library is the acceptance test for the first feature.
6. The repository hygiene items in §5.12 are fixed on day one (gitignore, stale
   shells, missing fixture README, deployment target).

The architecture that follows from this is in `v2-architecture.md`.
