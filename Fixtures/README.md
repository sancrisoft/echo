# Echo Fixture Suite

Real-hardware WAV recordings that drive the recorded-fixture tests:

- **SP-001 — echo cancellation:** `AECSignalLevelTests` (fast, signal-level),
  `AECAcceptanceTests` (slow, end-to-end through the Parakeet pass), and the
  fixture-profile tests at the end of `GateDiagnosticsTests` (fast, per-chunk
  gate verdicts on the `bleed-only` and `monologue` takes).
- **SP-002 — external input devices:** `ExternalInputMeasurementTests` (no
  model; it writes the full breakdown to
  `EchoTests/sp002-measure-report.txt`). These takes double as the recorded
  runs of BRN-002's confirmation experiment (built-in control, DJI at
  distance, earbuds input+output).

Until a scenario's fixtures exist, the tests that need them **skip** with a
pointer to this file. That is a normal end state, not a failure: every
scenario is gated on its own folder, so record the scenarios your hardware
can produce and let the rest skip. The SP-001 set needs nothing but the Mac
and a pair of wired headphones; most of SP-002 needs specific external
hardware (see that section). This README is the only file under `Fixtures/`
that is committed — the recordings stay on the machine that made them.

## Hard rules

- **Fixtures are real hardware recordings. Never synthesize, generate, mix,
  trim, normalize, or otherwise edit them** (project rule: no simulated audio
  data). Every threshold in these suites was calibrated against what real
  hardware actually does, so an edited take does not fail loudly — it
  silently answers a different question, and the number it produces looks
  exactly as trustworthy as a real one. Re-recording is the only correction:
  there is no bad take an editor can rescue.
- Every scenario names its hardware. The SP-001 scenarios use the Mac's
  **built-in microphone and built-in loudspeakers** (single exception:
  `double-talk-baseline`, which is recorded wearing **wired headphones**).
  Each SP-002 scenario names its input device below. Record the SP-001 set on
  the built-in mic even when a nicer one is plugged in: `FixtureSupportTests`
  asserts that `bleed-only` has *no* `mic-native.wav`, so a multi-channel
  input device there fails a test that has nothing to do with echo
  cancellation.
- `mic.wav` is the raw near-end signal (pre-AEC, bleed included);
  `system.wav` is the far-end reference. The recorder guarantees this — there
  is no AEC anywhere in its capture path.
- `mic-native.wav` appears automatically whenever the input device reports
  more than one channel (the DJI receiver does): the mic's native
  **pre-downmix** stream at the device's own sample rate and channel count,
  preserved so the max-magnitude downmix (ADR-004) stays offline-testable
  against real device audio. Mono devices produce no such file. Same rule as
  above: never edit it, and never delete it from a multi-channel take.

## Layout

```
Fixtures/
  # SP-001 — echo cancellation
  bleed-only/               mic.wav  system.wav  info.json
  double-talk/              mic.wav  system.wav  info.json
  double-talk-baseline/     mic.wav  system.wav  info.json
  monologue/                mic.wav  system.wav  info.json
  route-change/             mic.wav  system.wav  info.json
  # SP-002 — external input devices
  parity-baseline-builtin/  mic.wav  system.wav  info.json
  parity-dji-20cm/          mic.wav  system.wav  mic-native.wav  info.json
  parity-dji-50cm/          mic.wav  system.wav  mic-native.wav  info.json
  parity-dji-2cm/           mic.wav  system.wav  mic-native.wav  info.json
  earbuds-in-out/           mic.wav  system.wav  info.json
  external-ambient/         mic.wav  system.wav  mic-native.wav  info.json
```

A fresh clone has only this README under `Fixtures/`; the recorder creates
each `{scenario}/` folder on that scenario's first take.

The `mic-native.wav` column assumes the DJI reports two channels (TX1/TX2)
and a Bluetooth earbuds microphone reports one. If a device surprises you
either way, the recorder is right and this table is wrong: it writes the
file exactly when the tap format is multi-channel.

