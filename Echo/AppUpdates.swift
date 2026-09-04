//
//  AppUpdates.swift
//  Echo
//
//  Telling the user a newer Echo exists, and installing it.
//
//  Echo ships as ad-hoc signed zips attached to GitHub releases, installed
//  and updated by scripts/install.sh; there is no Sparkle feed. The app asks
//  GitHub what the latest release is, compares, and — on request — updates
//  itself by starting that same installer as a detached process and quitting:
//  the installer swaps the bundle and reopens Echo, so the app never
//  overwrites itself while running.
//
//    • `ReleaseVersion`      the "v0.0.12" ⇄ "0.0.12" arithmetic, pure
//    • `GitHubReleaseFeed`   the repository's URLs and the API decoding, pure
//    • `UpdateChecker`       observable state for Settings and the menu bar,
//                            plus the once-a-day automatic check
//    • `UpdaterPlan`         what the updater script needs to know, pure
//    • `UpdateActions`       leaving the app: release page, clipboard, and
//                            the update itself (updater script + quit)
//
//  Privacy: a check is one unauthenticated GET to api.github.com for the
//  latest release's metadata. It carries Echo's version in the User-Agent and
//  nothing about the user or their meetings, and one Settings toggle turns the
//  automatic one off. An update downloads the installer and the release zip
//  from GitHub, nothing else.
//
//  Comparing versions is the whole truth: a fix is always a new version (no
//  rebuilds under an existing tag, decided 2026-09-04), so the installer's
//  code-directory-hash comparison is idempotency, not a second signal.
//

import AppKit
import Foundation
import Observation

// MARK: - Versions

/// A release's version: the number behind a `vX.Y.Z` tag.
nonisolated struct ReleaseVersion: Hashable, Comparable, Sendable, CustomStringConvertible {

    /// Numeric components as written — [0, 0, 12] for "v0.0.12".
    let components: [Int]

    /// Anything after a hyphen — "rc.1" for "v0.1.0-rc.1". Nil for a release.
    let preRelease: String?

    /// Accepts "v0.0.12", "0.0.12", "V1.2" and "v0.1.0-rc.1" (surrounding
    /// whitespace ignored). Nil for anything that is not digits and dots —
    /// "", "latest", "1.0.x", a bare "v".
    init?(_ text: String) {
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.hasPrefix("v") || body.hasPrefix("V") { body.removeFirst() }

        var suffix: String?
        if let dash = body.firstIndex(of: "-") {
            suffix = String(body[body.index(after: dash)...])
            body = String(body[..<dash])
            if suffix?.isEmpty == true { return nil }
        }
        guard !body.isEmpty else { return nil }

        var parsed: [Int] = []
        for piece in body.split(separator: ".", omittingEmptySubsequences: false) {
            guard !piece.isEmpty, piece.allSatisfy(\.isNumber), let number = Int(piece) else { return nil }
            parsed.append(number)
        }
        components = parsed
        preRelease = suffix
    }

    /// "v0.0.12" — the git tag form.
    var tag: String { "v\(description)" }

    /// "0.0.12", or "0.1.0-rc.1".
    var description: String {
        let numbers = components.map(String.init).joined(separator: ".")
        return preRelease.map { "\(numbers)-\($0)" } ?? numbers
    }

    /// "1.0" and "1.0.0" are the same version: trailing zeros never count.
    private var normalized: [Int] {
        var trimmed = components
        while trimmed.count > 1, trimmed.last == 0 { trimmed.removeLast() }
        return trimmed
    }

    static func == (lhs: ReleaseVersion, rhs: ReleaseVersion) -> Bool {
        lhs.normalized == rhs.normalized && lhs.preRelease == rhs.preRelease
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(normalized)
        hasher.combine(preRelease)
    }

    /// Numeric components first; with equal numbers a pre-release sorts
    /// before the release it precedes (0.1.0-rc.1 < 0.1.0), and two
    /// pre-releases compare as plain strings.
    static func < (lhs: ReleaseVersion, rhs: ReleaseVersion) -> Bool {
        let a = lhs.normalized, b = rhs.normalized
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0
            let y = index < b.count ? b[index] : 0
            if x != y { return x < y }
        }
        switch (lhs.preRelease, rhs.preRelease) {
        case (nil, nil): return false
        case (.some, nil): return true
        case (nil, .some): return false
        case let (.some(p), .some(q)): return p < q
        }
    }
}

