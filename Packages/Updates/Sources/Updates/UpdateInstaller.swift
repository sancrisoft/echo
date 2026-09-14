//
//  UpdateInstaller.swift
//  Updates
//
//  Leaving the app: the release page, and the update itself.
//
//  Echo updates by starting the same installer the README quotes as a detached
//  process and quitting: the installer swaps the bundle and reopens Echo, so
//  the app never overwrites itself while running.
//
//  `AppKit` here is process work — opening a URL, quitting the app — and never
//  drawing; scripts/check_boundaries.sh allowlists this file by path. The
//  pasteboard is deliberately absent: it already has an owner in
//  `Workspace/MeetingActions.swift`.
//

import AppKit
import EchoCore
import Foundation

/// Why an update could not be started. Never why one failed: by then this
/// process is gone and the updater writes its own report.
public enum UpdateInstallFailure: Error, CustomStringConvertible, LocalizedError {

    /// The updater script or its log could not be written.
    case couldNotPrepare(String)
    /// `Process` refused to start `/bin/bash` on the updater script.
    case updaterDidNotStart(String)

    public var description: String {
        switch self {
        case .couldNotPrepare(let why): return "Couldn't prepare the updater: \(why)"
        case .updaterDidNotStart(let why): return "Couldn't start the updater: \(why)"
        }
    }

    public var errorDescription: String? { description }
}

/// What the updater script needs to know, gathered on the main actor and
/// rendered into bash by `UpdateInstaller.updaterScript`. Pure, so a test can
/// render one without a running app.
public struct UpdaterPlan: Equatable, Sendable {

    /// The Echo process the updater waits for before touching anything.
    public var pid: Int32
    /// The bundle to replace and reopen — `/Applications/Echo.app` normally.
    public var bundleURL: URL
    /// Where the installer is fetched from: the README's URL.
    public var installerURL: URL
    /// Appended to with everything the updater and the installer print.
    public var logURL: URL
    /// Written only when the update fails; Echo reads it at the next launch.
    public var failureReportURL: URL
    /// For the log's first line.
    public var appVersion: String

    public init(
        pid: Int32,
        bundleURL: URL,
        installerURL: URL,
        logURL: URL,
        failureReportURL: URL,
        appVersion: String
    ) {
        self.pid = pid
        self.bundleURL = bundleURL
        self.installerURL = installerURL
        self.logURL = logURL
        self.failureReportURL = failureReportURL
        self.appVersion = appVersion
    }

    /// The installer's own default. A bundle anywhere else is handed to it
    /// as `ECHO_INSTALL_DEST`, so the copy that was running is the one
    /// replaced (a dev build in DerivedData, a ~/Applications install).
    public static let defaultInstallPath = "/Applications/Echo.app"

    public var installsToDefaultPath: Bool {
        bundleURL.standardizedFileURL.path == Self.defaultInstallPath
    }
}

/// Starts an update and reads what the last one left behind.
///
/// The data root is injected rather than global: `update.log` and
/// `update-failed.txt` hang off the root this Echo was launched with, and a
/// test points it at a scratch folder.
public struct UpdateInstaller: Sendable {

    private let dataRoot: DataRoot

    public init(dataRoot: DataRoot) {
        self.dataRoot = dataRoot
    }

    /// `<data root>/Logs/update.log` — every update's transcript, appended.
    public var logURL: URL {
        dataRoot.logs.appending(path: "update.log", directoryHint: .notDirectory)
    }

    /// `<data root>/Logs/update-failed.txt` — exists only between a failed
    /// update and the next launch, which reads and removes it.
    public var failureReportURL: URL {
        dataRoot.logs.appending(path: "update-failed.txt", directoryHint: .notDirectory)
    }