`info.json` is metadata for humans — the tests read only the WAVs. It
records the scenario name, the date, the take's duration and its canonical
16 kHz sample rate, and the output route at record time, and — since
SP-002 — the input device's facts (name, transport, channel count, native
sample rate) plus the macOS input-volume position.

It is also the fastest check on a finished take: `durationSeconds` should
read ~30, `inputDevice.name` must be the device the scenario names,
`inputVolume` must be the same number across a whole session, and
`outputRouteAtRecordTime` reads `builtInSpeakers`, `headphones` or
`unsupported`. Bluetooth always classifies as `unsupported`, so
`earbuds-in-out` reading `unsupported` is correct rather than a bad take.

## How to record a take

1. Build and run Echo in **Debug** — open `Echo.xcodeproj` and run the `Echo`
   scheme (⌘R). The recorder is DEBUG-only, so an installed Echo does not
   have it; quit that one first, since both instances share
   `~/Library/Application Support/Echo` and only one may own it.
2. The first take asks macOS for **Microphone** and **System Audio
   Recording** permission. Grant both: without the microphone the take fails
   at once ("Microphone permission denied"), and a system tap that comes up
   deaf ends it with "No system audio was captured — nothing was written".
   Doing one normal recording (Start Recording → Stop) first gets both
   prompts out of the way.
3. Set the **input device** for the scenario: System Settings → Sound →
   **Input** → select the device the scenario names (SP-001 scenarios: the
   built-in microphone).
4. Check the **input volume** slider on that same screen — record it
   mentally, then **do not move it for the rest of the session**. Takes
   recorded at different slider positions are not level-comparable, and the
   whole point of the SP-002 set is level comparison. The recorder stores
   the position in `info.json`, so "was the slider sane?" is answerable
   after the fact instead of from memory.
5. Set the **output route** for the scenario: System Settings → Sound →
   Output → **MacBook Speakers** (or what the scenario names). Use a normal
   meeting volume (roughly 50–75%).
6. Sit in a quiet room at your normal working distance from the Mac.
7. Queue up "teammate audio" for the scenarios that need it: any recorded
   talk or meeting video with continuous speech (browser/QuickTime), **not**
   your own voice.
8. Click the Echo item in the **menu bar** (Echo has no Dock icon) →
   **Record Fixture…**, the last row of the popover, under the divider →
   pick the scenario. That menu is disabled while a normal recording runs.
9. In the folder dialog ("Choose the fixtures folder"), choose this directory
   (`Fixtures`) — ⌘⇧G types a path — and press **Record**. The take is
   written to `Fixtures/{scenario}/`.
10. A 3-second countdown runs, then the recorder captures **30 seconds** and
    shows the seconds remaining in the popover. Use that counter for the
    scripted timing below, and keep the popover open for the whole take — it
    is the only clock you get, and clicking into another app to fix something
    both hides it and puts the click on the mic track.
11. Done looks like "Fixture saved to …/Fixtures/{scenario}" under that menu.
    A failure reads "Fixture recording failed: …" instead and writes nothing.
12. **Listen to both WAVs before recording the next scenario** — `afplay
    Fixtures/{scenario}/mic.wav`, then `system.wav` — and read `info.json`.
    The recorder only refuses a channel that captured *nothing*: a take with
    the teammate audio paused, the wrong input device selected, or your voice
    off-mic is written out happily and surfaces much later as a puzzling test
    result.
13. A bad take? Just record the scenario again — files are overwritten,
    including a stale `mic-native.wav` from an earlier multi-channel take.
    Never repair one in an editor (see Hard rules).

Do not start a normal Echo recording while a fixture take is running: the
fixture menu disables itself while a recording is live, but not the other way
round, and both would fight over the capture hardware.

## The scripted utterance set

