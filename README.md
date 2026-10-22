# Echo

Echo is a macOS menu bar app that turns your meetings into notes you can act on. It records the call from any app, transcribes it on your Mac, and writes a summary grounded in what was actually said: what was discussed, what was decided, what needs to happen next, what is still open, and what may block progress.

Nothing leaves your Mac. Audio, transcripts and notes are plain files in your home folder, produced by models that run on-device.

## What you get

**A transcript with two voices.** Echo records your microphone and the meeting's system audio as separate streams, so it always knows who is who: the microphone is **You**, whatever the other participants say through your speakers is **Others**. No diarization guesswork, and it works with any meeting app — Zoom, Teams, Meet, Slack, FaceTime, a browser tab — because it captures at the OS level.

**Notes that stick to the transcript.** After the meeting, an on-device language model writes a Markdown document: what was discussed, then only the sections the meeting earns — key decisions, an action-items checklist, open questions, risks. Owners and due dates are never invented; if the transcript doesn't say it, it stays blank. The notes come out in the language the meeting was held in.

**A library, not a folder of files.** Every meeting sits in Echo's window with its transcript and notes: search every word of them with ⌘K, find inside a transcript with ⌘F, export to Markdown or plain text, copy the summary, reveal the files in Finder, or move a meeting to the Trash.

**It notices your calls.** Echo lives in the menu bar and in a small island at the top of the screen. When Zoom, Microsoft Teams, Slack, Discord, FaceTime, Webex or any browser goes into a call, the island offers to record just that app's audio. It never starts on its own — recording takes a click, or Control-Option-E from anywhere — and a recording left running after the call ends is stopped for you.

## Status

Echo is a proof of concept that we use for our own meetings, and it is honest about what that means:

- **Words arrive after the meeting ends.** Recording is live; transcription is one pass over the whole recording once you stop, and the notes follow. There is no live transcript.
- **Everyone on the other side is "Others".** Echo separates you from the room; it does not yet separate the people in the room from each other.
- **Apple Silicon only, macOS 15.6 or later.** The interface is in English; transcription is multilingual.
- **Builds are ad-hoc signed, not notarized by Apple.** That is why installing is a command rather than a download (see below).

## How it works