    /// The report a failed update left for this launch, if any. Removed once
    /// read, so it is shown once.
    public func takeFailureReport() -> String? {
        let url = failureReportURL
        guard let data = try? Data(contentsOf: url) else { return nil }
        try? FileManager.default.removeItem(at: url)
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// Updates Echo. Writes the updater script, starts it detached with its
    /// output going to `update.log`, and quits. The updater waits for this
    /// process to exit, downloads and runs the installer — which swaps the
    /// bundle and reopens Echo — and on any failure leaves a report and
    /// reopens the Echo that was there. Returns only when the updater could
    /// not be started; otherwise the process ends here.
    @MainActor
    public func updateAndRelaunch() throws {
        let plan = UpdaterPlan(
            pid: ProcessInfo.processInfo.processIdentifier,
            bundleURL: Bundle.main.bundleURL,
            installerURL: GitHubReleaseFeed.installScriptURL,
            logURL: logURL,
            failureReportURL: failureReportURL,
            appVersion: AppIdentity.version.display
        )
        let scriptURL = FileManager.default.temporaryDirectory
            .appending(path: "update-echo.sh", directoryHint: .notDirectory)
        let log: FileHandle
        do {
            try Self.updaterScript(plan).write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
            try FileManager.default.createDirectory(
                at: plan.logURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            if !FileManager.default.fileExists(atPath: plan.logURL.path) {
                FileManager.default.createFile(atPath: plan.logURL.path, contents: nil)
            }
            log = try FileHandle(forWritingTo: plan.logURL)
            try log.seekToEnd()
        } catch {
            throw UpdateInstallFailure.couldNotPrepare(error.localizedDescription)
        }

        let updater = Process()
        updater.executableURL = URL(filePath: "/bin/bash")
        updater.arguments = [scriptURL.path]
        updater.standardInput = FileHandle.nullDevice
        updater.standardOutput = log
        updater.standardError = log
        do {
            try updater.run()
        } catch {
            throw UpdateInstallFailure.updaterDidNotStart(error.localizedDescription)
        }
        // A child outlives its parent on macOS; the updater is waiting for
        // exactly this exit.
        NSApplication.shared.terminate(nil)
    }

    /// Opens a release's page — notes, assets, the full changelog.
    @MainActor
    public static func openReleasePage(_ release: LatestRelease) {
        NSWorkspace.shared.open(release.pageURL)
    }

    /// The updater, as bash. It refuses to proceed while Echo is still
    /// running, fetches the installer to a file before running it (a cut-off
    /// download cannot run half a script, and a curl failure is reported as
    /// one), insists the installer is one that understands
    /// `ECHO_INSTALL_DEST`, and reopens Echo whether or not the update
    /// succeeded — the installer's staging-and-swap means a failure leaves
    /// the old bundle in place.
    public static func updaterScript(_ plan: UpdaterPlan) -> String {
        let destination =
            plan.installsToDefaultPath
            ? "# Default location: the installer reopens Echo itself once the bundle is swapped."
            : "export ECHO_INSTALL_DEST=\(shellQuoted(plan.bundleURL.path))"
        return """
            #!/bin/bash
            # Written by Echo \(plan.appVersion) for Settings › Updates › Update Now. Waits for
            # Echo to quit, runs the same installer as the README, and reopens Echo.
            # Safe to delete.
            set -o pipefail
            trap '' HUP

            pid=\(plan.pid)
            app=\(shellQuoted(plan.bundleURL.path))
            report=\(shellQuoted(plan.failureReportURL.path))
            logfile=\(shellQuoted(plan.logURL.path))
            installer=\(shellQuoted(plan.installerURL.absoluteString))
            work="$(mktemp -d "${TMPDIR:-/tmp}/echo-update.XXXXXX")"
            trap 'rm -rf "$work"' EXIT

            log() { printf '[%s] %s\\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
            fail() {
              log "$1"
              mkdir -p "$(dirname "$report")" && printf '%s\\n' "$1" > "$report"
              osascript -e 'on run argv' -e 'display notification (item 1 of argv) with title "Echo update failed"' -e 'end run' "$1" >/dev/null 2>&1 || true
            }
            reopen() {
              sleep 1
              pgrep -qx Echo >/dev/null 2>&1 || open "$app"
            }

            log "Echo \(plan.appVersion) asked for an update; waiting for pid $pid to quit"
            for _ in $(seq 1 150); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
            if kill -0 "$pid" 2>/dev/null; then
              fail "Echo did not quit, so nothing was updated."
              exit 1
            fi

            log "downloading $installer"
            curl -fsSL --max-time 60 -o "$work/install.sh" "$installer"
            code=$?
            if [ "$code" -ne 0 ]; then
              fail "Couldn't download the installer (curl exit $code). Are you online? Echo was left as it was."
              reopen
              exit 1
            fi
            if ! grep -q 'ECHO_INSTALL_DEST' "$work/install.sh"; then
              fail "The installer on GitHub is older than this Echo expects; update with the README's command instead. Echo was left as it was."
              reopen
              exit 1
            fi

            \(destination)
            log "running the installer"
            bash "$work/install.sh"
            code=$?
            if [ "$code" -eq 0 ]; then
              log "installer finished"
            else
              fail "The installer exited with code $code; unless it said otherwise, the Echo you had is untouched. Details in $logfile"
            fi
            reopen

            """
    }

    /// Single-quotes `text` for bash, so spaces, `$`, backticks and quotes
    /// in a path survive.
    public static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
