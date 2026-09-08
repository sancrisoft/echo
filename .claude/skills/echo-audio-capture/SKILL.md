---
name: echo-audio-capture
description: Rules and measured hazards for Echo's dual-stream capture path — the microphone or system-audio channels, `MicrophoneCapture`, `SystemAudioCapture`, `CaptureRateGuard`, `AudioDownmixer`, level meters and waveforms, and symptoms like double-speed audio, a short or silent Team channel, a dropped external mic, or a wave that swims at constant height.
---

## The stack is not what the root docs say

`AGENTS.md` / `CLAUDE.md` still name ScreenCaptureKit, WhisperKit and SpeakerKit. All three are wrong; that text is stale and the code is the truth:

- Mic = `AVAudioEngine` tap (`MicrophoneCapture.swift`), rebuilt fresh on every `start()` so a device change is a restart.
- System audio = Core Audio **process taps**, not ScreenCaptureKit (`SystemAudioCapture.swift:7`). That choice is deliberate: no purple screen-recording indicator, DRM playback keeps working.
- Both channels resample to 16 kHz mono Float32 (`AudioConstants.captureFormat`).
- No diarization anywhere. `speaker` is the channel.

## The declared sample rate is a lie, and measurement outranks it

A Bluetooth headset drops the output device to 24 kHz while macOS keeps reporting 48 kHz (Apple Forums 770232) — the Team channel recorded at double speed. Worse, a Meet call delivered 512-frame cycles every 11.62 ms while declaring 48 kHz: 11.62/10.67 = 48000/44100, so **8% of every meeting was missing** and the guard called it a match.

- `CaptureRateGuard.tolerance` is **0.02**. It was 0.10 to spare 44.1-vs-48 on the untested assumption that the tap resamples that itself. Never widen it (`CaptureRateGuard.swift:87-104`).
- Two clocks, not one: delivered frames *and* the device sample clock must agree the stream ran unbroken (`continuitySlack` 0.02), so silence is `.measuring`, never a wrong correction.
- `discreditedRates` exists because defence 1 (measurement) and defence 2 (format notifications) otherwise flip-flop until the lie wins the correction budget (`maxCorrections` 3). A re-declared discredited rate is ignored (`SystemAudioCapture.swift:155-162`, `:873`).
- Corrections are gapless re-labels of the format, not tap rebuilds (`adoptSampleRate`).
- The aggregate is anchored to the start-time output device and cannot follow it, so an output-device change owes a full restart (`RecordingController.swift:1486` → `scheduleSystemCaptureRestart`), guarded on the session's own effective scope so it cannot race the first tap.

## Window by duration, never by callback count

The two taps fire ~8x apart and the code looks symmetric, which is the trap. Measured on this Mac at 48 kHz: the mic tap delivers **4800-frame buffers, exactly 100.0 ms**, whatever `tapBufferSize` asks for (`MicrophoneCapture.swift:43-47` — the request is advisory and macOS clamps it); the system IO proc runs ~10.7-11.6 ms per cycle.

- `RecordingState.levelWindow` = 0.06 s, deliberately **under** the mic cadence so the mic falls through to its newest reading while the fast tap still averages ~5 callbacks. Averaging wider than the cadence is pure display latency, not smoothing.
- `RecordingState.levelStaleAfter` = 0.5 s keeps a slow tap rendering its newest reading instead of flatlining; only a dead device rests.
- When a slow source feeds a fast display, interpolate **at the view** (`GlidingLevel` in `WaveformView.swift:119`, slide bounded 0.008-0.12 s). Do not slow the display and never fabricate readings.
- Levels and waveforms come from real capture only. A `RecordingState` driven by a random simulator timer was rejected outright; if the real source is not wired yet, ask rather than stub.

## Downmix by max magnitude, not by average

`AudioDownmixer.toMono` picks the largest-|value| sample per frame, sign preserved (ADR-004). Two reasons, both measured: `AVAudioConverter` keeps only channel 0 on multi-mic USB receivers that report no channel layout (a DJI Mic Mini silently loses TX2), and averaging attenuates a lone transmitter by 1/N — 6 dB on a two-channel receiver, which put the DJI's native rms `[0.0078, 0.0000]` below the speech gates and transcribed 0% at 20/50 cm. Max-magnitude keeps duplicated stereo bit-identical and no output sample is quieter than the old average.

## Core Audio tap traps

- Do **not** touch `isExclusive` on the global tap. `CATapDescription(monoGlobalTapButExcludeProcesses:)` sets it true ("exclude the listed PIDs"); flipping it inverts to "include only these (none)" and the tap delivers pure silence (`SystemAudioCapture.swift:276-279`).
- A scoped tap's include set is updated by writing a *description* back to `kAudioTapPropertyDescription` — mutate the **kept** `CATapDescription` so the tap UUID the aggregate references stays stable. An empty include set is legal at creation and at every point after; growing and shrinking both work live, no rebuild.
- `ioQueue` is `.userInteractive` on purpose. The per-cycle body is measured at 0.013 ms of a ~10.67 ms budget (`CaptureCallbackCostTests`, kept as a guard at 25%), so a loss is in *reaching* the block, never in running it — do not "optimize" callback work to fix a short channel.

## Diagnose from the audio, not from the code

The Team channel's 8% shortfall was first attributed to slow tap bring-up, inferred from the start order in `RecordingController.start`. Decoding the m4a and printing per-100 ms RMS showed **no silence at the head** — the theory was false and pre-warming the tap is dead as an idea. Every downstream suspect (writer backlog, dropped IO cycles, callback cost) was then ruled out by counters before the real cause appeared. Decode the audio and look first.

- `Logger.info` is never persisted and `log show` returns zero lines from an agent sandbox — persist capture diagnostics through `ErrorTrace.record` into `Logs/*.ndjson` (`SystemAudioCapture.traceRateCorrection`, `rateGuardConclusions`).
- `SystemAudioCapture` instances are reused across sessions, so one-shot log flags must be reset per activation.
- An absent Team channel still raises no notice: `InputHealthClassifier` keys on discarded *activity* (`activityMinimumRMS` 0.004, `activeRatio` 0.3, `crestFactor` 1.5, `onsetBound` 30 s), and its whole `// TUNABLE (SP-002 OQ7)` block is provisional and unmeasured — do not treat those numbers as validated.
