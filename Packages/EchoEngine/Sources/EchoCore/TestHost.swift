import Foundation

/// Whether this process is a test runner's host app rather than a real user launch.
/// Launch side effects must be skipped wholesale when it is — see AGENTS.md.
public enum TestHost {

    /// Computed once: several call sites read it and the answer cannot change mid-process.
    public static let isActive: Bool = detect(
        environment: ProcessInfo.processInfo.environment,
        isXCTestLinked: NSClassFromString("XCTestCase") != nil
    )

    /// Two signals, because a false negative corrupts the user's real store while a
    /// false positive only skips warm-up: XCTest is linked into the host for both
    /// XCTest and Swift Testing bundles, and Xcode sets `XCTest*` keys on it.
    static func detect(environment: [String: String], isXCTestLinked: Bool) -> Bool {
        if isXCTestLinked { return true }
        return environment.keys.contains { $0.hasPrefix("XCTest") }
    }
}
