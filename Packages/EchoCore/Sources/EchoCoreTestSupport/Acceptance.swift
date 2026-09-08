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
}

extension Trait where Self == ConditionTrait {

    /// Marks a suite or test as acceptance: it runs only when the gate is
    /// open, and otherwise skips with an explanation.
    public static var acceptance: Self {
        .enabled(if: Acceptance.isEnabled, Comment(rawValue: Acceptance.instructions))
    }
}