One script serves every scripted scenario — `double-talk`,
`double-talk-baseline`, the four SP-002 parity takes, and `earbuds-in-out` —
so takes stay comparable utterance by utterance (parity is judged relative
to the baseline take of the same script). Read the lines **at the exact
counter positions** — the spans are hardcoded in
`AECSignalLevelTests.doubleTalkSpans` (12–16 s, 18–22 s, 24–28 s from take
start):

| Counter shows | Elapsed | Say                                                          |
| ------------- | ------- | ------------------------------------------------------------ |
| 18 s left     | 12 s    | "The quarterly report is ready for review tomorrow morning." |
| 12 s left     | 18 s    | "I will send the updated design document after this call."   |
| 6 s left      | 24 s    | "Let's schedule the follow-up meeting for next Wednesday afternoon." |

Speak at your normal meeting volume, each line taking roughly its full
4-second span. Stay silent between lines. On the distance takes, **never
lean toward the microphone to compensate** — the distance under test is the
point.

## SP-001 scenarios (echo cancellation)

### `bleed-only` — teammate audio, user silent

Start the teammate audio playing through the built-in speakers *before*
triggering the recorder, and keep it playing for the whole take. **Stay
completely silent** — no typing, no chair noise. This is the speaker-bleed
scenario: everything on `mic.wav` after the room's contribution is echo.

### `double-talk` — scripted user speech over teammate audio

Teammate audio keeps playing through the speakers for the whole take. You
read the scripted utterance set above at its counter positions.

### `double-talk-baseline` — same script, wearing headphones

Identical to `double-talk` (same teammate audio source, same script, same
counter timing) but with **wired headphones** in the Mac's own headphone
jack, so there is no speaker bleed on the mic. Only that jack classifies as
`headphones` in `info.json` — a USB or Bluetooth headset reads as
`unsupported` — which is what makes a baseline take self-documenting after
the fact. Echo processing is bypassed on this route; the take defines which
utterances the transcription model can hear at all, so AEC is only charged
for utterances it *loses* relative to this baseline (SP-001 double-talk
criterion). `AECAcceptanceTests` needs this take *and* `double-talk`: with
only one of the two, its double-talk test skips.

### `monologue` — user speech, nothing playing

Nothing plays on the system side (close the video; the system channel
records silence). Speak continuously for the whole take — describe your day,
read a paragraph, anything natural. Verifies a silent far end causes no
attenuation of user speech.

### `route-change` — headphones plugged in mid-take

Start on built-in speakers with teammate audio playing (as in `bleed-only`).
When the counter shows about **15 s left**, plug in wired headphones and let
the take finish. Captures the mid-recording route change with its reset and
re-convergence. No automated test consumes this fixture yet — it exists for
manual verification and future tests.

## SP-002 scenarios (external input devices)

These six takes are both the parity fixtures and the recorded form of the
confirmation experiment (SP-002 "measurement before fix"). Record them as
**one session**: same room, same voice level, and — per device — the same
input-volume slider position throughout.

Most of this set is hardware-specific, and reproducing it is not the reader's
problem: `parity-dji-*` and `external-ambient` need a two-channel USB
wireless-mic receiver (a DJI Mic here), and `earbuds-in-out` needs Bluetooth
earbuds. Without that hardware, record `parity-baseline-builtin` — built-in
mic, nothing extra — and stop there. `ExternalInputMeasurementTests` gates on
that one take, prints "NOT RECORDED — skipped" for every scenario it cannot
find, and runs each device-specific assertion only when its take exists.

If you do record these on other hardware, read
`EchoTests/sp002-measure-report.txt` rather than the pass/fail line. The
numbers the suite pins — the external mic reaching 70% of the baseline's
transcribed seconds, the averaging downmix collapsing below 1 s, the
max-magnitude downmix restoring more than 5 s — are findings measured on one
specific receiver, kept so they cannot silently rot. On a different device
the report is the answer; those guards are not a verdict on your microphone.

Device and setup notes:

- **DJI Mic:** plug the USB receiver into the Mac and select it as the
  input device. Power on **one transmitter only** and leave the other in
  the charging case — a single active TX on a two-channel receiver is
  exactly the configuration whose downmix penalty ADR-004 exists for, and
  the mixed-in second channel would muddy the native fixture. Distances are
  mouth-to-transmitter; clip or hold the TX at the stated distance.
- **Bluetooth earbuds:** pair them before the session; only
  `earbuds-in-out` uses them, as **both** input and output.
- The system side stays **silent** for the parity and ambient takes (close
  the teammate-audio tab): the dropout reproduces in total silence, and a
  silent far end keeps every mic-channel gate measurement attributable to
  your speech alone instead of speaker bleed. Only `earbuds-in-out` plays
  teammate audio.

### `parity-baseline-builtin` — the script on the built-in mic

Input: **built-in microphone**. Output: MacBook Speakers, nothing playing.
Sit at your normal conversational distance from the Mac (roughly 40 cm) and
read the scripted utterance set at its counter positions. Every parity
comparison is relative to this take, so treat it as the reference
performance: normal voice, normal posture, no leaning in.

### `parity-dji-20cm` — the script on the DJI at working distance

Input: **DJI receiver**. Output: MacBook Speakers, nothing playing.
Transmitter at **20 cm** from your mouth. Read the same script at the same
counter positions, at the same voice level as the baseline take. This is the
distance the reported dropout was measured at, and where `mic-native.wav`
earns its keep: the shipping max-magnitude path (ADR-004) transcribes this
take, while the same native channels replayed through the old averaging
downmix still go silent — the before/after part B of
`ExternalInputMeasurementTests` prints.

### `parity-dji-50cm` — the script on the DJI at desk distance

Same as `parity-dji-20cm` with the transmitter at **50 cm** (propped on the
desk is fine). This is the far end of the parity bar: SP-002 requires
baseline-equivalent transcription at 20 cm *and* 50 cm.

### `parity-dji-2cm` — the script on the DJI at lip distance

Same again with the transmitter at **2 cm** — practically touching your
lips. The configuration that worked even before the downmix fix; it anchored
the experiment's prediction (BRN-002: DJI at 20 cm fails the level terms,
DJI at 2 cm passes, the control passes with margin). It carries no assertion
of its own — it appears in the measurement report as the loud-end anchor.

### `earbuds-in-out` — earbuds as input *and* output

Select the earbuds as **both** the input and the output device. Start
teammate audio playing — you should hear it in the earbuds — *before*
triggering the recorder and keep it playing for the whole take, then read
the script at its counter positions over it, exactly as in `double-talk`.
This records both sides of the reported dropout: `system.wav` is what the
tap captured while Bluetooth held the output route (the silently mute Team
channel), and `mic.wav` is what the earbuds' microphone delivered over its
Bluetooth profile.

### `external-ambient` — DJI ambience, user silent

Input: **DJI receiver**, transmitter clipped at the `parity-dji-20cm`
position. Output: MacBook Speakers, nothing playing. **Stay completely
silent** — no typing, no chair noise; normal room ambience only. This is
the false-positive guard behind the input-health notice: sustained quiet on
an external mic must keep producing zero transcribable chunks. That is the
half a recording can prove; the notice's own onset and clearing rules are
table-driven in `InputHealthClassifierTests`, which needs no fixtures.

## Watching the gate decisions live

Gate decisions are logged by the transcription pipeline, not by the fixture
recorder — a fixture take writes raw WAVs and never runs the speech gates.
To watch verdicts live, run a **normal Echo recording** in the same device
configuration (this is the live half of the confirmation experiment; run it
after the fixture takes, never at the same time). In a terminal:

```sh
log stream --predicate 'subsystem == "com.sancrisoft.Echo" AND category == "GateDiagnostics"' --level notice
```

Then start a recording in Echo, perform the same scripted utterances, and
watch the lines arrive — one per finalized chunk, roughly every 1–12 s per
channel:

