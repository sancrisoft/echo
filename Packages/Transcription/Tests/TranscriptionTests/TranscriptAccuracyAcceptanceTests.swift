//
//  TranscriptAccuracyAcceptanceTests.swift
//  TranscriptionTests
//
//  The WER harness — the executable form of the "measured baseline" Success
//  Criterion. Each local fixture case is transcribed by the production pass
//  and scored per channel against a local human-corrected reference, and the
//  WER table is recorded (the recorded table IS the baseline).
//
//  There is one engine now, so there is no live-vs-final comparison left to
//  make: the never-worse assertion died with the live pipeline it was
//  relative to. What remains asserted is no-text-on-silence, plus the
//  vacuity guard. Absolute WER targets are the user's to set against a
//  recorded baseline — this harness measures, it does not judge.
//
//  Fixture convention (fixtures are real recordings and are NEVER committed
//  — see Fixtures/README.md; the PoC kept them in the home folder instead):
//
//      Fixtures/<case-name>/
//          mic.wav               You-channel audio (16 kHz mono Float32
//                                preferred; anything AVAudioFile reads works)
//          system.wav            Team-channel audio (same formats)
//          reference-mic.txt     human-corrected reference for mic.wav
//          reference-system.txt  human-corrected reference for system.wav
//          info.json             the scenario metadata, ignored here
//
//  Each channel is optional, but a channel's wav and reference travel
//  together. A case whose name ends in "-silence" holds non-speech audio:
//  its references may be absent (the implied reference is empty) and the
//  pass must produce NO segments for it.
//
//  Slow: loads the Parakeet model (which must already be on disk), so it is
//  gated on ECHO_ACCEPTANCE=1 in addition to the local fixtures — see
//  `.acceptance` for the invocation.
//

import EchoCore
import EchoCoreTestSupport
import Foundation
import Testing
import Transcription

enum AccuracyFixtures {

    /// Accuracy cases are scenario folders under the repository's gitignored
    /// `Fixtures/` root — the one home every real recording shares
    /// (`Fixtures.root` in `EchoCoreTestSupport`).
    static var root: URL { Fixtures.root }

