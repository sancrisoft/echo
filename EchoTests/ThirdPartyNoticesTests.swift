//
//  ThirdPartyNoticesTests.swift
//  EchoTests
//
//  Every release zip carries LICENSE, NOTICE and THIRD_PARTY_NOTICES.md, and
//  the last one has to name every Swift package compiled into Echo.app: the
//  MIT and BSD licenses among them require their notices to travel with the
//  binary. Package.resolved is the ground truth for what those packages are,
//  so this is what keeps a new dependency from shipping unattributed.
//

import Foundation
import Testing

@Suite("Third-party notices")
struct ThirdPartyNoticesTests {

    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // EchoTests/
        .deletingLastPathComponent()   // repository root

    private static let noticesName = "THIRD_PARTY_NOTICES.md"

    private struct PackageResolved: Decodable {
        struct Pin: Decodable {
            let identity: String
            let location: String
        }
        let pins: [Pin]
    }

    private func text(_ path: String) throws -> String {
        try String(contentsOf: Self.root.appending(path: path), encoding: .utf8)
    }

    @Test func theThreeFilesTheReleaseShipsExist() throws {
        for name in ["LICENSE", "NOTICE", Self.noticesName] {
            let contents = try text(name)
            #expect(!contents.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "\(name) is empty")
        }
        let license = try text("LICENSE")
        #expect(license.contains("Apache License"))
        #expect(license.contains("Version 2.0, January 2004"))
        let notice = try text("NOTICE")
        #expect(notice.contains(Self.noticesName), "NOTICE should point the reader at the full list")
    }

    /// Each pinned package gets its own `### <identity>` heading (the repo
    /// name, so case-insensitive against SwiftPM's lowercased identity) and
    /// its pinned URL as a Markdown autolink — the angle brackets make
    /// `mlx-swift` and `mlx-swift-lm` distinguishable.
    @Test func everyPinnedPackageIsNamedInTheNotices() throws {
        let resolvedPath = "Echo.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
        let resolved = try JSONDecoder().decode(
            PackageResolved.self,
            from: Data(contentsOf: Self.root.appending(path: resolvedPath))
        )
        #expect(!resolved.pins.isEmpty, "Package.resolved lists no packages")

        let notices = try text(Self.noticesName)
        let headings = Set(
            notices.split(separator: "\n")
                .filter { $0.hasPrefix("### ") }
                .map { $0.dropFirst(4).trimmingCharacters(in: .whitespaces).lowercased() }
        )
        for pin in resolved.pins {
            #expect(headings.contains(pin.identity.lowercased()), "\(pin.identity) has no `### \(pin.identity)` entry in \(Self.noticesName)")
            var url = pin.location
            if url.hasSuffix(".git") { url.removeLast(4) }
            #expect(notices.contains("<\(url)>"), "\(pin.identity)'s entry does not link <\(url)>")
        }
    }

    @Test func theVendoredLicensesAreReferenced() throws {
        let notices = try text(Self.noticesName)
        for path in [
            "Vendor/webrtc-apm/licenses/LICENSE.webrtc-audio-processing",
            "Vendor/webrtc-apm/licenses/LICENSE.abseil-cpp",
        ] {
            #expect(FileManager.default.fileExists(atPath: Self.root.appending(path: path).path), "\(path) is missing")
            #expect(notices.contains(path), "\(Self.noticesName) does not reference \(path)")
        }
    }

    @Test func theReleaseWorkflowShipsTheNotices() throws {
        let workflow = try text(".github/workflows/release.yml")
        #expect(workflow.contains("cp LICENSE NOTICE \(Self.noticesName)"))
    }
}