```
gate microphone drop t=42.10s dur=4.02s rms=0.0071 peak=0.0312 crest=3.1 speech=0.14 strong=0.02 active=0.55 floor=0.0021 dyn=7.4dB failed=clearSpeechRMS+clearSpeechPeak+loudFallbackRMS+loudFallbackPeak+loudFallbackWindowRatio
```

`failed=` names every gate term the chunk missed (`GateDiagnostics.swift`
holds the full list with thresholds): the `…RMS`/`…Peak` terms are **level**
terms, the `…WindowRatio`/`…CrestFactor`/`…Dynamics` terms are **shape**
terms — which family fails for the DJI at 20 cm is SP-002's open question 1.
The lines persist in the local log store, so a session is also inspectable
after the fact:

```sh
log show --last 1h --predicate 'subsystem == "com.sancrisoft.Echo" AND category == "GateDiagnostics"'
```

## Meeting transcript samples (summary parity)

`meeting-samples/` holds **real meeting transcripts as plain text** — verbatim
copies of the Notion reference pairs used to calibrate the adaptive markdown
summary (`meetings_sample/<name>/transcript.txt` → `meeting-samples/<name>.txt`,
blank-line-separated paragraphs). They drive the acceptance-gated
`SummaryNotionParityTests` suite, which generates a REAL summary for each
sample and checks the distilled Notion quality rules structurally.

```
Fixtures/
  meeting-samples/
    checkin-echo-2.txt          # ~50% social small talk (the omission trap)
    checkin-gocoinvest-2.txt    # short, messy call (density scaling)
    output-*.md                 # written by the tests — the generated summary,
                                # for human side-by-side review vs the Notion
                                # reference (overwritten every run)
```

Same hard rule as the audio takes: **this is real meeting content and it never
enters git** (everything under `Fixtures/` except this README is ignored). Test
sources may name the samples but must never quote their content beyond short
assertion markers. Until the `.txt` files exist, the parity tests skip with a
pointer here — the expected state for anyone who does not have those two
meetings. Both file names are hardcoded in the suite and its assertions are
calibrated to what those two calls actually contain (the small talk that must
be omitted, the work substance that must survive), so a different transcript
filed under the same name proves nothing. This suite is also the one here that
*downloads*: unlike the AEC acceptance suite it fetches the summary model
(~3.3 GB) if it is not on disk yet.

## Running the tests

Signal-level tests run as part of the normal suite and activate automatically
once their fixture folders exist:

```sh
xcodebuild test -project Echo.xcodeproj -scheme Echo \
  -destination 'platform=macOS,arch=arm64' \
  -skipMacroValidation -skipPackagePluginValidation
```

The tests are hosted in `Echo.app` and share its data folder, so do not run
them while your own Echo is recording.

The acceptance suite loads the Parakeet model (which must already be on
disk — it never downloads) and is additionally gated on
the `ECHO_ACCEPTANCE` environment variable (xcodebuild forwards variables
prefixed with `TEST_RUNNER_` into the test process):

```sh
TEST_RUNNER_ECHO_ACCEPTANCE=1 xcodebuild test \
  -project Echo.xcodeproj -scheme Echo \
  -destination 'platform=macOS,arch=arm64' \
  -skipMacroValidation -skipPackagePluginValidation \
  -parallel-testing-enabled NO \
  -only-testing:EchoTests/AECAcceptanceTests
```

(In Xcode: edit the Echo scheme → Test → Environment Variables →
`ECHO_ACCEPTANCE=1`.)

Getting the model on disk: launch Echo, open its window ("Open Echo" in the
popover) and watch the models banner at the top. The transcription row
(Parakeet v3, ~480 MB) downloads itself on launch and ends at **Ready**; the
files land in
`~/Library/Application Support/Echo/Models/parakeet-tdt-0.6b-v3-coreml/`,
which is exactly where the suite looks.
