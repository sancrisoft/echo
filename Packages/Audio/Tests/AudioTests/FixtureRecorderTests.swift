//
//  FixtureRecorderTests.swift
//  AudioTests
//
//  Recorder-side plumbing for the fixture suite: the scenario ids must be
//  exactly the fixture folder names the tests discover, and info.json must
//  stay backward-compatible as the input-device metadata is added. No audio
//  is asserted here — takes are real hardware recordings (project rule: no
//  simulated audio data), and nothing here starts a capture source.
//

#if DEBUG

    import Audio
    import CoreAudio
    import Foundation
    import Testing

    struct FixtureRecorderTests {

        // MARK: - Scenarios

        @Test func scenarioIDsAreTheFixtureFolderNames() {
            // Exact order matters only for the DEBUG picker menu; the raw values
            // are the kebab-case folder names under Fixtures and must never
            // drift from the README.
            #expect(
                FixtureScenario.allCases.map(\.rawValue) == [
                    // The echo-cancellation suite.
                    "bleed-only",
                    "double-talk",
                    "double-talk-baseline",
                    "monologue",
                    "route-change",
                    // The external-input-device suite.
                    "parity-baseline-builtin",
                    "parity-dji-20cm",
                    "parity-dji-50cm",
                    "parity-dji-2cm",
                    "earbuds-in-out",
                    "external-ambient",
                ]
            )
        }

        // MARK: - info.json (write-only: assert the JSON keys explicitly)

        private static let legacyKeys: Set<String> = [
            "scenario", "recordedAt", "durationSeconds", "sampleRate", "outputRouteAtRecordTime",
        ]

        private func encodeToJSONObject(_ info: FixtureRecorder.FixtureInfo) throws -> [String: Any] {
            // Mirror the recorder's encoder configuration.
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(info)
            return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        }

        @Test func infoJSONAddsInputDeviceFactsAlongsideTheOriginalKeys() throws {
            let info = FixtureRecorder.FixtureInfo(
                scenario: "parity-dji-20cm",
                recordedAt: Date(timeIntervalSince1970: 1_782_000_000),
                durationSeconds: 30,
                sampleRate: 16_000,
                outputRouteAtRecordTime: "builtInSpeakers",
                inputDevice: InputDeviceFacts(
                    name: "DJI MIC MINI",
                    transportType: "usb",
                    channelCount: 2,
                    nativeSampleRate: 48_000,
                    inputVolume: 0.75
                )
            )

            let json = try encodeToJSONObject(info)

            // The original keys are unchanged (existing fixture folders stay
            // valid).
            #expect(json["scenario"] as? String == "parity-dji-20cm")
            #expect(json["durationSeconds"] as? Double == 30)
            #expect(json["sampleRate"] as? Double == 16_000)
            #expect(json["outputRouteAtRecordTime"] as? String == "builtInSpeakers")
            #expect(json["recordedAt"] is String)

            // The additive facts: name, transport, channel count, native sample
            // rate, macOS input-volume position.
            let device = try #require(json["inputDevice"] as? [String: Any])
            #expect(device["name"] as? String == "DJI MIC MINI")
            #expect(device["transportType"] as? String == "usb")
            #expect(device["channelCount"] as? Int == 2)
            #expect(device["nativeSampleRate"] as? Double == 48_000)
            #expect(device["inputVolume"] as? Double == 0.75)
        }

        @Test func infoJSONOmitsTheDeviceBlockWhenFactsAreUnreadable() throws {
            let info = FixtureRecorder.FixtureInfo(
                scenario: "monologue",
                recordedAt: Date(timeIntervalSince1970: 1_782_000_000),
                durationSeconds: 30,
                sampleRate: 16_000,
                outputRouteAtRecordTime: "headphones",
                inputDevice: nil
            )

            let json = try encodeToJSONObject(info)

            // Exactly the shape that predates the device block: additive means
            // absent, not null.
            #expect(Set(json.keys) == Self.legacyKeys)
        }

        @Test func infoJSONOmitsInputVolumeWhenTheDeviceExposesNone() throws {
            // Some input devices publish no volume control: record "no slider"
            // honestly instead of a made-up position.
            let info = FixtureRecorder.FixtureInfo(
                scenario: "earbuds-in-out",
                recordedAt: Date(timeIntervalSince1970: 1_782_000_000),
                durationSeconds: 30,
                sampleRate: 16_000,
                outputRouteAtRecordTime: "unsupported",
                inputDevice: InputDeviceFacts(
                    name: "Galaxy Buds",
                    transportType: "bluetooth",
                    channelCount: 1,
                    nativeSampleRate: 16_000,
                    inputVolume: nil
                )
            )

            let json = try encodeToJSONObject(info)
            let device = try #require(json["inputDevice"] as? [String: Any])
            #expect(device["inputVolume"] == nil)
            #expect(device["name"] as? String == "Galaxy Buds")
        }

        @Test func legacyInfoJSONWithoutDeviceFactsStillDecodes() throws {
            // The exact shape the first recorder wrote — fixture folders from
            // before the device block must remain valid should the type ever be
            // used to read.
            let legacy = Data(
                """
                {
                  "durationSeconds" : 31.5899375,
                  "outputRouteAtRecordTime" : "builtInSpeakers",
                  "recordedAt" : "2026-07-03T02:12:33Z",
                  "sampleRate" : 16000,
                  "scenario" : "double-talk"
                }
                """.utf8
            )

            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let info = try decoder.decode(FixtureRecorder.FixtureInfo.self, from: legacy)

            #expect(info.scenario == "double-talk")
            #expect(info.inputDevice == nil)
        }

        // MARK: - Transport naming (pure mapping)

        @Test func transportNamesCoverTheCommonTransportsWithFourCCFallback() {
            #expect(InputDeviceFactsReader.transportName(kAudioDeviceTransportTypeBuiltIn) == "builtIn")
            #expect(InputDeviceFactsReader.transportName(kAudioDeviceTransportTypeUSB) == "usb")
            #expect(InputDeviceFactsReader.transportName(kAudioDeviceTransportTypeBluetooth) == "bluetooth")
            #expect(InputDeviceFactsReader.transportName(kAudioDeviceTransportTypeBluetoothLE) == "bluetoothLE")
            #expect(InputDeviceFactsReader.transportName(kAudioDeviceTransportTypeAggregate) == "aggregate")
            #expect(InputDeviceFactsReader.transportName(kAudioDeviceTransportTypeUnknown) == "unknown")
            // Unrecognized transports stay identifiable via their four-char code…
            #expect(InputDeviceFactsReader.transportName(0x7465_7374) == "test")
            // …and non-printable values degrade to the raw number.
            #expect(InputDeviceFactsReader.transportName(3) == "3")
        }
    }

#endif
