# Echo

Echo is a macOS menu bar app that turns your meetings into notes you can act on. It records the call from any app, transcribes it on your Mac, and writes a summary grounded in what was actually said: what was discussed, what was decided, what needs to happen next, what is still open, and what may block progress.

Nothing leaves your Mac. Audio, transcripts and notes are plain files in your home folder, produced by models that run on-device.

## What you get

**A transcript with two voices.** Echo records your microphone and the meeting's system audio as separate streams, so it always knows who is who: the microphone is **You**, whatever the other participants say through your speakers is **Others**. No diarization guesswork, and it works with any meeting app — Zoom, Teams, Meet, Slack, FaceTime, a browser tab — because it captures at the OS level.

**Notes that stick to the transcript.** After the meeting, an on-device language model writes a Markdown document: what was discussed, then only the sections the meeting earns — key decisions, an action-items checklist, open questions, risks. Owners and due dates are never invented; if the transcript doesn't say it, it stays blank. The notes come out in the language the meeting was held in.

**A library, not a folder of files.** Every meeting sits in the dashboard with its transcript and notes: search them, export to Markdown or plain text, copy the summary, reveal the files in Finder, or move a meeting to the trash.

**It notices your calls.** When Zoom, Microsoft Teams, Slack, Discord, FaceTime, Webex or any browser goes into a call, a small island appears offering to record just that app's audio. It never starts on its own — recording takes a click — and a recording left running after the call ends is stopped for you.

## Status

Echo is a proof of concept that we use for our own meetings, and it is honest about what that means:

- **Words arrive after the meeting ends.** Recording is live; transcription is one pass over the whole recording once you stop, and the notes follow. There is no live transcript.
- **Everyone on the other side is "Others".** Echo separates you from the room; it does not yet separate the people in the room from each other.
- **Apple Silicon only, macOS 15.6 or later.** The interface is in English; transcription is multilingual.
- **Builds are ad-hoc signed, not notarized by Apple.** That is why installing is a command rather than a download (see below).

## How it works

- **Capture.** Your microphone goes through `AVAudioEngine`. The system audio goes through Core Audio process taps, not screen recording: no purple indicator in the menu bar, and protected playback elsewhere keeps working. When a recording starts from the call island, the tap is narrowed to that app's own processes where macOS allows it. A WebRTC audio-processing stage removes the meeting's playback from your microphone track, and a guard catches Bluetooth headsets that report one sample rate and deliver another.
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
curl -fsSL https://raw.githubusercontent.com/sancrisoft/echo/main/scripts/install.sh | bash -s -- --version v0.0.11
```

Check what you have and whether it's current, without changing anything:

```sh
curl -fsSL https://raw.githubusercontent.com/sancrisoft/echo/main/scripts/install.sh | bash -s -- --check
```

Install from a zip somebody sent you, with no network:

```sh
curl -fsSL https://raw.githubusercontent.com/sancrisoft/echo/main/scripts/install.sh | bash -s -- --from ~/Downloads/Echo-0.0.11.zip
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

Echo checks GitHub once a day and shows **Update available** in its menu bar
popover when there is a newer release. Settings › Updates has **Check for
Updates**, the release notes, and **Update Now**, which quits Echo, runs the
install script above and reopens Echo on the new version. Running the install
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

Echo lives in the menu bar; it has no Dock icon. On first use it asks for two
permissions:

- **Microphone** — to transcribe your voice.
- **System Audio Recording** — to transcribe what other participants say.

It then downloads the two models from Hugging Face (about 4 GB, once). Models
and all meeting data live in `~/Library/Application Support/Echo`.

## Privacy

Echo is local-first by design. Audio capture, transcription and summarization all run on your Mac; nothing is uploaded anywhere. The only network traffic is downloading the two models from Hugging Face once and, if you leave it on, a once-a-day request to GitHub for the latest release's version number — which says nothing about you or your meetings. Deleting the folder in `~/Library/Application Support/Echo` removes all of it.

## Open source

Echo is free software under the [Apache License 2.0](LICENSE); [NOTICE](NOTICE) carries the attributions that travel with it. [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) lists every bundled dependency and model with its license, and ships in each release zip next to `Echo.app`. Bug reports and ideas go to [GitHub Issues](https://github.com/sancrisoft/echo/issues), which are also the roadmap: what is planned lives there, as epics and their sub-issues. Pull requests are welcome; the Development section below has what you need to build and test.

Echo stands on other people's work: [FluidAudio](https://github.com/FluidInference/FluidAudio) for on-device speech recognition, [MLX](https://github.com/ml-explore/mlx-swift) and [mlx-swift-lm](https://github.com/ml-explore/mlx-swift-lm) for running the language model, the WebRTC audio-processing library for echo cancellation, NVIDIA's Parakeet model (CC-BY-4.0), and the Qwen team and mlx-community for the summary model and its quantized weights.

## Development

You need an Apple Silicon Mac, Xcode 26.6 or later, and the Metal toolchain (`xcodebuild -downloadComponent MetalToolchain`). Open [Echo.xcodeproj](Echo.xcodeproj) and run the `Echo` scheme. Swift package dependencies resolve automatically; the WebRTC audio-processing library is vendored in [Vendor/webrtc-apm](Vendor/webrtc-apm). The build is arm64-only, because MLX and that vendored library are.

Run the tests with:

```sh
xcodebuild test -project Echo.xcodeproj -scheme Echo \
  -destination 'platform=macOS,arch=arm64' \
  -skipMacroValidation -skipPackagePluginValidation
```

The acceptance suites — the ones that load a model or replay real meeting audio — are off by default: they need `TEST_RUNNER_ECHO_ACCEPTANCE=1` and audio fixtures that are not in the repository, and they skip themselves with a note when either is missing. Tests are hosted in `Echo.app` and share its data folder, so don't run them while your own Echo is recording.

### Releasing

Releases are built by CI from version tags:

```sh
git tag v0.0.2 && git push origin v0.0.2
```

The [release workflow](.github/workflows/release.yml) builds `Echo.app` (Release, arm64), packages it as `Echo-<version>.zip`, and publishes a GitHub release whose notes carry the install command. The install script and the in-app update check both read these releases, so pushing the tag is the whole release. The app version comes from the tag; nothing needs to change in the Xcode project.

> **Note** — Echo is currently a proof of concept. Builds are ad-hoc signed (not notarized by Apple), which is fine when installed through the script above; downloading the zip manually from the Releases page through a browser will trigger Gatekeeper warnings (`xattr -dr com.apple.quarantine /Applications/Echo.app` clears them). Use the install script.