    /// Skip reason shown while no local fixture case exists.
    static let instructions: Comment = """
        No accuracy fixtures found. Place cases at Fixtures/<case-name>/ containing mic.wav and/or \
        system.wav (16 kHz mono Float32 preferred; anything AVAudioFile reads works) plus \
        reference-mic.txt / reference-system.txt holding the human-corrected reference transcript \
        for each audio file present. Name non-speech cases with a -silence suffix — their \
        references may be omitted. See Fixtures/README.md; fixtures are real recordings and are \
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

    /// One case file's location. `root: nil` is the real fixtures folder and
    /// goes through `Fixtures.url(scenario:file:)`, the single accessor that
    /// knows the layout; a non-nil root is the temp layout the always-running
    /// plumbing tests below build, and mirrors it.
    private static func url(_ file: String, in caseName: String, under root: URL?) -> URL {
        guard let root else { return Fixtures.url(scenario: caseName, file: file) }
        return root.appending(path: caseName, directoryHint: .isDirectory)
            .appending(path: file, directoryHint: .notDirectory)
    }

    /// Case directories contributing at least one scoreable channel, sorted
    /// by name. `root` is injectable so the always-running plumbing tests
    /// below can drive discovery against temp layouts.
    static func caseNames(under root: URL? = nil) -> [String] {
        let base = root ?? Fixtures.root
        guard
            let entries = try? FileManager.default.contentsOfDirectory(
                at: base,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        else { return [] }
        return
            entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map(\.lastPathComponent)
            .filter { !channels(for: $0, under: root).isEmpty }
            .sorted()
    }

    /// The channels a case provides: the wav must exist, and so must its
    /// reference — except for -silence cases, where the reference is
    /// implicitly empty.
    static func channels(for caseName: String, under root: URL? = nil) -> [ChannelFixture] {
        let layout: [(AudioChannel, String, String)] = [
            (.microphone, "mic.wav", "reference-mic.txt"),
            (.system, "system.wav", "reference-system.txt"),
        ]
        return layout.compactMap { channel, wavName, referenceName in
            let wav = url(wavName, in: caseName, under: root)
            let reference = url(referenceName, in: caseName, under: root)
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

@Suite(.serialized, .acceptance)
struct TranscriptAccuracyAcceptanceTests {

    @Test(.enabled(if: !AccuracyFixtures.caseNames().isEmpty, AccuracyFixtures.instructions))
    func transcriptionWERBaseline() async throws {
        var rows = ["case | channel | WER (S/I/D) | ref words"]
        var sawSpeechSegments = false

        for caseName in AccuracyFixtures.caseNames() {
            let fixtures = AccuracyFixtures.channels(for: caseName)
            var audio: [AudioChannel: [Float]] = [:]
            for fixture in fixtures {
                audio[fixture.channel] = try TranscriptionTestSupport.loadWAV(at: fixture.wav)
            }

            let segments = try await TranscriptionTestSupport.transcribe(audio)

            if AccuracyFixtures.isSilenceCase(caseName) {
                // No text on silence — fixture-verified, never assumed. Ids,
                // spans and counts only: a failure message never carries
                // transcript text.
                #expect(
                    segments.isEmpty,
                    Comment(
                        rawValue: """
                            the pass invented text on silence (\(caseName)): \
                            \(segments.count) segments — \(Self.spans(segments))
                            """
                    )
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

        // The recorded table IS the baseline. It is attached to the run and
        // copied under a temporary root as a dated file; failing to write the
        // copy is non-fatal, and nothing is written into the repository, the
        // home folder or the app's data folder.
        let table = rows.joined(separator: "\n")
        let recorded = Self.recordResults(table)
        Attachment.record(
            recorded.map { "\(table)\n\nrecorded at \($0.path)" } ?? table,
            named: "wer-baseline.txt"
        )
    }

    // MARK: - Reporting

    private static func row(
        _ caseName: String,
        _ channel: AudioChannel,
        _ counts: WERScorer.Counts
    ) -> String {
        let wer = counts.wer.isFinite ? String(format: "%.3f", counts.wer) : "inf"
        let sid = "\(counts.substitutions)/\(counts.insertions)/\(counts.deletions)"
        return "\(caseName) | \(channel.rawValue) | \(wer) (\(sid)) | \(counts.referenceWordCount)"
    }

    /// Segment identity for a failure message: id, channel and span. Never the
    /// words — the assertion is about rows existing at all, and transcript
    /// text does not go into a message, a log or an attachment.
    private static func spans(_ segments: [TranscriptSegment]) -> String {
        segments
            .map {
                String(
                    format: "%@ %@ %.2f–%.2f",
                    $0.channel.rawValue, $0.id.uuidString, $0.start, $0.end
                )
            }
            .joined(separator: ", ")
    }

    /// The dated copy, under a temporary root. Returns nil when it could not
    /// be written — recording the baseline is a convenience, never the test.
    private static func recordResults(_ table: String) -> URL? {
        let day = Date().formatted(
            .iso8601.year().month().day().dateSeparator(.dash)
        )
        guard let directory = try? TemporaryDirectory(prefix: "echo-wer-baseline") else { return nil }
        let url = directory.path("results-\(day).txt")
        do {
            try table.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            return nil
        }
        return url
    }
}

// MARK: - Plumbing tests

/// Harness plumbing that always runs (no model, no fixtures, no env var):
/// the discovery and gating rules the acceptance suite skips on. This is
/// what CI sees green while the fixture set stays local.
struct AccuracyFixtureSupportTests {

    private func makeCase(_ name: String, files: [String], in root: URL) throws {
        let folder = root.appending(path: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for file in files {
            try Data().write(to: folder.appending(path: file, directoryHint: .notDirectory))
        }
    }

    /// The PoC kept accuracy cases in the home folder; v2 has one home for
    /// every real recording, and it is gitignored rather than outside the
    /// checkout. What still has to hold is that it is neither the test
    /// target's folder nor anywhere the repository tracks.
    @Test func rootIsTheGitignoredFixturesFolderOutsideTheTestTarget() {
        #expect(AccuracyFixtures.root.lastPathComponent == "Fixtures")
        #expect(AccuracyFixtures.root.path.hasPrefix(Fixtures.repositoryRoot.path))
        #expect(!AccuracyFixtures.root.path.contains("TranscriptionTests"))
    }

    @Test func missingRootYieldsNoCases() throws {
        let temporary = try TemporaryDirectory(prefix: "echo-accuracy-missing")
        defer { temporary.remove() }

        #expect(AccuracyFixtures.caseNames(under: temporary.path("no-such-root")).isEmpty)
    }

    @Test func discoveryRequiresAudioAndReferenceTogether() throws {
        let temporary = try TemporaryDirectory(prefix: "echo-accuracy-plumbing")
        defer { temporary.remove() }
        let root = temporary.url
        try makeCase("complete", files: ["mic.wav", "reference-mic.txt", "notes.txt"], in: root)
        try makeCase("audio-only", files: ["mic.wav"], in: root)
        try makeCase("reference-only", files: ["reference-system.txt"], in: root)
        try makeCase("empty", files: [], in: root)

        #expect(AccuracyFixtures.caseNames(under: root) == ["complete"])
        #expect(AccuracyFixtures.channels(for: "complete", under: root).map(\.channel) == [.microphone])
    }

    @Test func bothChannelsAreDiscoveredInStableOrder() throws {
        let temporary = try TemporaryDirectory(prefix: "echo-accuracy-plumbing")
        defer { temporary.remove() }
        try makeCase(
            "pair",
            files: ["mic.wav", "reference-mic.txt", "system.wav", "reference-system.txt"],
            in: temporary.url
        )

        let channels = AccuracyFixtures.channels(for: "pair", under: temporary.url)
        #expect(channels.map(\.channel) == [.microphone, .system])
        #expect(channels.map(\.wav.lastPathComponent) == ["mic.wav", "system.wav"])
    }

    @Test func silenceCasesNeedNoReference() throws {
        let temporary = try TemporaryDirectory(prefix: "echo-accuracy-plumbing")
        defer { temporary.remove() }
        try makeCase("quiet-room-silence", files: ["system.wav"], in: temporary.url)

        #expect(AccuracyFixtures.caseNames(under: temporary.url) == ["quiet-room-silence"])
        #expect(
            AccuracyFixtures.channels(for: "quiet-room-silence", under: temporary.url).map(\.channel)
                == [.system]
        )
        #expect(AccuracyFixtures.isSilenceCase("quiet-room-silence"))
        #expect(!AccuracyFixtures.isSilenceCase("quiet-room"))
    }

    @Test func missingReferenceReadsAsEmpty() throws {
        let temporary = try TemporaryDirectory(prefix: "echo-accuracy-plumbing")
        defer { temporary.remove() }
        try makeCase("hum-silence", files: ["mic.wav"], in: temporary.url)

        let fixture = try #require(
            AccuracyFixtures.channels(for: "hum-silence", under: temporary.url).first
        )
        #expect(AccuracyFixtures.reference(for: fixture) == "")
    }

    @Test func casesSortByName() throws {
        let temporary = try TemporaryDirectory(prefix: "echo-accuracy-plumbing")
        defer { temporary.remove() }
        try makeCase("b-case", files: ["mic.wav", "reference-mic.txt"], in: temporary.url)
        try makeCase("a-case", files: ["system.wav", "reference-system.txt"], in: temporary.url)

        #expect(AccuracyFixtures.caseNames(under: temporary.url) == ["a-case", "b-case"])
    }
}
