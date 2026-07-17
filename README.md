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

- macOS 15.6 or later
- Apple Silicon (M-series) Mac
- Disk space for the on-device models (several GB, downloaded on first use)
- [GitHub CLI](https://cli.github.com) (`gh`) with access to this repository, for installation

## Install

```sh
gh api -H "Accept: application/vnd.github.raw" repos/sancrisoft/echo/contents/scripts/install.sh | bash
```

That's it — the script downloads the latest release and installs it to `/Applications`. Echo lives in the menu bar (it has no Dock icon).

Prerequisites: `brew install gh` and `gh auth login` if you haven't already.

<details>
<summary>Install a specific version</summary>

```sh
gh api -H "Accept: application/vnd.github.raw" repos/sancrisoft/echo/contents/scripts/install.sh | bash -s v0.0.1
```

Available versions are listed under [Releases](https://github.com/sancrisoft/echo/releases).
</details>

### Update

Run the same install command again — it replaces the installed app with the latest release.

### Uninstall

```sh
rm -rf /Applications/Echo.app
rm -rf ~/Library/Application\ Support/Echo   # transcripts, summaries, and models
```

## First launch

On first use Echo will ask for two permissions:

- **Microphone** — to transcribe your voice.
- **System Audio Recording** — to transcribe what other meeting participants say.

It will also download the transcription and summarization models (several GB, one time). Model files and all meeting data live in `~/Library/Application Support/Echo`.

## Privacy

Echo is local-first by design. Audio capture, transcription, and summarization all run on your Mac; nothing is uploaded anywhere. Deleting the folder in `~/Library/Application Support/Echo` removes all of it.

## Development

Open [Echo.xcodeproj](Echo.xcodeproj) in Xcode 26.6+ and run the `Echo` scheme. The WebRTC audio-processing library is vendored in [Vendor/webrtc-apm](Vendor/webrtc-apm); Swift package dependencies resolve automatically.

### Releasing

Releases are built by CI from version tags:

```sh
git tag v0.0.2 && git push origin v0.0.2
```

The [release workflow](.github/workflows/release.yml) builds `Echo.app` (Release, arm64), packages it as `Echo-<version>.zip`, and publishes a GitHub release. The app version comes from the tag; nothing needs to change in the Xcode project.

> **Note** — Echo is currently a proof of concept. Builds are ad-hoc signed (not notarized by Apple), which is fine when installed through the script above; downloading the zip manually from the Releases page through a browser will trigger Gatekeeper warnings. Use the install script.
