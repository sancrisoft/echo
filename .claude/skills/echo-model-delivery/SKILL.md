---
name: echo-model-delivery
description: Downloading, caching, loading and retiring Echo's on-device models — `SummaryModelManager`, `ParakeetModelManager`, `ResumableFileDownload`, `SnapshotDownloadTally`, `SnapshotManifest`, `ModelDownloadProgress`, `ModelDownload.withStallRetry`, `RetiredModelCleanup`, `EchoPaths`, and symptoms like a stalled or 87.5%-stuck download, a "Ready" model that never loads, or files written outside the data folder.
---

## One data folder, no exceptions

Everything Echo writes lives under `~/Library/Application Support/Echo/` (`EchoPaths`) so uninstall is deleting the app plus one folder. **No UserDefaults for anything** — even the download pause state goes to `summary-download-state.json` (`EchoPaths.summaryDownloadStateFile`).

The Hub client must be constructed as `HubApi(downloadBase: EchoPaths.modelsDirectory, cache: nil)`. **`cache: nil` is mandatory** — the default `HubCache` writes outside the folder (`SummaryModelManager.swift:712-718`).

Two model layouts coexist, and mixing them up costs a re-download:
- Summary model: HubApi's `downloadBase/models/<org>/<repo>`.
- Parakeet: **flat** under `Models/`. FluidAudio resolves `download(to:)` / `load(from:)` / `modelsExist(at:)` against `<parent-of-directory>/<repoFolderName>`, so the one constant passed everywhere already ends in the repo folder name (`ParakeetModelManager.swift:14-15`, `:66-68`).

## The Hub's progress API is dead on this OS — own the transfer

`URLSession.download(for:delegate:)` never invokes its delegate on macOS 26. Measured against the real 3.27 GB weight file (`ResumableFileDownload.swift:12-25`):

```
task-scoped delegate  → 285 MB in 45 s, 0 progress callbacks
session-scoped one    → 144 MB in 15 s, 0 progress callbacks
classic dataTask      → 193 MB in 10 s, 7080 progress callbacks
```

Injecting a session does not help; the async API is the problem, and upstream has not fixed it (huggingface/swift-huggingface #50, #48, #52, #61) — **do not wait for a package bump**. The consequence was fatal, not cosmetic: a frozen fraction tripped the 60 s stall watchdog, three attempts later the user got "The download stalled and made no progress", deterministically, on every machine, for any file needing over a minute.

So the weight files ride `ResumableFileDownload` (dataTask + session delegate, `Range: bytes=N-` into a `.partial` Echo owns), and only the small configs stay with `HubApi.snapshot`. Verified resume: interrupted at 192,925,517 bytes, resumed with HTTP 206 from exactly there. A committed file is checked against the sha256 the repo published — for LFS files the Hub etag **is** the content sha256 (`SummaryModelManager.swift:599-612`). A `.metadata` sidecar is written so the Hub still recognises the file.

## Progress must be byte-weighted and single-sourced

The Hub's own fraction counts **file count** (`Progress(totalUnitCount: filenames.count)`), so 19 MB of configs — 0.6% of the bytes — filled 87.5% of the bar and 3.27 GB had to fit in the last eighth. `SnapshotDownloadTally` weights each file by the size the repo reports, and confines the coarse files-finished half to its own 0.6% byte slice.

`ModelDownloadProgress` is the one clamp in the codebase: a single fraction in [0,1] (NaN/±∞ clamped), percent **truncated** so it reads 100 only when the download is genuinely complete. Every displayed figure derives from it, which is what makes "8.93 GB of 8.3 GB" arithmetically impossible. Never compute a second total independently — no recursive disk sums, no hardcoded sizes (a display-only string like `modelDisplaySize` must never be a progress input).

## The stall watchdog must be fed real bytes, and retry only its own cancel

`ModelDownload.withStallRetry`: 3 attempts, `defaultStallTimeout` 60 s, watchdog polls every 5 s. Only **forward** progress resets the clock — a connection reporting the same fraction is exactly the stall being detected. A retry requires **both** `tracker.wasStalled` and `isOurCancellation(error)`: `wasStalled` alone would retry a genuine error thrown as the watchdog happened to fire, and `isOurCancellation` alone would retry a user-initiated pause (`ModelDownloadRetry.swift:73-80`). URLSession's own idle timeout is deliberately longer (120 s) so a silent connection is cancelled-and-resumed rather than surfacing a raw timeout.

Gotcha: `URL.resourceValues(forKeys:)` **caches** per URL, so a growing file's size reads stale — use `FileManager.attributesOfItem` (`ResumableFileDownload.swift:219-225`).

## Completeness comes from the manifest, never the repo's index

"Snapshot complete" is exactly "every file in the recorded manifest committed in the snapshot directory" (`SnapshotManifest.swift`). Do not derive it from `model.safetensors.index.json`: the Qwen repo's index references an `optiq/` vision sidecar the download globs deliberately exclude, so an index-derived rule reads a complete snapshot as **forever incomplete**, and a single-file repo may ship no index at all.

- The manifest carries its `modelID`, so a stale record from a retired model reads as absent rather than vouching for the new snapshot.
- Failure is safe in **one direction only**: missing, unreadable or foreign manifest → INCOMPLETE, routing to the resume path (which no-ops per already-committed file) — never "ready".
- It lives at `Models/summary-model-manifest.json`, **outside** the Hub-managed snapshot directory: HubApi's offline snapshot pass validates every repo file matching the globs and fails on one without a `.metadata` sidecar, so a foreign JSON planted inside would poison offline resume (`SummaryModelManager.swift:726-736`).

## Load offline-first

A stale HF OAuth token in `~/.cache/huggingface/token` returned **401 on every Hub request** while anonymous requests got 200 — so a fully cached model failed to load at launch, the pipeline silently stayed unloaded, and every sample was dropped while the waveforms kept moving. The levels bypass the pipeline, so a dead transcriber looks like a capture problem. Resolve the cached snapshot locally and only call out to the network when files are actually missing (`ParakeetModelManager.liveModelsPresent` is a pure disk check through FluidAudio's own required-file list, re-checked per pass, offline).

## Lifecycle and floors

- Lazy: `ensureDownloaded` fetches without loading; weights load only for active work and release **60 s** after the last use.
- Free-disk floor for the summary download is **6 GB** for a ~3.3 GB snapshot — the retired 12B's 15 GB floor applied at the same ~1.7× ratio. A floor still sized for a retired model blocks the migration on exactly the full disks it is about to relieve (`SummaryModelManager.swift:110-116`).
- `RetiredModelCleanup` runs on **every launch**, immediately and unconditionally. Extend `retiredRepoIDs` / `retiredFileNames`; never touch the logic. It is a **named-directory removal**, never a sweep of "everything that isn't the current model" — the models root is shared state. Non-fatal (a locked file retries next launch, never a dialog, never a throw) and durable by repetition, so no trigger state is persisted.