/// What GitHub reports as the newest release.
nonisolated struct LatestRelease: Equatable, Sendable {
    var version: ReleaseVersion
    /// The tag exactly as published ("v0.0.12").
    var tag: String
    /// The release's title ("Echo 0.0.12"), if it has one.
    var title: String?
    /// The release page — notes, assets, the full changelog.
    var pageURL: URL
    var publishedAt: Date?
}

/// Why a check produced no answer. `message` is what the Settings page shows.
nonisolated enum UpdateCheckError: Error, Equatable {
    /// The request never got an HTTP answer: offline, DNS, timeout, TLS.
    case offline
    case http(Int)
    /// 403/429 — GitHub's unauthenticated limit is 60 requests an hour per
    /// address, which a busy office NAT can exhaust.
    case rateLimited
    case malformed(String)
    case unrecognizedTag(String)

    var message: String {
        switch self {
        case .offline:
            return "Couldn't reach GitHub. Are you online?"
        case .rateLimited:
            return "GitHub is limiting update checks from this network right now. Try again in an hour."
        case .http(404):
            return "GitHub has no releases for Echo (HTTP 404)."
        case .http(let code):
            return "GitHub answered with HTTP \(code)."
        case .malformed:
            return "GitHub sent an answer Echo couldn't read."
        case .unrecognizedTag(let tag):
            return "The latest release is tagged “\(tag)”, which isn't a version Echo understands."
        }
    }
}

// MARK: - The feed

/// Where Echo's releases live and how the latest one is read. Every URL a
/// user might see — README, release notes, the Update button — derives from
/// `repository`, so the install command is one string everywhere (a test
/// holds the README and the script to it).
nonisolated enum GitHubReleaseFeed {

    static let repository = "sancrisoft/echo"
    static let defaultBranch = "main"

    static var releasesPageURL: URL {
        URL(string: "https://github.com/\(repository)/releases")!
    }

    static var latestReleaseAPIURL: URL {
        URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
    }

    static var installScriptURL: URL {
        URL(string: "https://raw.githubusercontent.com/\(repository)/\(defaultBranch)/scripts/install.sh")!
    }

    /// The README's one-liner, verbatim.
    static var installCommand: String {
        "curl -fsSL \(installScriptURL.absoluteString) | bash"
    }

    /// The request a check sends. No cache: the point is today's answer.
    static func latestReleaseRequest(appVersion: String) -> URLRequest {
        var request = URLRequest(url: latestReleaseAPIURL, timeoutInterval: 15)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Echo/\(appVersion) (macOS)", forHTTPHeaderField: "User-Agent")
        return request
    }

    /// The fields of GitHub's release object this needs. Drafts and
    /// pre-releases never come back from /releases/latest, so there is
    /// nothing to filter.
    private struct Payload: Decodable {
        var tagName: String
        var name: String?
        var htmlUrl: URL
        var publishedAt: Date?

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case name
            case htmlUrl = "html_url"
            case publishedAt = "published_at"
        }
    }

    static func decodeLatest(_ data: Data) throws -> LatestRelease {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let payload: Payload
        do {
            payload = try decoder.decode(Payload.self, from: data)
        } catch {
            throw UpdateCheckError.malformed(String(describing: error))
        }
        guard let version = ReleaseVersion(payload.tagName) else {
            throw UpdateCheckError.unrecognizedTag(payload.tagName)
        }
        return LatestRelease(
            version: version,
            tag: payload.tagName,
            title: payload.name,
            pageURL: payload.htmlUrl,
            publishedAt: payload.publishedAt
        )
    }
}

// MARK: - The checker

/// The update state the Settings page and the menu-bar popover render.
///
/// `status` is the last *answer* and survives a re-check (`isChecking` is
/// separate), so the popover's "Update available" never flickers off while
/// the daily check is in flight.
@Observable
@MainActor
final class UpdateChecker {

    nonisolated enum Status: Equatable {
        /// Never checked (or the automatic check is still pending).
        case idle
        case upToDate(LatestRelease)
        case available(LatestRelease)
        case failed(String)
    }

    /// The network, injectable: tests hand in canned answers.
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    /// The version this build compares against — nil only if the bundle's
    /// version string is unparseable, which `evaluate` reports as a failure
    /// rather than guessing.
    let installedVersion: ReleaseVersion?

    private(set) var status: Status = .idle
    private(set) var isChecking = false
    private(set) var lastCheckedAt: Date?

