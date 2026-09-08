# Echo

Echo is a macOS menu bar app that turns your meetings into notes you can act on.
It records the call from any app, transcribes it on your Mac, and writes a
summary grounded in what was actually said: what was discussed, what was
decided, what needs to happen next, what is still open, and what may block
progress.

Nothing leaves your Mac. Audio, transcripts and notes are plain files in your
home folder, produced by models that run on-device.

> **This is the v2 branch: a rebuild in progress.** The app that ships today
> lives on `main` (v0.0.13) and is installed with the command in its README.
> v2 is being built feature by feature on a new architecture; it reads the same
> data folder as v1, so a library recorded with v1 opens in v2 unchanged. What
> works today on this branch is listed below.

## What Echo does

- **A transcript with two voices.** Your microphone is **You**; whatever the
  other participants say through your speakers is **Others**. The two are
  captured separately and merged by timestamp — no diarization guesswork, and it
  works with Zoom, Teams, Meet, Slack, FaceTime or a browser tab because it
  captures at the OS level.
- **Notes that stick to the transcript.** An on-device language model writes a
  Markdown document: what was discussed, then only the sections the meeting
  earns — decisions, an action-items checklist, open questions, risks. Owners
  and due dates are never invented.
- **A library, not a folder of files.** Every meeting has its transcript and
  notes; search them, export to Markdown or plain text, copy the summary, reveal
  the files in Finder, or move a meeting to Trash.
- **It notices your calls.** When a meeting app goes into a call, a small island
  offers to record it. It never starts on its own.

### On this branch today

| Capability | State |
|---|---|
| Open the existing library, read summaries and transcripts, search, sort, rename, trash, restore, export, copy, reveal | ✅ |
| Settings: launch at login, keep recordings, auto-summaries, storage | ✅ |
| Recording, transcription, summarization, model download, call detection, island, updates | port in progress — see `docs/architecture/v2-architecture.md` §11 |

## Requirements

- An Apple Silicon Mac running macOS 15.6 or later.
- To build: Xcode 26.6 or later. The Metal toolchain
  (`xcodebuild -downloadComponent MetalToolchain`) is needed once the
  summarization package lands.

## Setup and run

```sh
git clone https://github.com/sancrisoft/echo.git
cd echo
git switch v2
make build      # Debug build of Echo.app into build/
make run        # build and launch
```

Or open `Echo.xcodeproj` in Xcode and run the `Echo` scheme. Swift package
dependencies resolve automatically.

Echo is a menu bar agent: after launch, use the menu bar item to open the
window. Everything it stores lives in `~/Library/Application Support/Echo`.
To run against a scratch folder instead of your real library:

```sh
ECHO_DATA_ROOT=/tmp/echo-scratch ECHO_OPEN_WINDOW=1 build/Build/Products/Debug/Echo.app/Contents/MacOS/Echo
```

## Test

```sh
make test                  # every package with swift test, then the hosted app tests
make test-package P=Meetings
make lint                  # swift-format (strict) + the architecture boundary rules
make format
```

Suites that need a downloaded model or real recordings are gated:
`ECHO_ACCEPTANCE=1 swift test --package-path Packages/<Name>`; see
`Fixtures/README.md`.

To look at the UI without clicking through it, render a scene to a PNG against
a copy of your library:

```sh
scripts/snapshot.sh                 # build/snapshots/{library,summary,transcript,trash,settings}.png
ECHO_APPEARANCE=light scripts/snapshot.sh summary
```

## Repository

```
App/            the macOS app target: composition root, scenes, lifecycle
AppTests/       the few tests that need the real app as host
Packages/       one local Swift package per capability
  EchoCore/       shared vocabulary: transcript, data root, error trace, settings, launch flags
  Meetings/       the library on disk and in memory
  DesignSystem/   tokens and primitives
  Workspace/      the main window
  …               Audio, Transcription, Summarization, ModelDelivery, Recording,
                  CallDetection, Updates, Island — added as their features land
docs/architecture/   discovery, architecture, ADRs
scripts/        install script, boundary check, snapshots
Makefile        build · run · test · lint · format
```

## Architecture in one paragraph

Strong boundaries between modules, simple structure within modules. Each
package owns one product capability, has its own tests and a small public API,
and depends only downward: `App → UI packages → Recording → engine packages →
EchoCore`. Engine packages never import SwiftUI; UI packages never touch disk,
audio or models. Inside a package the layout is flat — one file per concept, no
mandated layers. State has one owner per kind (a session facade, the library, a
window model); side effects start from the composition root, never from
initializers, so the test host stays inert. Swift 6 everywhere, with isolation
stated explicitly in the engine and main-actor by default in the UI.

## Documentation

- `docs/architecture/v2-discovery.md` — what the product is, what the PoC
  taught us, what must be preserved.
- `docs/architecture/v2-architecture.md` — packages, ownership, dependency
  graph, state, data flow, testing, tooling.
- `docs/architecture/adr/` — the decisions with real trade-offs.
- `CLAUDE.md` — how to work in this repository (for people and coding agents).

## Privacy

Audio capture, transcription and summarization run on your Mac; nothing is
uploaded anywhere. The only network traffic is downloading the on-device models
once and, if you leave it on, a daily request to GitHub for the latest release's
version number. Deleting `~/Library/Application Support/Echo` removes all data.

## License

Echo is free software under the [Apache License 2.0](LICENSE); [NOTICE](NOTICE)
carries the attributions that travel with it and
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) lists every bundled dependency
and model with its license. Bug reports and ideas go to
[GitHub Issues](https://github.com/sancrisoft/echo/issues), which are also the
roadmap.
