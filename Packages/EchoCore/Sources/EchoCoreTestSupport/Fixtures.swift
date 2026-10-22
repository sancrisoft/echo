//
//  Fixtures.swift
//  EchoCoreTestSupport
//
//  Where the real recordings and transcripts live, and how a test asks for
//  them. `Fixtures/` sits at the repository root and is gitignored: it holds
//  real meeting audio and text that never enter the repository. A test that
//  needs a fixture gates itself on `available(_:)` and skips with instructions
//  when it is missing — never a failure.
//

import Foundation

public enum Fixtures {

    /// `<repo>/Fixtures`. Resolved from this file's path, not from a bundle:
    /// fixtures are not test resources, and every scenario's `mic.wav` would
    /// flatten onto one bundle path.
    public static let root: URL = {
        // Packages/EchoCore/Sources/EchoCoreTestSupport/Fixtures.swift → repo root is five levels up.
        var url = URL(filePath: #filePath)
        for _ in 0..<5 { url = url.deletingLastPathComponent() }
        return url.appending(path: "Fixtures", directoryHint: .isDirectory)
    }()

    /// The repository root, for tests that read tracked files (workflows,
    /// notices, Package.swift files).
    public static let repositoryRoot: URL = root.deletingLastPathComponent()

    /// What to tell someone whose checkout has no fixtures.
    public static let instructions =
        "Fixtures are real recordings kept out of the repository. See Fixtures/README.md to record or copy them."

    /// A file inside a scenario folder, e.g. `Fixtures/bleed-only/mic.wav`.
    public static func url(scenario: String, file: String) -> URL {
        root.appending(path: scenario, directoryHint: .isDirectory)
            .appending(path: file, directoryHint: .notDirectory)
    }

    /// True when a dual-channel scenario is present (both `mic.wav` and
    /// `system.wav`).
    public static func available(_ scenario: String) -> Bool {
        let fileManager = FileManager.default
        return fileManager.fileExists(atPath: url(scenario: scenario, file: "mic.wav").path)
            && fileManager.fileExists(atPath: url(scenario: scenario, file: "system.wav").path)
    }

    /// `Fixtures/meeting-samples/<name>.txt` — a real transcript for the
    /// summarization acceptance suites.
    public static func meetingSampleURL(_ name: String) -> URL {
        url(scenario: "meeting-samples", file: "\(name).txt")
    }

    public static func meetingSampleAvailable(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: meetingSampleURL(name).path)
    }
}
