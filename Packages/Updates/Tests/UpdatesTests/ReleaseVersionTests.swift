//
//  ReleaseVersionTests.swift
//  UpdatesTests
//
//  The version arithmetic behind the tags, and the rule that decides which
//  version this build claims to be.
//

import Foundation
import Testing

@testable import Updates

@Suite("Release versions")
struct ReleaseVersionTests {

    @Test(
        arguments: [
            ("v0.0.12", [0, 0, 12], nil),
            ("0.0.12", [0, 0, 12], nil),
            ("V1.2", [1, 2], nil),
            ("v0.1.0-rc.1", [0, 1, 0], "rc.1"),
            (" v0.0.12\n", [0, 0, 12], nil),
            ("v0.0.10-hotfix.1", [0, 0, 10], "hotfix.1"),
        ] as [(String, [Int], String?)]
    )
    func parsesTagsAndBareNumbers(input: (String, [Int], String?)) throws {
        let version = try #require(ReleaseVersion(input.0))
        #expect(version.components == input.1)
        #expect(version.preRelease == input.2)
    }

    @Test(arguments: ["", "latest", "1.0.x", "v", "-rc", "1..2", "v1.", "+1.0", "1.0-"])
    func rejectsAnythingThatIsNotAVersion(text: String) {
        #expect(ReleaseVersion(text) == nil)
    }

    @Test func printsTheTagAndTheBareFormBack() throws {
        let version = try #require(ReleaseVersion("v0.0.12"))
        #expect(version.description == "0.0.12")
        #expect(version.tag == "v0.0.12")

        let candidate = try #require(ReleaseVersion("0.1.0-rc.1"))
        #expect(candidate.tag == "v0.1.0-rc.1")
    }

    @Test func ordersNumericallyNotLexically() throws {
        let chain = try ["0.0.9", "0.0.10", "0.0.12", "0.1.0", "1.0"].map { try #require(ReleaseVersion($0)) }
        for (lower, higher) in zip(chain, chain.dropFirst()) {
            #expect(lower < higher, "\(lower) should sort before \(higher)")
        }
    }

    @Test func trailingZerosDoNotMakeADifferentVersion() throws {
        let short = try #require(ReleaseVersion("1.0"))
        let long = try #require(ReleaseVersion("1.0.0"))
        #expect(short == long)
        #expect(short.hashValue == long.hashValue)
        #expect(!(short < long) && !(long < short))
    }

    @Test func preReleasesSortBeforeTheirRelease() throws {
        let rc = try #require(ReleaseVersion("0.1.0-rc.1"))
        let beta = try #require(ReleaseVersion("0.1.0-beta"))
        let release = try #require(ReleaseVersion("0.1.0"))
        let previous = try #require(ReleaseVersion("0.0.12"))
        #expect(rc < release)
        #expect(beta < rc)
        #expect(previous < beta)
    }

    /// `ECHO_INSTALLED_VERSION` exists so a dev build, whose 1.0 is ahead of
    /// every tag, can still be shown the "update available" path.
    @Test func theOverrideWinsOverTheBundleAndGarbageIsIgnored() {
        #expect(ReleaseVersion.installed(bundleVersion: "1.0", override: nil) == ReleaseVersion("1.0"))
        #expect(ReleaseVersion.installed(bundleVersion: "1.0", override: "0.0.1") == ReleaseVersion("0.0.1"))
        #expect(ReleaseVersion.installed(bundleVersion: "1.0", override: "nonsense") == ReleaseVersion("1.0"))
        #expect(ReleaseVersion.installed(bundleVersion: "?", override: nil) == nil)
    }
}
