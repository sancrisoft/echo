//
//  TranscriptAccuracyAcceptanceTests.swift
//  EchoTests
//
//  The WER harness — the executable form of the "measured baseline" Success
//  Criterion. Each local fixture case is transcribed by the production pass
//  and scored per channel against a local human-corrected reference, and the
//  WER table is printed (the printed table IS the recorded baseline).
//
//  There is one engine now, so there is no live-vs-final comparison left to
//  make: the never-worse assertion died with the live pipeline it was
//  relative to. What remains asserted is no-text-on-silence, plus the
//  vacuity guard. Absolute WER targets are the user's to set against a
//  printed baseline — this harness measures, it does not judge.
//
//  Local fixture convention (fixtures are personal recordings and are NEVER
//  committed — SP-005 Privacy):
//
//      ~/EchoAccuracyFixtures/<case-name>/
//          mic.wav               You-channel audio (16 kHz mono Float32
//                                preferred; anything AVAudioFile reads works)
//          system.wav            Team-channel audio (same formats)
//          reference-mic.txt     human-corrected reference for mic.wav
//          reference-system.txt  human-corrected reference for system.wav
//          notes.txt             optional, ignored
//
//  Each channel is optional, but a channel's wav and reference travel
//  together. A case whose name ends in "-silence" holds non-speech audio:
//  its references may be absent (the implied reference is empty) and the
//  final pass must produce NO segments for it.
//
//  Slow: loads the Parakeet model (which must already be on disk), so it is
//  gated on ECHO_ACCEPTANCE=1 in addition to the local fixtures — see
//  Acceptance.gate for the invocation.
//

import Foundation
import Testing
@testable import Echo

nonisolated enum AccuracyFixtures {

    /// Accuracy fixtures live OUTSIDE the repository, in the user's home
    /// folder — unlike EchoTests/Fixtures they are full meeting-shaped
    /// personal recordings and must never be committed (SP-005 Privacy).
    static var root: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("EchoAccuracyFixtures", isDirectory: true)
    }

    /// Skip reason shown while no local fixture case exists.
    static let instructions: Comment = """
    No accuracy fixtures found. Place cases at \
    ~/EchoAccuracyFixtures/<case-name>/ containing mic.wav and/or system.wav \
    (16 kHz mono Float32 preferred; anything AVAudioFile reads works) plus \
    reference-mic.txt / reference-system.txt holding the human-corrected \
    reference transcript for each audio file present (optional notes.txt is \
    ignored). Name non-speech cases with a -silence suffix — their \
    references may be omitted. Fixtures are personal recordings and are \
    never committed to the repository.
    """

    /// One scoreable channel of a fixture case.
    struct ChannelFixture {
        let channel: AudioChannel
        let wav: URL
        let referenceURL: URL
    }

    /// Non-speech cases carry the silence-hallucination assertion instead
    /// of a reference transcript.
    static func isSilenceCase(_ name: String) -> Bool {
        name.hasSuffix("-silence")
    }

    /// Case directories contributing at least one scoreable channel, sorted
    /// by name. `root` is injectable so the always-running plumbing tests
    /// below can drive discovery against temp layouts.
    static func caseNames(under root: URL = root) -> [String] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map(\.lastPathComponent)
            .filter { !channels(for: $0, under: root).isEmpty }
            .sorted()
    }

    /// The channels a case provides: the wav must exist, and so must its
    /// reference — except for -silence cases, where the reference is
    /// implicitly empty.
    static func channels(for caseName: String, under root: URL = root) -> [ChannelFixture] {
        let folder = root.appendingPathComponent(caseName, isDirectory: true)
        let layout: [(AudioChannel, String, String)] = [
            (.microphone, "mic.wav", "reference-mic.txt"),
            (.system, "system.wav", "reference-system.txt"),
        ]
        return layout.compactMap { channel, wavName, referenceName in
            let wav = folder.appendingPathComponent(wavName)
            let reference = folder.appendingPathComponent(referenceName)
            guard FileManager.default.fileExists(atPath: wav.path) else { return nil }
            guard FileManager.default.fileExists(atPath: reference.path) || isSilenceCase(caseName) else {
                return nil
            }
            return ChannelFixture(channel: channel, wav: wav, referenceURL: reference)
        }
    }

    static func reference(for fixture: ChannelFixture) -> String {
        (try? String(contentsOf: fixture.referenceURL, encoding: .utf8)) ?? ""
    }
}

@Suite(.serialized, .enabled(if: Acceptance.isEnabled, Acceptance.gate))
struct TranscriptAccuracyAcceptanceTests {

    @Test(.enabled(if: !AccuracyFixtures.caseNames().isEmpty, AccuracyFixtures.instructions))
    func transcriptionWERBaseline() async throws {
        var rows = ["case | channel | WER (S/I/D) | ref words"]
        var sawSpeechSegments = false

        for caseName in AccuracyFixtures.caseNames() {
            let fixtures = AccuracyFixtures.channels(for: caseName)
            var audio: [AudioChannel: [Float]] = [:]
            for fixture in fixtures {
                audio[fixture.channel] = try Fixtures.loadWAV(at: fixture.wav)
            }

            let segments = try await Acceptance.transcribe(audio)

            if AccuracyFixtures.isSilenceCase(caseName) {
                // No text on silence — fixture-verified, never assumed.
                #expect(
                    segments.isEmpty,
                    "the pass invented text on silence (\(caseName)): \(segments.map(\.text))"
                )
            } else if !segments.isEmpty {
                sawSpeechSegments = true
            }

            for fixture in fixtures {
                let counts = WERScorer.score(
                    reference: AccuracyFixtures.reference(for: fixture),
                    segments: segments.filter { $0.channel == fixture.channel }
                )
                rows.append(Self.row(caseName, fixture.channel, counts))
            }
        }

