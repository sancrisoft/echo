//
//  ParakeetReplayHarness.swift
//  EchoTests
//
//  The developer replay harness: re-runs the transcription pass over a
//  meeting's kept fixture audio outside the app flow, records the resulting
//  segment set, and diffs it against the previous replay — so every change to
//  the pass is measured against real audio before it ships. A harness, not a
//  judge: it prints and records, it never asserts accuracy.
//
//  Producing a fixture (user story 12): run a DEBUG build of the app with
//  ECHO_KEEP_RETAINED_AUDIO=1 in its environment; a meeting whose final pass
//  succeeds then keeps its audio as
//
//      ~/Library/Application Support/Echo/Meetings/<meeting-id>/
//          debug-kept-mic.m4a
//          debug-kept-system.m4a
//
//  Replaying it: point ECHO_REPLAY_DIR at a directory holding those kept
//  files (either channel may be absent — the meeting's own folder works
//  directly). Through xcodebuild the variable must be spelled with the
//  TEST_RUNNER_ prefix, which xcodebuild strips before handing it to the
//  test process:
//
//      TEST_RUNNER_ECHO_REPLAY_DIR="$HOME/Library/Application Support/Echo/Meetings/<id>" \
//      xcodebuild test -project Echo.xcodeproj -scheme Echo \
//          -destination 'platform=macOS' -parallel-testing-enabled NO \
//          -only-testing:EchoTests/ParakeetReplayHarness
//
//  Each run writes replay-<ISO timestamp>.json (the segment set) next to the
//  audio and prints a compact per-channel report; when previous replay-*.json
//  files exist, the run also prints the segment delta against the most recent
//  one (keyed on normalized text + times rounded to 0.1 s). Slow: loads the
//  Parakeet model, which must ALREADY be on disk under the app's Models
//  folder — the harness never downloads anything.
//

import Foundation
import Testing
@testable import Echo

nonisolated enum ReplayHarness {

    /// The directory holding the kept fixture audio — the gate. Unset means
    /// the suite skips with the pointer below.
    static var directory: URL? {
        ProcessInfo.processInfo.environment["ECHO_REPLAY_DIR"].map {
            URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true)
        }
    }

    static var isEnabled: Bool { directory != nil }

    static let gate: Comment = """
    Developer replay harness — run on demand against a meeting's kept fixture \
    audio: TEST_RUNNER_ECHO_REPLAY_DIR=<dir> xcodebuild test -project \
    Echo.xcodeproj -scheme Echo -destination 'platform=macOS' \
    -parallel-testing-enabled NO \
    -only-testing:EchoTests/ParakeetReplayHarness. Kept fixtures live at \
    ~/Library/Application Support/Echo/Meetings/<id>/debug-kept-*.m4a — \
    produce them by running a DEBUG app build with ECHO_KEEP_RETAINED_AUDIO=1 \
    (see the header of ParakeetReplayHarness.swift)
    """

    /// The kept-fixture names the DEBUG keep flag writes. Sourced from the
    /// store's single home of the names when it is compiled in.
    static func keptFileName(for channel: AudioChannel) -> String {
        #if DEBUG
        MeetingStore.debugKeptAudioFileName(for: channel)
        #else
        channel == .microphone ? "debug-kept-mic.m4a" : "debug-kept-system.m4a"
        #endif
    }
}

@Suite(.serialized, .enabled(if: ReplayHarness.isEnabled, ReplayHarness.gate))
struct ParakeetReplayHarness {

    @Test func replayTranscriptionPassOverKeptAudio() async throws {
        let directory = try #require(ReplayHarness.directory)

        // Either channel may be absent (a mic-only or system-only meeting);
        // at least one must exist or there is nothing to replay.
        var retained: [AudioChannel: URL] = [:]
        for channel in [AudioChannel.microphone, .system] {
            let url = directory.appending(
                path: ReplayHarness.keptFileName(for: channel),
                directoryHint: .notDirectory
            )
            if FileManager.default.fileExists(atPath: url.path) {
                retained[channel] = url
            }
        }
        try #require(
            !retained.isEmpty,
            """
            No debug-kept-mic.m4a / debug-kept-system.m4a under \
            \(directory.path) — produce them with a DEBUG app run under \
            ECHO_KEEP_RETAINED_AUDIO=1 (see this file's header)
            """
        )