    /// What the last Update Now left behind when it failed, handed in at
    /// launch from the updater's report file (see `UpdateActions`). Shown in
    /// Settings for this run only: the report is consumed when read.
    private(set) var lastInstallFailure: String?

    @ObservationIgnored private let transport: Transport
    @ObservationIgnored private var inFlight: Task<Void, Never>?
    @ObservationIgnored private var automatic: Task<Void, Never>?

    init(
        installedVersion: ReleaseVersion? = AppVersion.release,
        transport: @escaping Transport = { try await URLSession.shared.data(for: $0) }
    ) {
        self.installedVersion = installedVersion
        self.transport = transport
    }

    /// The newer release, when the last check found one.
    var availableRelease: LatestRelease? {
        if case .available(let release) = status { return release }
        return nil
    }

    func noteInstallFailure(_ message: String) {
        lastInstallFailure = message
    }

    /// Runs one check. Concurrent callers (the daily timer and a click on
    /// Check for Updates) share a single request.
    func check() async {
        if let inFlight {
            await inFlight.value
            return
        }
        let task = Task { await performCheck() }
        inFlight = task
        await task.value
        inFlight = nil
    }

    private func performCheck() async {
        isChecking = true
        defer {
            isChecking = false
            lastCheckedAt = Date()
        }
        do {
            let latest = try await Self.fetchLatest(transport: transport, appVersion: AppVersion.short)
            status = Self.evaluate(installed: installedVersion, latest: latest)
        } catch let error as UpdateCheckError {
            status = .failed(error.message)
            // Offline is ordinary for a laptop; anything else is worth a trace.
            if error != .offline {
                ErrorTrace.record("Update check failed", error: error, category: "Updates")
            }
        } catch {
            status = .failed(UpdateCheckError.offline.message)
        }
    }

    /// The comparison, pure: newer on GitHub means available; equal or a
    /// local build ahead of every tag (a dev build's 1.0) means up to date.
    nonisolated static func evaluate(installed: ReleaseVersion?, latest: LatestRelease) -> Status {
        guard let installed else {
            return .failed("Couldn't read this build's version.")
        }
        return latest.version > installed ? .available(latest) : .upToDate(latest)
    }

    /// One request, mapped to `UpdateCheckError`. Any transport failure — no
    /// route, DNS, timeout, TLS — is `.offline`: the user's remedy is the same.
    nonisolated static func fetchLatest(transport: Transport, appVersion: String) async throws -> LatestRelease {
        let request = GitHubReleaseFeed.latestReleaseRequest(appVersion: appVersion)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport(request)
        } catch {
            throw UpdateCheckError.offline
        }
        if let http = response as? HTTPURLResponse {
            switch http.statusCode {
            case 200..<300: break
            case 403, 429: throw UpdateCheckError.rateLimited
            default: throw UpdateCheckError.http(http.statusCode)
            }
        }
        return try GitHubReleaseFeed.decodeLatest(data)
    }

    // MARK: Automatic checks

    /// Checks once shortly after launch, then daily, for as long as
    /// `isEnabled` says so. The preference is read at every tick, so flipping
    /// the toggle needs no restart — off simply skips the next ticks.
    func startAutomaticChecks(
        initialDelay: Duration = .seconds(30),
        interval: Duration = .seconds(24 * 60 * 60),
        isEnabled: @escaping @MainActor () -> Bool
    ) {
        automatic?.cancel()
        automatic = Task { [weak self] in
            try? await Task.sleep(for: initialDelay)
            while !Task.isCancelled {
                guard let self else { return }
                if isEnabled() {
                    await self.check()
                }
                try? await Task.sleep(for: interval)
            }
        }
    }

    func stopAutomaticChecks() {
        automatic?.cancel()
        automatic = nil
    }
}

// MARK: - Leaving the app

nonisolated enum UpdateActionError: Error, CustomStringConvertible {
    /// The updater script or its log could not be written.
    case couldNotPrepare(String)
    /// `Process` refused to start `/bin/bash` on the updater script.
    case updaterDidNotStart(String)

    var description: String {
        switch self {
        case .couldNotPrepare(let why): return "Couldn't prepare the updater: \(why)"
        case .updaterDidNotStart(let why): return "Couldn't start the updater: \(why)"
        }
    }
}