        // Sanity: with speech fixtures present, a segment-free run means the
        // replay or model load is broken — the table would be vacuous.
        if AccuracyFixtures.caseNames().contains(where: { !AccuracyFixtures.isSilenceCase($0) }) {
            try #require(
                sawSpeechSegments,
                "no segments from any speech fixture: replay or model load is broken"
            )
        }

        // The printed table IS the recorded baseline. A copy lands in the
        // local fixtures folder — outside the repo — as a dated record;
        // failing to write it is non-fatal.
        let table = rows.joined(separator: "\n")
        print("[WER] baseline table\n\(table)")
        Self.recordResults(table)
    }

    // MARK: - Reporting

    private nonisolated static func row(
        _ caseName: String,
        _ channel: AudioChannel,
        _ counts: WERScorer.Counts
    ) -> String {
        let wer = counts.wer.isFinite ? String(format: "%.3f", counts.wer) : "inf"
        let sid = "\(counts.substitutions)/\(counts.insertions)/\(counts.deletions)"
        return "\(caseName) | \(channel.rawValue) | \(wer) (\(sid)) | \(counts.referenceWordCount)"
    }

    private nonisolated static func recordResults(_ table: String) {
        let day = Date().formatted(
            .iso8601.year().month().day().dateSeparator(.dash)
        )
        let url = AccuracyFixtures.root.appendingPathComponent("results-\(day).txt")
        try? table.write(to: url, atomically: true, encoding: .utf8)
    }
}

// MARK: - Plumbing tests

/// Harness plumbing that always runs (no model, no fixtures, no env var):
/// the discovery and gating rules the acceptance suite skips on. This is
/// what CI sees green while the fixture set stays local.
struct AccuracyFixtureSupportTests {

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("echo-accuracy-plumbing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeCase(_ name: String, files: [String], in root: URL) throws {
        let folder = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for file in files {
            try Data().write(to: folder.appendingPathComponent(file))
        }
    }

    @Test func rootLivesInTheHomeFolderOutsideTheRepo() {
        #expect(AccuracyFixtures.root.lastPathComponent == "EchoAccuracyFixtures")
        #expect(
            AccuracyFixtures.root.path.hasPrefix(
                FileManager.default.homeDirectoryForCurrentUser.path
            )
        )
        #expect(!AccuracyFixtures.root.path.contains("EchoTests"))
    }

    @Test func missingRootYieldsNoCases() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("echo-accuracy-missing-\(UUID().uuidString)")
        #expect(AccuracyFixtures.caseNames(under: root).isEmpty)
    }

    @Test func discoveryRequiresAudioAndReferenceTogether() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try makeCase("complete", files: ["mic.wav", "reference-mic.txt", "notes.txt"], in: root)
        try makeCase("audio-only", files: ["mic.wav"], in: root)
        try makeCase("reference-only", files: ["reference-system.txt"], in: root)
        try makeCase("empty", files: [], in: root)

        #expect(AccuracyFixtures.caseNames(under: root) == ["complete"])
        #expect(AccuracyFixtures.channels(for: "complete", under: root).map(\.channel) == [.microphone])
    }

    @Test func bothChannelsAreDiscoveredInStableOrder() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try makeCase(
            "pair",
            files: ["mic.wav", "reference-mic.txt", "system.wav", "reference-system.txt"],
            in: root
        )

        let channels = AccuracyFixtures.channels(for: "pair", under: root)
        #expect(channels.map(\.channel) == [.microphone, .system])
        #expect(channels.map(\.wav.lastPathComponent) == ["mic.wav", "system.wav"])
    }

    @Test func silenceCasesNeedNoReference() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try makeCase("quiet-room-silence", files: ["system.wav"], in: root)

        #expect(AccuracyFixtures.caseNames(under: root) == ["quiet-room-silence"])
        #expect(
            AccuracyFixtures.channels(for: "quiet-room-silence", under: root).map(\.channel)
                == [.system]
        )
        #expect(AccuracyFixtures.isSilenceCase("quiet-room-silence"))
        #expect(!AccuracyFixtures.isSilenceCase("quiet-room"))
    }

    @Test func missingReferenceReadsAsEmpty() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try makeCase("hum-silence", files: ["mic.wav"], in: root)

        let fixture = try #require(AccuracyFixtures.channels(for: "hum-silence", under: root).first)
        #expect(AccuracyFixtures.reference(for: fixture) == "")
    }

    @Test func casesSortByName() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try makeCase("b-case", files: ["mic.wav", "reference-mic.txt"], in: root)
        try makeCase("a-case", files: ["system.wav", "reference-system.txt"], in: root)

        #expect(AccuracyFixtures.caseNames(under: root) == ["a-case", "b-case"])
    }
}
