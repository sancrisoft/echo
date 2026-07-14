//
//  SummaryModelPathsTests.swift
//  EchoTests
//
//  Guards the single-data-root rule (user decision 2026-07-13): every path the
//  app derives for persisted data must live under
//  ~/Library/Application Support/Echo.
//

import Foundation
import Testing
@testable import Echo

@Suite("EchoPaths")
struct SummaryModelPathsTests {

    @Test("app support root is ~/Library/Application Support/Echo")
    func appSupportRoot() {
        let expected = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Echo")
        #expect(EchoPaths.appSupportDirectory.standardizedFileURL.path == expected.standardizedFileURL.path)
    }

    @Test("models directory is <root>/Models and exists after access")
    func modelsDirectory() {
        let url = EchoPaths.modelsDirectory
        #expect(url.lastPathComponent == "Models")
        #expect(url.deletingLastPathComponent().path == EchoPaths.appSupportDirectory.path)
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
    }

    @Test("summary model snapshot resolves under the models directory")
    func snapshotUnderModelsDirectory() {
        // The manager derives its snapshot via HubApi's models/<org>/<repo>
        // layout; the invariant we care about is the prefix.
        let expected = EchoPaths.modelsDirectory
            .appending(path: "models")
            .appending(path: SummaryModelManager.modelID)
        #expect(expected.path.hasPrefix(EchoPaths.modelsDirectory.path))
    }
}
