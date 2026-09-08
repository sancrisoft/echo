# Architecture review after the first feature

Date: 2026-09-08. Scope: the foundation (`App`, `EchoCore`) plus the first real
feature — the meeting library in the main window (`Meetings`, `DesignSystem`,
`Workspace`). The feature was chosen because it exercises persistence, state
ownership, UI, concurrency, error handling and testing without pulling in any
ML dependency, and because opening the existing v1 library unchanged is the
acceptance test ADR-005 demands.

What was verified: 169 package tests and the hosted tripwire pass; `make lint`
is clean; the app builds, launches as an agent, and — against a copy of a real
v1 library — lists both meetings grouped by month, renders the summary
(checkboxes, sections, inline code), the transcript (turns with You/Others and
timestamps), the empty Trash and the settings form. Package tests never touched
the real data folder.

## The questions, answered

**Are the package boundaries right?**
Yes for these four. `Meetings` had a clean seam: the store, the library façade,
export formatting and the selection rules moved in without needing anything
from the UI, and the UI needed nothing from the store's internals. The one
place the boundary bit was the `MeetingSummary` type: the PoC persisted a
struct with fixed fields; v2 persists Markdown, so the summary crossing the
Meetings→Workspace boundary is a `String`, and the fixed-field struct survives
only as `LegacyMeetingSummary` for reading old files. That is the right shape —
it also removed the PoC's main-actor-isolated `Codable` hop.

**Do the dependencies make sense?**
`Workspace → Meetings → EchoCore` and `Workspace → DesignSystem` were the only
edges the feature needed. The App imports all four to compose. No edge was
added for convenience. The boundary script caught nothing, which is the point:
the graph was designed before the code.

**Is there too much shared code?**
`EchoCore` has eight files and each has at least three consumers or is the
vocabulary itself (`TranscriptSegment` is read by Meetings and Workspace today
and by four more packages later). `AppSettings` in `EchoCore` is the one item
that could be argued (it is a persisted-preferences type, not vocabulary); it
stays because Workspace, Recording, CallDetection and Updates all read it and
none owns it. `EchoCoreTestSupport.Fixtures` has no consumer yet — it exists
for the acceptance suites that arrive with Audio and Transcription; it is small
and documented.

**Too many abstractions?**
None were introduced beyond what the PoC already had and tested: one actor for
the disk, one observable façade, one window model, pure resolvers. There is no
repository protocol, no coordinator, no service locator. `WindowOpener` is the
one indirection (SwiftUI's `openWindow` has no home outside a view), inherited
from the PoC and kept because ⌘, and the menu bar item need it.

**Is the code easy to find?**
`Packages/Workspace/Sources/Workspace/` has nine files whose names say what they
hold; the PoC's 2 934-line `DashboardView` became `WorkspaceWindow` (layout),
`MeetingSidebar` (list), `MeetingDocumentView` (document), `TrashView`,
`SettingsScreen`, with the logic they used to embed pulled into
`WorkspaceModel`, `MeetingGrouping` and `MeetingStatus` — each tested.

**Could an agent modify this feature without understanding the app?**
Yes: the sidebar, the document and the settings screen are one file each; the
storage they read is one package with a public API listed in the architecture
document; the selection rules are one type with tests. `CLAUDE.md` maps every
question ("where is disk touched?", "where are the ECHO_ flags?") to one file.

**Should anything be simplified?**
Three things were, during the review:

1. `MeetingLibrary.refresh()` no longer writes. In the PoC, loading the list
   purged trash and rewrote metas — the reason the test-host guard had to gate
   it. v2 makes those explicit (`purgeExpiredTrash`, `backfillWordCounts`,
   `foldLegacySummaries`) and the composition root calls them once. A view can
   call `refresh()` freely.
2. Storage is measured once. The PoC had three ways to count the recordings'
   bytes and a test to keep them in agreement; `StorageBreakdown.measure` is
   the one.
3. `WorkspaceModel` owns selection. The PoC tracked it three times per list and
   had a dead `MeetingLibrary.selection`; the window model is the only holder
   and its rules are pure methods.

## What the feature taught the architecture

- **Token enums must be `nonisolated`.** `DesignSystem` defaults to the main
  actor, but `EchoFont`/`EchoColor` are read by the Markdown renderer's pure
  helpers. Recorded in `CLAUDE.md`; the fix was one keyword per enum.
- **Isolated method references crash the Swift 6.3.3 compiler** when passed as
  a `Binding` setter. Recorded as a known trap; the workaround is a closure.
- **The boundary script runs on bash 3.2** (macOS's default). Associative
  arrays are out; the dependency table is a `case`.
- **Pixels cannot be captured from outside a window** on this macOS, so the
  design-review tool has to live in the app: `ECHO_SNAPSHOT_PATH` and
  `ECHO_SNAPSHOT_SCENE` (DEBUG) render a scene and quit, driven by
  `scripts/snapshot.sh`. Two flags, both in `LaunchEnvironment`, versus the
  PoC's nine scattered across views.
- **The App target needs the window model.** ⌘, must select the settings
  section before the window opens; `AppComposition.openSettings()` does that.
  The App composes state; it does not render it.

## Watch list for the next features

- `MeetingStatus.resolve` takes only the meta today. When `Recording` lands it
  gains session and finalization inputs (recording, waiting, transcribing) and
  must stay the single resolver every surface uses — the PoC's
  `MeetingDisplayState` had that property and its tests should come along.
- `WorkspaceModel` will need `documentTab` per meeting or a rule for what the
  tab does on selection change; today it persists across meetings, which is
  what the design asked for.
- `MeetingLibrary` exposes `store` for the pipeline. If `Recording` ends up
  wrapping every store method in the library again, that is the PoC's shape
  returning; prefer the pipeline talking to the store and telling the library
  to refresh.
- `AppSettings` still needs five edits to add a preference. Acceptable at six
  preferences; revisit if it passes ten.
- The audio port must model the IO queue explicitly (ADR-002); the first
  `nonisolated(unsafe)` or `@unchecked Sendable` without a comment naming the
  thread is the signal to stop and think.

## Verdict

The boundaries held under a real feature, the dependency graph did not need an
edge that was not planned, shared code did not grow, and the PoC's tests for the
ported parts passed with only API renames. Proceed with the engine ports in the
order of `v2-architecture.md` §11.