/// What the updater script needs to know, gathered on the main actor and
/// rendered into bash by `UpdateActions.updaterScript`. Pure, so a test can
/// render one without a running app.
nonisolated struct UpdaterPlan: Equatable, Sendable {
    /// The Echo process the updater waits for before touching anything.
    var pid: Int32
    /// The bundle to replace and reopen — `/Applications/Echo.app` normally.
    var bundleURL: URL
    /// Where the installer is fetched from: the README's URL.
    var installerURL: URL
    /// Appended to with everything the updater and the installer print.
    var logURL: URL
    /// Written only when the update fails; Echo reads it at the next launch.
    var failureReportURL: URL
    /// For the log's first line.
    var appVersion: String

    /// The installer's own default. A bundle anywhere else is handed to it
    /// as `ECHO_INSTALL_DEST`, so the copy that was running is the one
    /// replaced (a dev build in DerivedData, a ~/Applications install).
    static let defaultInstallPath = "/Applications/Echo.app"

    var installsToDefaultPath: Bool {
        bundleURL.standardizedFileURL.path == Self.defaultInstallPath
    }
}

@MainActor
enum UpdateActions {

    static func openReleasePage(_ release: LatestRelease) {
        NSWorkspace.shared.open(release.pageURL)
    }

    static func openReleasesPage() {
        NSWorkspace.shared.open(GitHubReleaseFeed.releasesPageURL)
    }

    static func copyInstallCommand() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(GitHubReleaseFeed.installCommand, forType: .string)
    }

    /// ~/Library/Application Support/Echo/Logs/update.log — every update's
    /// transcript, appended.
    nonisolated static var updateLogURL: URL {
        EchoPaths.logsDirectory.appending(path: "update.log", directoryHint: .notDirectory)
    }

    /// ~/Library/Application Support/Echo/Logs/update-failed.txt — exists only
    /// between a failed update and the next launch, which reads and removes it.
    nonisolated static var failureReportURL: URL {
        EchoPaths.logsDirectory.appending(path: "update-failed.txt", directoryHint: .notDirectory)
    }

    /// Updates Echo. Writes the updater script, starts it detached with its
    /// output going to `update.log`, and quits. The updater waits for this
    /// process to exit, downloads and runs the installer — which swaps the
    /// bundle and reopens Echo — and on any failure leaves a report and
    /// reopens the Echo that was there. Returns only when the updater could
    /// not be started; otherwise the process ends here.
    static func updateAndRelaunch() throws {
        let plan = UpdaterPlan(
            pid: ProcessInfo.processInfo.processIdentifier,
            bundleURL: Bundle.main.bundleURL,
            installerURL: GitHubReleaseFeed.installScriptURL,
            logURL: updateLogURL,
            failureReportURL: failureReportURL,
            appVersion: AppVersion.display
        )
        let scriptURL = FileManager.default.temporaryDirectory
            .appending(path: "update-echo.sh", directoryHint: .notDirectory)
        let log: FileHandle
        do {
            try updaterScript(plan).write(to: scriptURL, atomically: true, encoding: .utf8)
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
            throw UpdateActionError.couldNotPrepare(error.localizedDescription)
        }

        let updater = Process()
        updater.executableURL = URL(fileURLWithPath: "/bin/bash")
        updater.arguments = [scriptURL.path]
        updater.standardInput = FileHandle.nullDevice
        updater.standardOutput = log
        updater.standardError = log
        do {
            try updater.run()
        } catch {
            throw UpdateActionError.updaterDidNotStart(error.localizedDescription)
        }
        // A child outlives its parent on macOS; the updater is waiting for
        // exactly this exit.
        NSApplication.shared.terminate(nil)
    }

    /// The report a failed update left for this launch, if any. Removed once
    /// read, so it is shown once.
    nonisolated static func takeFailureReport(at url: URL = failureReportURL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        try? FileManager.default.removeItem(at: url)
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// The updater, as bash. It refuses to proceed while Echo is still
    /// running, fetches the installer to a file before running it (a cut-off
    /// download cannot run half a script, and a curl failure is reported as
    /// one), insists the installer is one that understands
    /// `ECHO_INSTALL_DEST`, and reopens Echo whether or not the update
    /// succeeded — the installer's staging-and-swap means a failure leaves
    /// the old bundle in place.
    nonisolated static func updaterScript(_ plan: UpdaterPlan) -> String {
        let destination = plan.installsToDefaultPath
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
    nonisolated static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
