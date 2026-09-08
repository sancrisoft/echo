---
name: echo-verification
description: How to prove a change works in Echo without destroying real data — hosted tests and `TestHostGuard`, the `Fixtures/` layout, `TEST_RUNNER_ECHO_*` gates, the Parakeet replay harness and kept fixture audio, honest xcodebuild gates, `ErrorTrace` diagnostics, and the CI check.
---

## The test host is the real app — it has already destroyed a meeting

`xcodebuild test` launches **Echo.app** as the test host, and until the guard landed that host ran the full production launch path against `~/Library/Application Support/Echo`: model preload, retention-staging sweeps, finalization resume over real pending meetings, trash purge (real folder deletes), retired-model cleanup, call-detection listeners. On 2026-08-06 a test run's sweep deleted a live meeting's `meta.json` within seconds while the user was recording; the historical "Skipping unreadable meeting folder" floods have the same cause.

- `TestHost.isActive` gates every launch side effect (`TestHostGuard.swift`). Detection is belt-and-braces: `NSClassFromString("XCTestCase")` (linked into the host for Swift Testing too) **or** any `XCTest*` environment key. A false positive only skips warm-up; a false negative corrupts the user's store.
- Under a test host the app must be inert scaffolding. **Tests construct their own objects against temp directories** — never the real data root.
- `ErrorTrace.shared` still writes to the real `Logs/` from test processes (append-only pollution, accepted).
- **Never run the suite while the real app is recording.** If in doubt, ask rather than assume it is idle.

## Fixtures live at the repo root, not under EchoTests/

`EchoTests/` is a `PBXFileSystemSynchronizedRootGroup`, which flattens everything beneath it into the test bundle's Resources — 11 scenarios each shipping `mic.wav`/`system.wav` collided as `error: Multiple commands produce …/Resources/mic.wav` and the build failed before any test ran. Fixtures are now `/Fixtures/<scenario>/`, resolved from `#filePath` up two levels (`FixtureSupport.swift:33-38`). Nothing reads the bundle, so nothing belongs in it.

Dead end, measured, do not retry: a `PBXFileSystemSynchronizedBuildFileExceptionSet` with `membershipExceptions = (Fixtures,)` parses fine and is **silently ignored** — all duplicate-output warnings survive; the exception list wants individual files. Also, hand-picked pbxproj object IDs must be checked for collisions first: reusing an `XCBuildConfiguration` ID makes Xcode report the project as damaged. New source files auto-join targets (synchronized root group), so no pbxproj edit is needed for them.

## Running the suite

```
xcodebuild test -project Echo.xcodeproj -scheme Echo \
  -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:EchoTests
```

- `-parallel-testing-enabled NO` is required, not optional: the tests are hosted in Echo.app and share its data folder, and parallel test clones also race the HubApi `.incomplete` download rename.
- `TEST_RUNNER_`-prefixed variables are stripped by xcodebuild before the test process sees them, so `TEST_RUNNER_ECHO_ACCEPTANCE=1` becomes `ECHO_ACCEPTANCE=1`. Gates in use: `ECHO_ACCEPTANCE` (real models/generations), `ECHO_REPLAY_DIR` (replay harness), `ECHO_AEC_SPIKE` (offline AEC spike). Every gated suite skips with its own invocation string in the skip reason.
- Acceptance suites **never download** — the model must already be on disk under `Models/`. Suites with more than one model test carry `@Suite(.serialized, ...)`.
- Swift Testing quirk: `-only-testing:Target/Type/func` selects 0 tests unless the function name carries a `()` suffix. Filter at the **suite** level and it just runs.
- Never block a cooperative thread in a test helper: one `usleep` spin starved the whole parallel run (16 s stalls and unrelated flakes).

## Honest gates, not eyeballed output

With `-quiet`, per-suite swift-testing output may not appear at all, and `$?` after `xcodebuild | tail` is **tail's** exit status. Take the result from the bundle instead:

```
xcodebuild test ... -resultBundlePath build/EchoTests.xcresult
xcrun xcresulttool get test-results summary --path build/EchoTests.xcresult
```

Also: zsh's `status` is read-only, so it cannot be used as a shell variable in a runner script.

## Measure real audio, do not reason about it

The only honest verification of a capture/ASR/AEC change is a replay over real recorded audio:

1. Run a DEBUG app build with `ECHO_KEEP_RETAINED_AUDIO=1`; a meeting whose pass succeeds keeps `debug-kept-mic.m4a` / `debug-kept-system.m4a` in its meeting folder (`RecordingController.swift:1072`, names in `MeetingStore.swift:754-755`).
2. Point the harness at a directory holding them: `TEST_RUNNER_ECHO_REPLAY_DIR=<dir> ... -only-testing:EchoTests/ParakeetReplayHarness`. Each run writes `replay-<ISO>.json` next to the audio and prints the delta against the most recent previous one.
3. The harness prints and records; **it never asserts accuracy**. The judgement is yours, off the numbers.

Rules that came out of doing this wrong:
- **Decode the audio and look before reasoning from call order.** "The tap comes up slowly, so the hole is at the start" was inferred from the start order in `RecordingController.start` and shipped; per-100 ms RMS of the m4a showed no silence at the head and the theory was false.
- Decode is nondeterministic run to run — diff by word containment, never equality.
- Attribute by measuring per-channel counts across A/B arms, not by reading the diff and guessing which branch did it.
- Searching for duplicated text to detect echo is circular; select spans acoustically.
- Fixture meetings `5B6C156C-0CB9-49E0-B192-50C7A184451D` (language/gap failures) and `E656A3F9-BF5A-400D-BD92-1747B6C3D946` (bleed residue) hold the only replayable evidence of their failure modes — **never delete them or their `debug-kept-*.m4a`**.
- Fixtures are real hardware recordings, never synthesized.

## Diagnostics: ErrorTrace, not the unified log

New error paths call `ErrorTrace.record(message, error:, category:, metadata:)` — never `Self.log.error(...)` directly. It mirrors to `os.Logger` with the call site's existing category *and* appends an NDJSON record (id, ISO-8601 timestamp, per-launch session id, error type/domain/code and underlying chain, `file:line`, app version, metadata) to `Logs/errors-YYYY-MM-DD.ndjson`, UTC days, pruned after `retentionDays` = 14. Best-effort and fire-and-forget: logging must never take the app down or block a call site. The actor is injectable with a temp directory for tests.

Why this matters for verification: `Logger.info` is **never persisted**, `log show` returns zero lines from an agent's sandbox (even for Apple subsystems), and zsh's builtin `log` shadows the tool — use `/usr/bin/log` when a person runs it, and persist anything you need to read later through `ErrorTrace`.

## CI

`.github/workflows/ci.yml` runs on every pull request and on pushes to `main` / `v2/**`; PR runs are superseded by the next push, `main` runs never are. Job name is **"Build and test"** — branch protection requires it by that name, keep it stable. `macos-26`, arm64 only (MLX and the vendored webrtc-apm are arm64-only), ad-hoc signed, `timeout-minutes: 45`, Xcode setup shared with `release.yml` via `.github/actions/setup-xcode`. The result bundle uploads on failure. Acceptance/fixture/spike suites gate themselves off, so the run needs neither models nor fixtures. Local run of the same command: 88 s, 863 tests, 843 passed / 20 skipped.
