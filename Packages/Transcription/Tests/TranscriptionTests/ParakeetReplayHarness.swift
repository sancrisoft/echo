//
//  ParakeetReplayHarness.swift
//  TranscriptionTests
//
//  The developer replay harness: re-runs the transcription pass over the
//  recorded fixture scenarios outside the app flow, records the resulting
//  segment set, and diffs it against a promoted baseline — so every change to
//  the pass is measured against real audio before it ships. A harness, not a
//  judge: it records and reports, it never asserts accuracy.
//
//  Fixtures are the repository's own scenario folders (see Fixtures/README.md),
//  not a meeting's kept audio: the PoC pointed ECHO_REPLAY_DIR at
//  `~/Library/Application Support/Echo/Meetings/<id>/debug-kept-*.m4a`, which
//  reads the app's real data folder and needs an environment variable — both
//  forbidden here. Every scenario with a complete `mic.wav` / `system.wav`
//  pair is replayed; a checkout with none skips with instructions.
//
//  Each run writes replay-<ISO timestamp>.json (the segment set) into a
//  temporary directory and records a compact per-channel report, the pass's
//  structured events, and — when the scenario folder holds a
//  `replay-baseline.json` — the segment delta against it, keyed on normalized
//  text plus times rounded to 0.1 s. Promoting a take to a baseline is a
//  deliberate copy the developer makes; the harness never writes into the
//  repository. Slow: loads the Parakeet model, which must ALREADY be on disk
//  under the app's Models folder — the harness never downloads anything.
//

import EchoCore
import EchoCoreTestSupport
import Foundation
import Synchronization
import Testing
import Transcription

enum ReplayHarness {

    /// A promoted take, read-only, inside the scenario folder. Absent means
    /// this run IS the baseline.
    static let baselineFileName = "replay-baseline.json"

    /// Every recorded scenario with a complete channel pair, sorted by name.
    static var availableScenarios: [String] {
        guard
            let entries = try? FileManager.default.contentsOfDirectory(
                at: Fixtures.root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        else { return [] }
        return
            entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map(\.lastPathComponent)
            .filter { Fixtures.available($0) }
            .sorted()
    }

    static let instructions: Comment = """
        Developer replay harness — needs at least one recorded scenario with both mic.wav and \
        system.wav under Fixtures/<scenario>/ (see Fixtures/README.md) and the Parakeet model \
        already downloaded under the app's Models folder; the harness never fetches it.
        """

    /// The channel files a scenario provides — the recorded pair.
    static func fixtureURL(_ channel: AudioChannel, in scenario: String) -> URL {
        Fixtures.url(scenario: scenario, file: channel == .microphone ? "mic.wav" : "system.wav")
    }
}

/// The pass's structured event sink, collected off whatever thread FluidAudio
/// and the channel loop call it from. A `Mutex` rather than an actor because
/// the sink is a synchronous `@Sendable` callback that cannot hop (ADR-002).
final class PassEventCollector: Sendable {

    private let events = Mutex<[PassEvent]>([])

    func record(_ event: PassEvent) {
        events.withLock { $0.append(event) }
    }

    var recorded: [PassEvent] {
        events.withLock { $0 }
    }
}

@Suite(.serialized, .acceptance)
struct ParakeetReplayHarness {

    @Test(.enabled(if: !ReplayHarness.availableScenarios.isEmpty, ReplayHarness.instructions))
    func replayTranscriptionPassOverKeptAudio() async throws {
        let takes = try TemporaryDirectory(prefix: "echo-replay")
        var report: [String] = []

        for scenario in ReplayHarness.availableScenarios {
            // Either channel may be absent (a mic-only or system-only take);
            // at least one must exist or there is nothing to replay.
            var retained: [AudioChannel: URL] = [:]
            for channel in [AudioChannel.microphone, .system] {
                let url = ReplayHarness.fixtureURL(channel, in: scenario)
                if FileManager.default.fileExists(atPath: url.path) {
                    retained[channel] = url
                }
            }
            try #require(!retained.isEmpty, ReplayHarness.instructions)

            // The model is a pure disk check against the app's Models folder.
            // If it isn't there the pass throws `modelUnavailable` and this
            // test fails honestly instead of quietly downloading half a
            // gigabyte.
            //
            // The event sink carries ids, times and scores and no text, so
            // the diagnostics can be recorded without a transcript leaving
            // the segment set the harness already holds.
            let collector = PassEventCollector()
            let segments = try await TranscriptionPass.run(
                retainedFiles: retained,
                model: TranscriptionTestSupport.model,
                onEvent: { collector.record($0) }
            )

            // Compact per-channel report, then the pass's own events.
            report.append("[replay] \(scenario)")
            for channel in [AudioChannel.microphone, .system] where retained[channel] != nil {
                report.append(
                    "[replay] "
                        + Self.channelReport(
                            channel,
                            segments: segments.filter { $0.channel == channel }
                        )
                )
            }
            report += collector.recorded.map { "[replay][event] " + Self.line($0) }

            // Record this take: replay-<ISO timestamp>.json (colons swapped
            // for dashes — name-sorted IS time-sorted), under the temporary
            // root, never next to the fixture.
            let stamp = Date().formatted(.iso8601).replacingOccurrences(of: ":", with: "-")
            let output = takes.path("\(scenario)-replay-\(stamp).json")
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(segments).write(to: output, options: .atomic)
            report.append("[replay] segment set written to \(output.path)")

            // The measurement (user story 13): the delta against the promoted
            // baseline — what a pipeline variant added and removed.
            let baselineURL = Fixtures.url(
                scenario: scenario,
                file: ReplayHarness.baselineFileName
            )
            if let data = try? Data(contentsOf: baselineURL) {
                let baseline = try JSONDecoder().decode([TranscriptSegment].self, from: data)
                report += Self.delta(
                    from: baseline,
                    baselineName: baselineURL.lastPathComponent,
                    to: segments
                )
            } else {
                report.append(
                    "[replay] no \(ReplayHarness.baselineFileName) in \(scenario) — this take is "
                        + "the baseline; copy it into the scenario folder to diff against it"
                )
            }
        }

        Attachment.record(report.joined(separator: "\n"), named: "replay-report.txt")
    }

