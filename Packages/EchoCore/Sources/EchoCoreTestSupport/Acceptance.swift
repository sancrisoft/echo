//
//  Acceptance.swift
//  EchoCoreTestSupport
//
//  The gate for suites that load a real model or replay real audio. Off by
//  default so `swift test` and CI need neither; a developer opens it with
//  `ECHO_ACCEPTANCE=1` (`swift test`) or `TEST_RUNNER_ECHO_ACCEPTANCE=1`
//  (`xcodebuild test` strips the prefix before the process sees it).
//

import Foundation
import Testing

public enum Acceptance {

    /// The environment variable, as the test process sees it.
    public static let variable = "ECHO_ACCEPTANCE"

    /// True when the gate is open.
    public static var isEnabled: Bool {
        ProcessInfo.processInfo.environment[variable] == "1"
    }

    /// What a skipped suite says.
    public static let instructions =
        "Acceptance suites need a downloaded model and local fixtures. Run with ECHO_ACCEPTANCE=1 to include them."

    // MARK: - The echo-cancellation measurement spike

    /// The variable naming a directory of `mic.wav` / `system.wav` for the
    /// offline echo-cancellation measurement.
    public static let aecSpikeVariable = "ECHO_AEC_SPIKE"

    /// The directory the spike measures, or nil when it is not set.
    ///
    /// This is a measurement harness, not a test: it replays one real pair
    /// through the canceller and prints what it removed, so the numbers that
    /// justify the AEC constants can be taken again on new hardware. It never
    /// runs in CI and it asserts nothing about a threshold. The gate lives
    /// here rather than in the suite because this file is the only test-side
    /// place allowed to read the environment.
    public static var aecSpikeDirectory: URL? {
        guard let raw = ProcessInfo.processInfo.environment[aecSpikeVariable],
            !raw.isEmpty
        else { return nil }
        // Tilde-expanded so a literal "~/pair" works, not only the form the
        // shell already expanded.
        return URL(filePath: (raw as NSString).expandingTildeInPath, directoryHint: .isDirectory)
    }

    /// What a skipped spike says.
    public static let aecSpikeInstructions =
        "Set ECHO_AEC_SPIKE=<dir> (a folder holding mic.wav and system.wav) to run the echo-cancellation measurement."
}

extension Trait where Self == ConditionTrait {

    /// Marks a suite or test as acceptance: it runs only when the gate is
    /// open, and otherwise skips with an explanation.
    public static var acceptance: Self {
        .enabled(if: Acceptance.isEnabled, Comment(rawValue: Acceptance.instructions))
    }

    /// Marks a suite as the echo-cancellation measurement spike: it runs only
    /// when a pair of recordings is named, and otherwise skips with an
    /// explanation.
    public static var aecSpike: Self {
        .enabled(
            if: Acceptance.aecSpikeDirectory != nil,
            Comment(rawValue: Acceptance.aecSpikeInstructions)
        )
    }
}
