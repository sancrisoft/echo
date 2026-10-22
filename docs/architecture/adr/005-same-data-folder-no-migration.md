# ADR-005 — v2 reads and writes the v1 data folder with no migration

Status: accepted · 2026-09-08

## Context

Users of v0.0.x have meetings under `~/Library/Application Support/Echo/Meetings/`
as one folder per meeting: `meta.json`, `transcript.json`, `summary.md`
(sometimes a legacy `summary.json`), and optionally preserved `audio-*.m4a`.
Older folders carry the pre-SP-007 speaker encoding (`{"teammates":{}}`), metas
without `wordCount`/`transcriptProvenance`/`captureScope`, and Whisper-era
provenance strings. The PoC's tests guard that an untouched old `meta.json`
stays byte-identical after reads.

## Options

1. A new store format with a one-shot migration.
2. The same folder, the same files, tolerant additive schemas, and the legacy
   decoders kept forever.

## Decision

Option 2. The first feature's acceptance test is opening an existing v1 library
and seeing every meeting.

Rules, owned by `Meetings`:

- Same root (`DataRoot`), same folder layout, same file names.
- `meta.json`: sorted keys, ISO-8601 dates, optional fields encoded only when
  present, `schemaVersion` read and rejected if higher than understood. New
  fields are optional with defaults; a field is never renamed or removed.
- `transcript.json`: a bare array of `TranscriptSegment`; `speaker` is a plain
  string with the legacy object form and unknown values decoding to the channel
  default.
- `summary.md` is the summary. A `summary.json` is read when no `summary.md`
  exists; when both exist the Markdown wins. Folding a legacy json into
  Markdown writes the `.md` first and deletes the json after, never when the
  resolved Markdown is empty.
- Audio name families are the state: `retained-*` pending, `audio-*`
  preserved, `debug-kept-*` invisible.
- Writes are atomic; `meta.json` is written last; deletions are named files.
- `settings.json` is decoded key by key with defaults.

## Consequences

- No migration code, no version flag, nothing to get wrong on upgrade or
  downgrade: a user can install v1 over v2 and back.
- The legacy decoders are permanent code with permanent tests.
- Schema evolution is additive only; anything else needs a new ADR.