    // MARK: - Reporting

    private static func channelReport(
        _ channel: AudioChannel,
        segments: [TranscriptSegment]
    ) -> String {
        guard !segments.isEmpty else { return "\(channel.rawValue): 0 segments" }
        let firstStart = segments.map(\.start).min() ?? 0
        let lastEnd = segments.map(\.end).max() ?? 0
        let speechSeconds = segments.reduce(0.0) { $0 + max(0, $1.end - $1.start) }
        return String(
            format: "%@: %d segments, %.1fs – %.1fs, %.1fs speech",
            channel.rawValue, segments.count, firstStart, lastEnd, speechSeconds
        )
    }

    /// One pass event as a line: ids, times and scores, exactly what the sink
    /// carries. The PoC's sink was a `String` with the words already in it.
    private static func line(_ event: PassEvent) -> String {
        switch event {
        case .channelDecoded(let decode):
            return String(
                format: "decoded %@: %.1fs audio, %d tokens, %d segments, %.2fs decode",
                decode.channel.rawValue,
                decode.audioSeconds,
                decode.tokenCount,
                decode.segmentCount,
                Self.seconds(decode.decodeDuration)
            )
        case .segmentProduced(let id, let channel, let start, let end):
            return String(
                format: "produced %@ %@ %.2f–%.2f",
                channel.rawValue, id.uuidString, start, end
            )
        case .segmentSuppressed(let suppression):
            let ratio = suppression.rmsRatio.map { String(format: "%.3f", $0) } ?? "none"
            return String(
                format:
                    "suppressed %@ %@ %.2f–%.2f tier=%@ containment=%.3f rms=%@ ownVoice=%.2fs "
                    + "match=%@ %.2f–%.2f",
                suppression.channel.rawValue,
                suppression.segmentID.uuidString,
                suppression.start,
                suppression.end,
                suppression.tier.rawValue,
                suppression.containment,
                ratio,
                suppression.ownVoiceSeconds,
                suppression.matchID.uuidString,
                suppression.matchStart,
                suppression.matchEnd
            )
        }
    }

    private static func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }

    /// A segment's diff identity: channel + normalized text + times rounded
    /// to 0.1 s — wording and timing changes register, segment IDs (fresh
    /// every run) don't.
    private static func diffKey(_ segment: TranscriptSegment) -> String {
        let normalized = segment.text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return String(
            format: "%@ | %@ | %.1f–%.1f",
            segment.channel.rawValue, normalized, segment.start, segment.end
        )
    }

    /// Multiset delta between two takes, as added/removed rows.
    private static func delta(
        from baseline: [TranscriptSegment],
        baselineName: String,
        to current: [TranscriptSegment]
    ) -> [String] {
        var counts: [String: Int] = [:]
        for segment in baseline { counts[diffKey(segment), default: 0] -= 1 }
        for segment in current { counts[diffKey(segment), default: 0] += 1 }
        let added = counts.filter { $0.value > 0 }
        let removed = counts.filter { $0.value < 0 }

        var lines = [
            "[replay] delta vs \(baselineName): +\(added.values.reduce(0, +)) segments, "
                + "-\(removed.values.map { -$0 }.reduce(0, +)) segments"
        ]
        for (key, count) in added.sorted(by: { $0.key < $1.key }) {
            lines.append("[replay]   + \(key)" + (count > 1 ? " (×\(count))" : ""))
        }
        for (key, count) in removed.sorted(by: { $0.key < $1.key }) {
            lines.append("[replay]   - \(key)" + (count < -1 ? " (×\(-count))" : ""))
        }
        if added.isEmpty && removed.isEmpty {
            lines.append("[replay]   identical segment sets")
        }
        return lines
    }
}
