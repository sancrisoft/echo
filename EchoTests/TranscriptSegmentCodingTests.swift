//
//  TranscriptSegmentCodingTests.swift
//  EchoTests
//
//  SP-007 S1 (ADR-023): `speaker` persists as a plain string ("me" /
//  "teammates") instead of the synthesized enum-object form
//  ({"teammates": {}}), and decoding is tolerant — the legacy object form
//  and unknown speaker strings both load, falling back to the
//  channel-derived default (mic → me, system → teammates) rather than
//  failing the meeting. No migration, no schemaVersion bump: old files
//  stay byte-untouched and simply keep decoding.
//

import Foundation
import Testing
@testable import Echo

struct TranscriptSegmentCodingTests {

    // MARK: - Helpers

    /// Mirrors MeetingStore's encoder settings so assertions on encoded
    /// shape match what actually lands on disk.
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private static func makeSegment(
        channel: AudioChannel = .microphone,
        speaker: Speaker = .me
    ) -> TranscriptSegment {
        TranscriptSegment(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            channel: channel,
            speaker: speaker,
            text: "Hello",
            start: 1.0,
            end: 2.5
        )
    }

    // MARK: - Encoding

    @Test("speaker encodes as a plain string, not the legacy enum object")
    func speakerEncodesAsPlainString() throws {
        let data = try Self.encoder.encode(Self.makeSegment(channel: .microphone, speaker: .me))
        let json = String(decoding: data, as: UTF8.self)

        #expect(json.contains(#""speaker" : "me""#))
        #expect(!json.contains(#""speaker" : {"#))
    }

    // MARK: - Decoding

    @Test("the new string form round-trips")
    func stringFormRoundTrips() throws {
        let original = Self.makeSegment(channel: .system, speaker: .teammates)
        let data = try Self.encoder.encode(original)
        let decoded = try Self.decoder.decode(TranscriptSegment.self, from: data)

        #expect(decoded == original)
    }

    @Test("the legacy object speaker form still decodes (old meetings keep opening)")
    func legacyObjectFormDecodes() throws {
        // Verbatim shape of a pre-SP-007 transcript.json entry.
        let legacy = """
        {
          "channel" : "system",
          "end" : 2.5,
          "id" : "00000000-0000-0000-0000-000000000001",
          "speaker" : {
            "teammates" : {

            }
          },
          "start" : 1,
          "text" : "Hello"
        }
        """
        let decoded = try Self.decoder.decode(TranscriptSegment.self, from: Data(legacy.utf8))
        #expect(decoded.speaker == .teammates)

        let legacyMe = """
        {
          "channel" : "microphone",
          "end" : 2.5,
          "id" : "00000000-0000-0000-0000-000000000001",
          "speaker" : {
            "me" : {

            }
          },
          "start" : 1,
          "text" : "Hello"
        }
        """
        let decodedMe = try Self.decoder.decode(TranscriptSegment.self, from: Data(legacyMe.utf8))
        #expect(decodedMe.speaker == .me)
    }

    @Test(
        "an unrecognized speaker string falls back to the channel-derived default",
        arguments: [
            (channel: "system", expected: Speaker.teammates),
            (channel: "microphone", expected: Speaker.me),
        ]
    )
    func unknownSpeakerFallsBackToChannelDefault(channel: String, expected: Speaker) throws {
        // Forward room for diarization labels (ADR-023): an unknown speaker
        // must never fail the meeting load — channel is the source of truth.
        let json = """
        {
          "channel" : "\(channel)",
          "end" : 2.5,
          "id" : "00000000-0000-0000-0000-000000000001",
          "speaker" : "diarized-3",
          "start" : 1,
          "text" : "Hello"
        }
        """
        let decoded = try Self.decoder.decode(TranscriptSegment.self, from: Data(json.utf8))
        #expect(decoded.speaker == expected)
    }

    @Test("a transcript array mixing legacy and new speaker forms decodes")
    func mixedFormsArrayDecodes() throws {
        // The shape MeetingStore.loadRecord actually reads: one transcript.json
        // holding segments written by different app versions must never fail.
        let json = """
        [
          {
            "channel" : "microphone",
            "end" : 1,
            "id" : "00000000-0000-0000-0000-000000000001",
            "speaker" : {
              "me" : {

              }
            },
            "start" : 0,
            "text" : "Old mic segment"
          },
          {
            "channel" : "system",
            "end" : 2,
            "id" : "00000000-0000-0000-0000-000000000002",
            "speaker" : "teammates",
            "start" : 1,
            "text" : "New team segment"
          },
          {
            "channel" : "system",
            "end" : 3,
            "id" : "00000000-0000-0000-0000-000000000003",
            "speaker" : "diarized-3",
            "start" : 2,
            "text" : "Future diarized segment"
          }
        ]
        """
        let decoded = try Self.decoder.decode([TranscriptSegment].self, from: Data(json.utf8))

        #expect(decoded.count == 3)
        #expect(decoded.map(\.speaker) == [.me, .teammates, .teammates])
    }
}
