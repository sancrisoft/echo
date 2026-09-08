import Foundation
import Testing

/// The opt-in for suites that download a model or replay recorded audio. Off by
/// default: without it they skip with a note, they never fail.
public enum Acceptance {

    /// What the test process reads.
    public static let variable = "ECHO_ACCEPTANCE"

    /// What an `xcodebuild` invocation must set: it strips the `TEST_RUNNER_`
    /// prefix before handing the variable to the test process, so the two runners
    /// do not spell the same gate the same way. Both spellings are accepted here
    /// so neither invocation is wrong.
    public static let xcodebuildVariable = "TEST_RUNNER_\(variable)"

    public static var isEnabled: Bool { isEnabled(in: ProcessInfo.processInfo.environment) }

    static func isEnabled(in environment: [String: String]) -> Bool {
        environment[variable] == "1" || environment[xcodebuildVariable] == "1"
    }

    static let reason: Comment = """
    Acceptance suite — needs a model on disk or recorded fixtures, so it is off by \
    default. Run it with `\(variable)=1 swift test --package-path Packages/EchoEngine`, \
    or `\(xcodebuildVariable)=1 xcodebuild test ...` (xcodebuild strips the \
    TEST_RUNNER_ prefix, which is why the two spellings differ).
    """
}

extension Trait where Self == ConditionTrait {

    /// Marks a suite or test as acceptance-gated: skipped with a note explaining
    /// both invocations unless the environment opts in.
    public static var acceptance: Self {
        .enabled(if: Acceptance.isEnabled, Acceptance.reason)
    }
}
