//
//  TemporaryDirectory.swift
//  EchoCoreTestSupport
//
//  A unique scratch folder for one test. Every store, writer or log under test
//  is rooted here, never at the real data root.
//

import Foundation

public struct TemporaryDirectory: Sendable {

    public let url: URL

    /// Creates `<tmp>/<prefix>-<uuid>/`.
    public init(prefix: String = "echo-test") throws {
        url = FileManager.default.temporaryDirectory
            .appending(path: "\(prefix)-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    /// A path inside the folder.
    public func path(_ component: String) -> URL {
        url.appending(path: component)
    }

    /// Deletes the folder and everything in it. Safe to call twice.
    public func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}
