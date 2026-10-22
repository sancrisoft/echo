# ADR-001 — Local Swift packages are the module boundaries

Status: accepted · 2026-09-08

## Context

The PoC is one app target with 71 flat files. Its two hubs (`RecordingController`,
1 821 lines; `DashboardView`, 2 934 lines) fused orchestration with UI state and
made the orchestration untestable. Nothing stopped a view from reaching three
levels into the engine, and nothing stopped the engine from growing a SwiftUI
import. The earlier v2 attempt (`attic/v2/bootstrap-*`) proposed two packages
(`EchoEngine` with nine targets, `EchoUI` with seven) and one import-scanning
test.

We want boundaries the compiler enforces, ownership an agent can find by
directory name, and tests that run without the app.

## Options

1. **One target, folders.** No enforcement; the PoC's shape.
2. **One package, many targets** (the earlier attempt). Enforced imports, one
   `swift test`, but one `Package.swift` owns every dependency and every
   module shares one test target's build; the "package" is a namespace, not an
   owner.
3. **One local package per capability**, each with its own `Package.swift`,
   sources, tests and declared dependencies; the app target links the products.

## Decision

Option 3. Twelve packages, one per product capability (`v2-architecture.md`
§2), created when their first feature lands. Dependencies point downward:
`App → UI packages → Recording → engine packages → EchoCore`. Engine packages
never import SwiftUI/AppKit; `scripts/check_boundaries.sh` enforces what SwiftPM
cannot. `EchoCore` is an allowlisted shared package (three or more consumers, no
UI, not a capability). `DesignSystem` is a UI leaf with no product knowledge.

Inside a package the structure is flat. No mandatory layers, no
`Models/Views/Services` split. Folders appear only when a flat listing stops
helping.

## Consequences

- An import is a dependency decision; adding one edits a `Package.swift` and is
  visible in review.
- Each package's tests run alone (`swift test --package-path Packages/X`), fast,
  with no host app.
- Twelve `Package.swift` files to keep consistent (same tools version, same
  platform, same language mode). A `Makefile` loop and CI keep them honest.
- External dependencies are isolated where they are used: FluidAudio in
  `Transcription`, MLX in `Summarization`, the Hub client in `ModelDelivery`,
  the vendored WebRTC library in `Audio`. Nothing else links them.
- Xcode resolves twelve local packages; first build is slower than one target,
  incremental builds are faster because a change in `Audio` does not rebuild
  `Workspace`.
