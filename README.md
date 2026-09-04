# Echo

Echo is a local-first macOS menu bar app that turns your meetings into structured notes. It records your microphone and the system audio separately, transcribes both on-device, and generates a grounded summary — what was discussed, what was decided, what needs to happen next.

Everything runs locally: audio, transcripts, and summaries never leave your Mac.

## Features

- **Dual-stream capture** — your microphone (labeled **You**) and the meeting's system audio (labeled **Others**) are recorded as separate streams, so speaker attribution doesn't depend on diarization guesswork. Works with any meeting app (Zoom, Meet, Teams, …) because it captures at the OS level.
- **On-device transcription** — [WhisperKit](https://github.com/argmaxinc/WhisperKit) transcribes both streams locally, aligned by timestamp into a single transcript.
- **Echo cancellation** — a WebRTC audio-processing stage keeps the meeting's own playback from leaking into your microphone track.
- **AI summaries, fully local** — an on-device LLM (Gemma via [MLX](https://github.com/ml-explore/mlx-swift)) produces a short summary, a detailed summary, decisions, action items, open questions, and risks. Summaries are grounded in the transcript: owners and due dates are never invented — if the transcript doesn't say it, the field stays empty.
- **Meetings library** — every meeting is stored with its transcript and summary, browsable from the dashboard.

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

Can't write to `/Applications`? Put `ECHO_INSTALL_DEST="$HOME/Applications/Echo.app"`
in front of the command and it installs there instead.

Run `... | bash -s -- --help` for every option.
</details>

### Update

Run the same install command again — it replaces the installed app with the latest release.

### Uninstall

```sh
curl -fsSL https://raw.githubusercontent.com/sancrisoft/echo/main/scripts/install.sh | bash -s -- --uninstall
```

It removes the app, then asks separately before deleting your meetings — those
are yours, and it defaults to keeping them. Add `--keep-data` or `--delete-data`
to skip the question.

## First launch

Echo lives in the menu bar; it has no Dock icon. On first use it asks for two
permissions:

- **Microphone** — to transcribe your voice.
- **System Audio Recording** — to transcribe what other participants say.

It then downloads the transcription and summarization models (several GB, once).
Models and all meeting data live in `~/Library/Application Support/Echo`.

## Privacy

Echo is local-first by design. Audio capture, transcription, and summarization all run on your Mac; nothing is uploaded anywhere. Deleting the folder in `~/Library/Application Support/Echo` removes all of it.

## Development

Open [Echo.xcodeproj](Echo.xcodeproj) in Xcode 26.6+ and run the `Echo` scheme. The WebRTC audio-processing library is vendored in [Vendor/webrtc-apm](Vendor/webrtc-apm); Swift package dependencies resolve automatically.

### Releasing

Releases are built by CI from version tags:

```sh
git tag v0.0.2 && git push origin v0.0.2
```

The [release workflow](.github/workflows/release.yml) builds `Echo.app` (Release, arm64), packages it as `Echo-<version>.zip`, and publishes a GitHub release whose notes carry the install command. The install script reads these releases, so pushing the tag is the whole release. The app version comes from the tag; nothing needs to change in the Xcode project.

> **Note** — Echo is currently a proof of concept. Builds are ad-hoc signed (not notarized by Apple), which is fine when installed through the script above; downloading the zip manually from the Releases page through a browser will trigger Gatekeeper warnings (`xattr -dr com.apple.quarantine /Applications/Echo.app` clears them). Use the install script.
