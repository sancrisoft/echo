# ADR-004 — Package tests run without a host; the app hosts only what needs it

Status: accepted · 2026-09-08

## Context

Every PoC test is hosted inside the real `Echo.app`. On 2026-08-06 a hosted run
booted the full launch path against the real data folder while a real Echo was
recording, and a sweep deleted a live meeting's `meta.json`. The fix was
`TestHost.isActive` (an `XCTestCase` class lookup or any `XCTest*` environment
key) gating six launch sites, plus one tripwire test. The guard is a heuristic;
its failure mode corrupts user data. Hosted tests also run serially, cannot run
in parallel with a recording, and need `xcodebuild`.

## Options

1. Keep everything hosted and keep the guard.
2. Package tests for everything, no hosted tests at all.
3. Package tests for every package; a small hosted `AppTests` target only for
   behavior that needs the real app process.

## Decision

Option 3.

- Every package has `Tests/<Name>Tests` run with `swift test`. No host process
  exists, so no launch path can run. Stores, writers and downloaders are tested
  against temporary roots; a test that reads or writes the real data root is a
  bug unless it is an acceptance suite that needs an already-downloaded model.
- `EchoCoreTestSupport` (a product of `EchoCore`) provides the fixtures root
  (`Fixtures/` at the repo root, gitignored, resolved from `#filePath`), the
  `.acceptance` trait (`ECHO_ACCEPTANCE=1`; `xcodebuild` strips a
  `TEST_RUNNER_` prefix), temp-root helpers, and the rule that a missing fixture
  skips with instructions.
- `AppTests` is hosted and small: the `TestHost` tripwire, launch smoke, and
  anything that needs `NSApplication`.
- Side effects live in `start()`-style methods, never in initializers.
  `AppComposition.start()` is the one door and checks `TestHost.isActive` once.
  This replaces the PoC's six scattered gates with one.
- Swift Testing everywhere. No sleeps for timing; no wall-clock performance
  assertions on shared runners; no writing into the source tree.

## Consequences

- `make test` runs twelve `swift test` invocations then one `xcodebuild test`.
  Package tests are fast and parallel-safe.
- The acceptance suites (real Parakeet and Qwen runs, fixture replays) remain
  gated and serialized; they are the only tests that touch `Models/`.
- A port brings its module's tests with it; tests that need the host are
  rewritten as package tests or explicitly justified in `AppTests`.
