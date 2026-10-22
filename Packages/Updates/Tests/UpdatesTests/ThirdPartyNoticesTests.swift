//
//  ThirdPartyNoticesTests.swift
//  UpdatesTests
//
//  Every release zip carries LICENSE, NOTICE and THIRD_PARTY_NOTICES.md, and
//  the last one has to name every Swift package compiled into Echo.app: the
//  MIT and BSD licenses among them require their notices to travel with the
//  binary. Package.resolved is the ground truth for what those packages are,
//  so this is what keeps a new dependency from shipping unattributed — and,
//  the other way round, a dropped one from staying listed.
//
//  Ported from the PoC's test target. It lives beside the release feed's
//  tests, which read the README and the release workflow the same way: what
//  a release ships is checked where the release is.
//

import Foundation
import Testing

@Suite("Third-party notices")
struct ThirdPartyNoticesTests {

    private static let root = URL(filePath: #filePath)
        .deletingLastPathComponent()  // Tests/UpdatesTests/
        .deletingLastPathComponent()  // Tests/
        .deletingLastPathComponent()  // Packages/Updates/
        .deletingLastPathComponent()  // Packages/
        .deletingLastPathComponent()  // repository root

    private static let noticesName = "THIRD_PARTY_NOTICES.md"

    /// The app's own resolution: every package compiled into Echo.app.
    private static let resolvedPath = "Echo.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"

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

    private func pins() throws -> [PackageResolved.Pin] {
        try JSONDecoder().decode(
            PackageResolved.self, from: Data(contentsOf: Self.root.appending(path: Self.resolvedPath))
        ).pins
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
        let pins = try pins()
        #expect(!pins.isEmpty, "Package.resolved lists no packages")

        let notices = try text(Self.noticesName)
        let headings = Set(
            notices.split(separator: "\n")
                .filter { $0.hasPrefix("### ") }
                .map { $0.dropFirst(4).trimmingCharacters(in: .whitespaces).lowercased() }
        )
        for pin in pins {
            #expect(
                headings.contains(pin.identity.lowercased()),
                "\(pin.identity) has no `### \(pin.identity)` entry in \(Self.noticesName)")
            var url = pin.location
            if url.hasSuffix(".git") { url.removeLast(4) }
            #expect(notices.contains("<\(url)>"), "\(pin.identity)'s entry does not link <\(url)>")
        }
    }

    /// The other direction: a package the app no longer resolves is no
    /// longer compiled into it, so its entry under Swift packages has gone
    /// stale. Notices list what ships, not what once did.
    @Test func everyListedPackageIsStillPinned() throws {
        let pinned = Set(try pins().map { $0.identity.lowercased() })
        let notices = try text(Self.noticesName)
        let section =
            try #require(notices.components(separatedBy: "\n## Swift packages\n").last)
            .components(separatedBy: "\n## ").first ?? ""
        let listed = section.split(separator: "\n")
            .filter { $0.hasPrefix("### ") }
            .map { $0.dropFirst(4).trimmingCharacters(in: .whitespaces).lowercased() }
        #expect(!listed.isEmpty, "\(Self.noticesName) lists no Swift packages")
        for name in listed {
            #expect(pinned.contains(name), "\(name) is listed in \(Self.noticesName) but no longer pinned")
        }
    }

    @Test func theVendoredLicensesAreReferenced() throws {
        let notices = try text(Self.noticesName)
        for path in [
            "Packages/Audio/Vendor/webrtc-apm/licenses/LICENSE.webrtc-audio-processing",
            "Packages/Audio/Vendor/webrtc-apm/licenses/LICENSE.abseil-cpp",
        ] {
            #expect(
                FileManager.default.fileExists(atPath: Self.root.appending(path: path).path), "\(path) is missing")
            #expect(notices.contains(path), "\(Self.noticesName) does not reference \(path)")
        }
    }

    @Test func theReleaseWorkflowShipsTheNotices() throws {
        let workflow = try text(".github/workflows/release.yml")
        #expect(workflow.contains("cp LICENSE NOTICE \(Self.noticesName)"))
    }
}
