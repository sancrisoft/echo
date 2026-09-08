import Foundation
import Testing

private let forbiddenModules: Set<String> = ["SwiftUI", "AppKit", "Cocoa", "EchoUI"]

/// Tests/EchoEngineTests/<this file> — three levels up is the package root.
private let packageRoot = URL(filePath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()

@Test func engineSourcesImportNoUserInterface() throws {
    let sources = packageRoot.appending(path: "Sources", directoryHint: .isDirectory)
    let swiftFiles = try swiftFiles(under: sources)

    #expect(
        swiftFiles.count >= 8,
        "the walk found only \(swiftFiles.count) Swift files under Sources/, so this scan proves nothing"
    )

    var violations: [String] = []
    for file in swiftFiles {
        let contents = try String(contentsOf: file, encoding: .utf8)
        for (offset, line) in contents.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            guard let module = importedModule(in: String(line)), forbiddenModules.contains(module) else { continue }
            let path = file.path().replacingOccurrences(of: packageRoot.path(), with: "")
            violations.append("\(path):\(offset + 1): import \(module)")
        }
    }

    #expect(
        violations.isEmpty,
        """
        The engine must not depend on the user interface. Move this code to Packages/EchoUI, \
        or express what it needs as an engine type the UI reads:
        \(violations.joined(separator: "\n"))
        """
    )
}

private func swiftFiles(under directory: URL) throws -> [URL] {
    guard let walk = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else {
        throw BoundaryScanFailure.unreadable(directory)
    }
    return walk
        .compactMap { $0 as? URL }
        .filter { $0.pathExtension == "swift" }
        .sorted { $0.path() < $1.path() }
}

private func importedModule(in line: String) -> String? {
    let tokens = line.split(whereSeparator: \.isWhitespace).map(String.init)
    guard tokens.first?.hasPrefix("//") == false,
          let keyword = tokens.firstIndex(of: "import"),
          let imported = tokens[safe: keyword + 1]
    else { return nil }
    // Submodule imports (`import AppKit.NSView`) are the same dependency.
    return imported.split(separator: ".").first.map(String.init)
}

private enum BoundaryScanFailure: Error {
    case unreadable(URL)
}

extension Array {
    fileprivate subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