        // The previous takes, snapshotted BEFORE this run writes its own.
        let previousReplays = Self.replayFiles(in: directory)

        // The model comes from the app's own manager — a pure disk check
        // against ~/Library/Application Support/Echo/Models. If it isn't
        // there the pass throws `modelUnavailable` and this test fails
        // honestly instead of quietly downloading half a gigabyte.
        //
        // Diagnostic mode: the harness is a local dev tool, so printing
        // transcript text to stdout is fine HERE — per channel the decode
        // summary, then every produced segment with its times.
        let segments = try await ParakeetPass.run(
            retainedFiles: retained,
            models: ManagedParakeetModelProvider(manager: ParakeetModelManager()),
            diagnostics: { line in print("[replay][diag] \(line)") }
        )

        // Compact per-channel report.
        print("[replay] \(directory.path)")
        for channel in [AudioChannel.microphone, .system] where retained[channel] != nil {
            print("[replay] " + Self.channelReport(
                channel,
                segments: segments.filter { $0.channel == channel }
            ))
        }

        // Record this take next to the audio: replay-<ISO timestamp>.json
        // (colons swapped for dashes — name-sorted IS time-sorted).
        let stamp = Date().formatted(.iso8601).replacingOccurrences(of: ":", with: "-")
        let output = directory.appending(path: "replay-\(stamp).json", directoryHint: .notDirectory)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(segments).write(to: output, options: .atomic)
        print("[replay] segment set written to \(output.lastPathComponent)")

        // The measurement (user story 13): the delta against the most recent
        // previous take — what a pipeline variant added and removed.
        if let previous = previousReplays.last {
            let baseline = try JSONDecoder().decode(
                [TranscriptSegment].self,
                from: Data(contentsOf: previous)
            )
            Self.printDelta(from: baseline, baselineName: previous.lastPathComponent, to: segments)
        } else {
            print("[replay] no previous replay-*.json — this take is the baseline")
        }
    }

    // MARK: - Reporting

    private nonisolated static func channelReport(
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

    /// Previous takes in this directory, name-sorted (= time-sorted, the
    /// stamp is lexicographic): the last element is the most recent.
    private nonisolated static func replayFiles(in directory: URL) -> [URL] {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        return entries
            .filter {
                $0.lastPathComponent.hasPrefix("replay-")
                    && $0.pathExtension == "json"
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// A segment's diff identity: channel + normalized text + times rounded
    /// to 0.1 s — wording and timing changes register, segment IDs (fresh
    /// every run) don't.
    private nonisolated static func diffKey(_ segment: TranscriptSegment) -> String {
        let normalized = segment.text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return String(
            format: "%@ | %@ | %.1f–%.1f",
            segment.channel.rawValue, normalized, segment.start, segment.end
        )
    }

    /// Multiset delta between two takes, printed as added/removed rows.
    private nonisolated static func printDelta(
        from baseline: [TranscriptSegment],
        baselineName: String,
        to current: [TranscriptSegment]
    ) {
        var counts: [String: Int] = [:]
        for segment in baseline { counts[diffKey(segment), default: 0] -= 1 }
        for segment in current { counts[diffKey(segment), default: 0] += 1 }
        let added = counts.filter { $0.value > 0 }
        let removed = counts.filter { $0.value < 0 }

        print("[replay] delta vs \(baselineName): +\(added.values.reduce(0, +)) segments, -\(removed.values.map { -$0 }.reduce(0, +)) segments")
        for (key, count) in added.sorted(by: { $0.key < $1.key }) {
            print("[replay]   + \(key)" + (count > 1 ? " (×\(count))" : ""))
        }
        for (key, count) in removed.sorted(by: { $0.key < $1.key }) {
            print("[replay]   - \(key)" + (count < -1 ? " (×\(-count))" : ""))
        }
        if added.isEmpty && removed.isEmpty {
            print("[replay]   identical segment sets")
        }
    }
}
