import Foundation

/// Recorded audio and transcripts the fixture suites replay. Local-only: real
/// meeting material, gitignored, never shipped.
public enum Fixtures {

    /// Resolved from this source file, never from a bundle. `Fixtures/` sits at the
    /// repository root, outside every target: `EchoTests/` is a synchronized group
    /// that flattens into bundle Resources, where two scenarios' `mic.wav` collide.
    public static let root: URL = URL(filePath: #filePath)
        .deletingLastPathComponent()   // EchoTestSupport/
        .deletingLastPathComponent()   // Sources/
        .deletingLastPathComponent()   // EchoEngine/
        .deletingLastPathComponent()   // Packages/
        .deletingLastPathComponent()   // repository root
        .appending(path: "Fixtures", directoryHint: .isDirectory)

    public static func folder(_ scenario: String) -> URL {
        root.appending(path: scenario, directoryHint: .isDirectory)
    }

    public static func file(_ scenario: String, _ name: String) -> URL {
        folder(scenario).appending(path: name, directoryHint: .notDirectory)
    }

    /// A scenario is available only as a complete two-channel pair.
    public static func available(_ scenario: String) -> Bool {
        exists(file(scenario, "mic.wav")) && exists(file(scenario, "system.wav"))
    }

    /// The two channel URLs, or a failure that says the fixtures are local-only.
    public static func require(_ scenario: String) throws -> (mic: URL, system: URL) {
        guard exists(root) else { throw FixtureUnavailable.rootMissing(root) }
        let mic = file(scenario, "mic.wav")
        let system = file(scenario, "system.wav")
        for url in [mic, system] where !exists(url) {
            throw FixtureUnavailable.channelMissing(scenario: scenario, url: url)
        }
        return (mic: mic, system: system)
    }

    private static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
    }
}

public enum FixtureUnavailable: Error, CustomStringConvertible {
    case rootMissing(URL)
    case channelMissing(scenario: String, url: URL)

    public var description: String {
        switch self {
        case .rootMissing(let url):
            """
            No fixtures on this machine. \(Self.localOnly)
            Expected the set at \(url.path(percentEncoded: false)).
            """
        case .channelMissing(let scenario, let url):
            """
            Fixture scenario "\(scenario)" is not recorded on this machine. \(Self.localOnly)
            Expected \(url.path(percentEncoded: false)).
            """
        }
    }

    private static let localOnly = """
    Fixtures are real recorded audio: local-only, gitignored, never in the repository — \
    record them per Fixtures/README.md, or gate the suite so it skips instead.
    """
}