- **Capture.** Your microphone goes through `AVAudioEngine`. The system audio goes through Core Audio process taps, not screen recording: no purple indicator in the menu bar, and protected playback elsewhere keeps working. When a recording starts from a call the island noticed, the tap is narrowed to that app's own processes where macOS allows it. A WebRTC audio-processing stage removes the meeting's playback from your microphone track, and a guard catches Bluetooth headsets that report one sample rate and deliver another.
- **Transcription.** [Parakeet TDT 0.6B v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3) (NVIDIA, CC-BY-4.0) through [FluidAudio](https://github.com/FluidInference/FluidAudio)'s Core ML port, about 480 MB on disk. Each channel is transcribed once, end to end, after the meeting, and the two are merged by timestamp.
- **Notes.** [Qwen3.5 4B](https://huggingface.co/mlx-community/Qwen3.5-4B-OptiQ-4bit) (OptiQ 4-bit, 3.3 GB) through [MLX](https://github.com/ml-explore/mlx-swift). Short meetings are summarized in one pass; long ones are split, summarized per part and merged. The weights load when needed and leave memory a minute after the last summary.
- **Storage.** Plain files under `~/Library/Application Support/Echo`: one folder per meeting in `Meetings/` with `meta.json`, `transcript.json` and `summary.md` (plus the two audio files if you choose to keep recordings), the models in `Models/`, settings in `settings.json`, logs in `Logs/`. Human-readable, yours to back up or delete.

## Requirements

- An Apple Silicon (M-series) Mac running macOS 15.6 or later
- About 6 GB free for the first launch, which downloads the two on-device models (about 4 GB on disk)

## Install

Open Terminal, paste this, press return:

```sh
curl -fsSL https://raw.githubusercontent.com/sancrisoft/echo/main/scripts/install.sh | bash
```

That's the whole install. It takes about a minute.

**What that command does** — you can [read the script](scripts/install.sh) before
running it, and it is worth 30 seconds if you have never installed anything this
way:

1. Checks your Mac can run Echo (Apple Silicon, macOS version) and warns if disk
   space looks tight for the models.
2. Downloads the latest release from GitHub and checks it twice: against the
   checksum GitHub publishes for the file, then against the app's own code
   signature.
3. Copies `Echo.app` into `/Applications` and opens it.

It touches nothing else and prints each step as it goes. If Echo is already
running it quits it first and reopens it on the new version.

> **Why a command and not a normal download?** Echo is signed but not notarized
> by Apple (that needs a paid developer account, and this is still a proof of
> concept). macOS quarantines anything unnotarized that arrives through a
> browser, so a hand-downloaded copy refuses to open. The installer clears that
> flag, which is the one thing you cannot do by dragging an icon.

<details>
<summary>Other ways to install</summary>

Install a specific version:

```sh
curl -fsSL https://raw.githubusercontent.com/sancrisoft/echo/main/scripts/install.sh | bash -s -- --version v0.0.13
```

Check what you have and whether it's current, without changing anything:

```sh
curl -fsSL https://raw.githubusercontent.com/sancrisoft/echo/main/scripts/install.sh | bash -s -- --check
```

Install from a zip somebody sent you, with no network:

```sh
curl -fsSL https://raw.githubusercontent.com/sancrisoft/echo/main/scripts/install.sh | bash -s -- --from ~/Downloads/Echo-0.0.13.zip
```

See the plan first — which release, from where, to where, whether Echo would be
quit — without downloading or changing anything. Combine it with any of the above:

```sh
curl -fsSL https://raw.githubusercontent.com/sancrisoft/echo/main/scripts/install.sh | bash -s -- --dry-run
```

Can't write to `/Applications`? Put `ECHO_INSTALL_DEST="$HOME/Applications/Echo.app"`
in front of the command and it installs there instead.

Run `... | bash -s -- --help` for every option.
</details>

### Update

Echo checks GitHub when it launches and once a day after that. When there is a
newer release it asks once, when it launches or when you next open its window,
with **Update** and **Later**; and the menu bar item's menu, where **Check for
Updates** sits under the version, reads **Update to Echo X.Y.Z** until you do.
Settings › Updates has **Check for Updates**, the release notes and **Update
Now**. Updating quits Echo, runs the install script above and reopens Echo on
the new version; it waits while a recording is running. Running the install
command yourself does the same thing; if you already have the latest build it
says so and changes nothing. The daily check can be turned off in Settings ›
Updates.

### Uninstall

```sh
curl -fsSL https://raw.githubusercontent.com/sancrisoft/echo/main/scripts/install.sh | bash -s -- --uninstall
```

It removes the app, then asks separately before deleting your meetings — those
are yours, and it defaults to keeping them. Add `--keep-data` or `--delete-data`
to skip the question, or `--dry-run` to see what it would remove and remove nothing.

## First launch

Echo lives in the menu bar and the island; it has a Dock icon only while its
window is open. The first time it runs, the window opens on a short welcome
that sets up the three things Echo needs, once:

- **Microphone** — to transcribe your voice.
- **System Audio Recording** — to transcribe what other participants say.
- **The two models**, downloaded from Hugging Face (about 4 GB, once).

After that, opening Echo from Spotlight, Finder or the menu bar item opens its
window; when it starts at login (Settings › Launch Echo at login) it stays in
the menu bar until you ask for it. Models and all meeting data live in
`~/Library/Application Support/Echo`.

**Coming from 0.0.x?** Your library opens as it is: the data folder and its
files are the same, and nothing is migrated or downloaded again. macOS asks for
the two permissions once more, because every ad-hoc signed build is new to it,
and the welcome shows once.

## Privacy

Echo is local-first by design. Audio capture, transcription and summarization all run on your Mac; nothing is uploaded anywhere. The only network traffic is downloading the two models from Hugging Face once and, if you leave it on, a request to GitHub for the latest release's version number at launch and once a day — which says nothing about you or your meetings. Deleting the folder in `~/Library/Application Support/Echo` removes all of it.

## Open source

Echo is free software under the [Apache License 2.0](LICENSE); [NOTICE](NOTICE) carries the attributions that travel with it. [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) lists every bundled dependency and model with its license, and ships in each release zip next to `Echo.app`. Bug reports and ideas go to [GitHub Issues](https://github.com/sancrisoft/echo/issues), which are also the roadmap: what is planned lives there, as epics and their sub-issues. Pull requests are welcome; the Development section below has what you need to build and test.

Echo stands on other people's work: [FluidAudio](https://github.com/FluidInference/FluidAudio) for on-device speech recognition, [MLX](https://github.com/ml-explore/mlx-swift) and [mlx-swift-lm](https://github.com/ml-explore/mlx-swift-lm) for running the language model, the WebRTC audio-processing library for echo cancellation, NVIDIA's Parakeet model (CC-BY-4.0), and the Qwen team and mlx-community for the summary model and its quantized weights.

## Development

You need an Apple Silicon Mac, Xcode 26.6 or later, and the Metal toolchain once per Xcode install (`xcodebuild -downloadComponent MetalToolchain`), which the summarization engine compiles its kernels with. The build is arm64-only, because MLX and the vendored WebRTC audio-processing library ([Packages/Audio/Vendor](Packages/Audio/Vendor)) are.

```sh
git clone https://github.com/sancrisoft/echo.git
cd echo
make build      # Debug build of Echo.app into build/
make run        # build and launch
```

Or open [Echo.xcodeproj](Echo.xcodeproj) in Xcode and run the `Echo` scheme. Swift package dependencies resolve automatically. To run against a scratch folder instead of your real library:

```sh
ECHO_DATA_ROOT=/tmp/echo-scratch ECHO_OPEN_WINDOW=1 build/Build/Products/Debug/Echo.app/Contents/MacOS/Echo
```

### Test

```sh
make test                  # every package with swift test, then the hosted app tests
make test-package P=Meetings
make lint                  # swift-format (strict) + the architecture boundary rules
make format
```

Package tests run with `swift test` and never touch your data folder. The few tests that need the real app are hosted in `Echo.app` and stay inert there. The acceptance suites — the ones that load a model or replay real meeting audio — are off by default: they need `ECHO_ACCEPTANCE=1 swift test --package-path Packages/<Name>` and audio fixtures that are not in the repository (see [Fixtures/README.md](Fixtures/README.md)), and they skip themselves with a note when either is missing.

To look at the window without clicking through it, render a scene to a PNG against a copy of your library (it quits a running Echo first):

```sh
scripts/snapshot.sh                 # build/snapshots/{library,summary,transcript,trash,settings,island}.png
ECHO_APPEARANCE=light scripts/snapshot.sh summary
```

The install script has tests of its own, plain bash with no framework, that point it at a scratch folder and never touch a real Echo:

```sh
bash scripts/tests/install_test.sh
```

The [installer workflow](.github/workflows/installer.yml) runs them with shellcheck on every pull request that touches `scripts/`, and installs the latest real release into a scratch destination on a macOS runner to check the script end to end.

### Repository

```
App/            the macOS app target: composition root, scenes, lifecycle, the menu bar item
AppTests/       the few tests that need the real app as host
Packages/       one local Swift package per capability
  EchoCore/       shared vocabulary: transcript, data root, error trace, settings, launch flags
  Meetings/       the library on disk and in memory, and its search
  Audio/          capture, echo cancellation, devices and routes
  Transcription/  the post-stop pass over each channel
  Summarization/  the on-device model and the notes
  ModelDelivery/  resumable model downloads
  Recording/      the session: start, stop, finalization, summaries
  CallDetection/  noticing a call
  Updates/        the release feed, the check and the updater
  DesignSystem/   tokens and primitives
  Workspace/      the main window
  Island/         the island
docs/architecture/   discovery, architecture, ADRs
scripts/        install script, boundary check, snapshots
Makefile        build · run · test · lint · format
```

Strong boundaries between modules, simple structure within them. Each package owns one product capability, has its own tests and a small public API, and depends only downward: `App → UI packages → Recording → engine packages → EchoCore`. Engine packages never import SwiftUI; UI packages never touch disk, audio or models. State has one owner per kind (a session facade, the library, a window model); side effects start from the composition root, never from initializers, so the test host stays inert. Swift 6 everywhere. [CLAUDE.md](CLAUDE.md) is how to work in this repository, for people and coding agents alike; [docs/architecture](docs/architecture) has the discovery, the architecture and the decisions with real trade-offs.

### Releasing

Releases are built by CI from version tags:

```sh
git tag v0.1.0 && git push origin v0.1.0
```

The [release workflow](.github/workflows/release.yml) builds `Echo.app` (Release, arm64), packages it as `Echo-<version>.zip`, and publishes a GitHub release whose notes carry the install command. The install script and the in-app update check both read these releases, so pushing the tag is the whole release. The app version comes from the tag; nothing needs to change in the Xcode project.

> **Note** — Builds are ad-hoc signed (not notarized by Apple), which is fine when installed through the script above; downloading the zip manually from the Releases page through a browser will trigger Gatekeeper warnings (`xattr -dr com.apple.quarantine /Applications/Echo.app` clears them). Use the install script.
