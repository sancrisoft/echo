# ADR-003 — One owner per state; one session facade the UI reads

Status: accepted · 2026-09-08

## Context

In the PoC three surfaces (popover, island, menu bar) each tracked their own idea
of the session and contradicted each other. The dashboard triple-tracked
selection (`selection`, `hoveredID`, `rightClicks.hoveredID`) in two lists,
kept `library.section` and `opened` in sync by hand in two places, let
`selectedTab` diverge from `opened.tab`, reset search and sort on every remount,
and shipped a `MeetingLibrary.selection` nobody read. `RecordingController` was
the only environment object, so every view depended on `controller.state.*`,
`controller.library.*` and `controller.finalization.*`.

## Options

1. A global store (single state tree, reducers) for the whole app.
2. Keep the PoC shape: one controller object exposes its sub-objects.
3. One `@Observable` owner per kind of state, injected by the composition root;
   the UI never reaches through one object into another.

## Decision

Option 3.

- **Session**: `RecordingSession` (Recording) is the single truth about a
  recording — phase, live levels, notices, current meeting, and the actions.
  Every surface reads it. Levels come from real capture, never simulated.
- **Library**: `MeetingLibrary` (Meetings); disk is the source of truth, the
  library is a main-actor cache that re-reads after its own mutations. Reading
  never writes.
- **Model readiness**: `ParakeetModel` and `SummaryModel` each expose one state
  with one clamped fraction.
- **Detection**: `CallDetector`. **Updates**: `UpdateChecker`. **Preferences**:
  `AppSettings`.
- **Window navigation**: `WorkspaceModel` (Workspace) owns section, selection,
  opened document, tab, search text and sort order. Lists render from it; they do
  not own selection.
- **Derived state is computed**: a meeting's display status is a pure function of
  `MeetingMeta`, `RecordingSession` and the finalization machine's state.
- **Transient UI** (hover, dialogs, focus) is `@State` in the view.
- `AppComposition` constructs every owner and injects each with
  `.environment(_:)`. Cross-owner reactions are method calls made by the owner
  that knows (the session attaches a summary; a setting turning detection off
  stops the detector), not observation chains.

No global store: the owners are few, their relationships are explicit, and a
store would add a layer between every view and the object it renders.

## Consequences

- A view declares `@Environment(MeetingLibrary.self)` and
  `@Environment(RecordingSession.self)` — it says what it depends on.
- Adding state means finding its owner or making a new observable in the package
  that owns the capability. There is no "put it on the controller".
- `WorkspaceModel` is testable on its own; the PoC's `MeetingListNavigation`
  rules move into it.
- Mirrors are forbidden unless documented as derived and kept by the owner
  (`CallDetector.appsInCall` is the machine's attribution, exposed).
