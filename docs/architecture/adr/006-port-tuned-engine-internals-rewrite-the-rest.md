# ADR-006 — Port the measured engine internals; rewrite orchestration and UI

Status: accepted · 2026-09-08

## Context

v2 is a rebuild, not a refactor: the PoC's structure, hubs and UI are not the
reference. But the engine holds months of behavior that was found by measuring
real calls, not by reasoning — the Bluetooth sample-rate lie and its 2 %
tolerance, the max-magnitude downmix, the segment cutter's 0.6 s/0.3 s/12 s,
the dedup tiers and own-voice rescue, the Spanish-drift decoder settings, the
8 000-token routing, the prompt's recency reminder, the byte-honest download
transport, the fail-safe manifest. `v2-discovery.md` §7 and §9 list them with
their reasons. Rewriting them from first principles would lose them; keeping the
PoC's orchestration and UI would keep its problems.

## Decision

Two different treatments, decided per module:

- **Ported as internals** (behavior and constants preserved, comments carried,
  tests brought along, isolation fixed per ADR-002, public API redesigned per
  ADR-001): capture sources and their defenses, echo cancellation, device and
  route monitors, input health, retention encoding, the transcription pass and
  segment shaping, dedup, utterance derivation, the finalization machine, the
  summarization pipeline and prompts, chunking and merge, the Markdown parser,
  model delivery, the meeting store and its tolerant decoders, the call-session
  machine and catalogs, the release feed and version arithmetic, the pure
  navigation and display-state rules.
- **Rewritten**: `RecordingController` (becomes `RecordingSession` with injected
  collaborators), `DashboardView` and the popover (become `Workspace` on a design
  system), the island view, settings screens, the app shell, and every place the
  PoC mixed a view with a side effect.
- **Not ported** (recorded in the discovery document instead): the disabled AEC
  pre-pass and bleed probe, live-transcript remnants, the `liveFloor` draft UI,
  retired-protocol validator types, the never-called WhisperKit cache migration,
  the in-view debug harness.

A port may change names, file boundaries and isolation. It may not change a
measured constant or a defended behavior without a new measurement, and it keeps
the comment that explains the number next to the number.

## Consequences

- The engine ports are mostly mechanical but each needs its Swift 6 isolation
  decided.
- The PoC's test suites are the acceptance criteria for each port: they must
  pass against the new package with only import and API changes.
- Orchestration and UI get the design attention; the engine gets the respect.
