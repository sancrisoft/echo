//
//  UpdateInstallerTests.swift
//  UpdatesTests
//
//  The bash Echo hands to `/bin/bash` when the user clicks Update Now,
//  rendered from a fixed plan so the assertions read like the script, plus the
//  report a failed update leaves behind for the next launch.
//

import EchoCore
import EchoCoreTestSupport
import Foundation
import Testing

@testable import Updates

@Suite("Updater script")
struct UpdaterScriptTests {

    private func plan(bundle: String = UpdaterPlan.defaultInstallPath) -> UpdaterPlan {
        UpdaterPlan(
            pid: 4242,
            bundleURL: URL(filePath: bundle),
            installerURL: GitHubReleaseFeed.installScriptURL,
            logURL: URL(filePath: "/Users/someone/Library/Application Support/Echo/Logs/update.log"),
            failureReportURL: URL(filePath: "/Users/someone/Library/Application Support/Echo/Logs/update-failed.txt"),
            appVersion: "v0.0.12 (87)"
        )
    }

    @Test func waitsForEchoToQuitThenRunsTheREADMEsInstaller() {
        let script = UpdateInstaller.updaterScript(plan())
        #expect(script.hasPrefix("#!/bin/bash\n"))
        #expect(script.contains("set -o pipefail"))
        #expect(script.contains("pid=4242"))
        #expect(script.contains("kill -0 \"$pid\""))
        #expect(script.contains("installer='\(GitHubReleaseFeed.installScriptURL.absoluteString)'"))
        #expect(script.contains("curl -fsSL --max-time 60 -o \"$work/install.sh\" \"$installer\""))
        #expect(script.contains("bash \"$work/install.sh\""))
        #expect(script.contains("v0.0.12 (87)"))
    }

    @Test func theDefaultLocationIsLeftToTheInstaller() {
        let script = UpdateInstaller.updaterScript(plan())
        #expect(!script.contains("ECHO_INSTALL_DEST="))
        #expect(script.contains("open \"$app\""))
    }

    @Test func aBundleAnywhereElseIsTheOneReplaced() {
        let script = UpdateInstaller.updaterScript(plan(bundle: "/Users/someone/Applications/Echo.app"))
        #expect(script.contains("export ECHO_INSTALL_DEST='/Users/someone/Applications/Echo.app'"))
    }

    @Test func pathsWithSpacesAreQuoted() {
        let script = UpdateInstaller.updaterScript(plan())
        #expect(script.contains("report='/Users/someone/Library/Application Support/Echo/Logs/update-failed.txt'"))
        #expect(script.contains("logfile='/Users/someone/Library/Application Support/Echo/Logs/update.log'"))
    }

    @Test func aFailureLeavesAReportAndReopensEcho() {
        let script = UpdateInstaller.updaterScript(plan())
        #expect(script.contains("> \"$report\""))
        #expect(
            script.contains("grep -q 'ECHO_INSTALL_DEST' \"$work/install.sh\""),
            "refuses an installer that predates the seam it relies on"
        )
        // Two failure branches reopen Echo, and so does the normal ending.
        #expect(script.components(separatedBy: "\n  reopen\n").count - 1 == 2, "each failure path reopens Echo")
        #expect(script.hasSuffix("\nreopen\n"))
    }

    @Test(
        arguments: [
            ("plain", "'plain'"),
            ("with space", "'with space'"),
            ("it's", "'it'\\''s'"),
        ] as [(String, String)]
    )
    func shellQuoting(input: (String, String)) {
        #expect(UpdateInstaller.shellQuoted(input.0) == input.1)
    }

    @Test func theScriptIsValidBash() throws {
        let scratch = try TemporaryDirectory()
        defer { scratch.remove() }
        let url = scratch.path("updater.sh")
        try UpdateInstaller.updaterScript(plan()).write(to: url, atomically: true, encoding: .utf8)
        let bash = Process()
        bash.executableURL = URL(filePath: "/bin/bash")
        bash.arguments = ["-n", url.path]
        try bash.run()
        bash.waitUntilExit()
        #expect(bash.terminationStatus == 0)
    }
}

@Suite("Update installer")
struct UpdateInstallerPathsTests {

    /// The log and the report hang off the data root that was injected, so a
    /// test never writes near the real folder.
    @Test func theLogAndTheReportHangOffTheInjectedDataRoot() throws {
        let scratch = try TemporaryDirectory()
        defer { scratch.remove() }
        let installer = UpdateInstaller(dataRoot: DataRoot(url: scratch.url))
        #expect(installer.logURL == scratch.url.appending(path: "Logs/update.log"))
        #expect(installer.failureReportURL == scratch.url.appending(path: "Logs/update-failed.txt"))
    }

    @Test func aFailureReportIsReadOnce() throws {
        let scratch = try TemporaryDirectory()
        defer { scratch.remove() }
        let installer = UpdateInstaller(dataRoot: DataRoot(url: scratch.url))
        #expect(installer.takeFailureReport() == nil)

        try FileManager.default.createDirectory(
            at: installer.failureReportURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try "The installer exited with code 1\n".write(
            to: installer.failureReportURL, atomically: true, encoding: .utf8
        )
        #expect(installer.takeFailureReport() == "The installer exited with code 1")
        #expect(installer.takeFailureReport() == nil)
        #expect(!FileManager.default.fileExists(atPath: installer.failureReportURL.path))
    }
}
