# Fixtures

Real recordings and real meeting transcripts the acceptance suites replay. They
never enter the repository: everything in this folder except this file is
gitignored, and the suites that need a fixture skip with a note when it is
missing. Tests find this folder from their own file path, not from a bundle
(`Fixtures.root` in `EchoCoreTestSupport`).

## Layout

```
Fixtures/
├── <scenario>/            one dual-channel take, ~30 s
│   ├── mic.wav            microphone, 16 kHz mono Float32 (the user)
│   ├── system.wav         system audio, 16 kHz mono Float32 (the others)
│   ├── mic-native.wav     optional: the mic at the device's native rate and
│   │                      channel count (multi-channel receivers)
│   └── info.json          scenario, recordedAt, durationSeconds, sampleRate,
│                          outputRouteAtRecordTime, inputDevice{…}
└── meeting-samples/
    ├── <name>.txt         a real transcript, blank-line-separated paragraphs
    └── output-<name>.md   written by the summarization parity suite
```

Scenarios the suites know: `bleed-only`, `double-talk`, `double-talk-baseline`,
`earbuds-in-out`, `external-ambient`, `monologue`, `parity-baseline-builtin`,
`parity-dji-2cm`, `parity-dji-20cm`, `parity-dji-50cm`, `route-change`.

## Recording a scenario

Fixtures are recorded on real hardware with the DEBUG fixture recorder (it
arrives with the Audio package). There is deliberately no echo cancellation in
its path: `mic.wav` is the raw near-end signal including speaker bleed,
`system.wav` the far-end reference. Never synthesize audio and present it as a
fixture; synthetic signals belong inside a test, generated at runtime.

## Running the suites that use them

```sh
ECHO_ACCEPTANCE=1 swift test --package-path Packages/<Package>
```

Acceptance suites also need the on-device models already downloaded; they never
fetch them.
