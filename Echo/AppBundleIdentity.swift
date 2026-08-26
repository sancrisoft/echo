//
//  AppBundleIdentity.swift
//  Echo
//
//  Which `.app` a running process belongs to — the identity Core Audio's
//  bundle ID alone cannot give.
//
//  Chromium helpers carry their parent's bundle ID as a prefix
//  (`com.brave.Browser.helper.renderer`), so `CallApp.matches` finds them from
//  the bundle ID alone. Gecko-based browsers do not work that way: Zen's media
//  process is `app.zen-browser.plugincontainer` and Firefox's is
//  `org.mozilla.plugincontainer` — neither shares a prefix with the browser
//  the user actually launched. What every architecture *does* share is a path:
//  the helper's executable lives inside the parent's bundle. So the process's
//  executable path, walked up to its outermost `.app`, is the one identity
//  that holds for all of them.
//
//  This is what makes browser detection browser-agnostic: paired with
//  `BrowserCatalog`, a mic-capturing process is recognised as "a browser" by
//  the bundle it lives in, so a browser Echo has never heard of is detected
//  the day it is installed.
//
//  The walk is pure and table-tested; only the pid → path syscall and the
//  Info.plist read touch the system.
//

import Darwin
import Foundation

nonisolated enum AppBundleIdentity {

    /// The bundle ID of the outermost `.app` containing this process's
    /// executable, or `""` when there is none: daemons, XPC services that live
    /// inside a framework rather than an app (Safari's WebKit GPU process is
    /// one — it keeps its curated catalog entry for exactly this reason), and
    /// pids that died before the read.
    ///
    /// An empty result is the same silence as an empty bundle ID: it matches
    /// nothing, so a nameless process can never be read as a call.
    static func appBundleID(ofPID pid: pid_t) -> String {
        guard let executable = executablePath(ofPID: pid),
              let bundlePath = outermostAppBundlePath(forExecutablePath: executable)
        else { return "" }
        return cache.bundleID(atPath: bundlePath)
    }

    /// The outermost `.app` in an executable's path — the app the user
    /// launched, never a helper bundle nested inside it:
    ///
    ///     …/Brave Browser.app/Contents/Frameworks/…/Helpers/
    ///         Brave Browser Helper (Renderer).app/Contents/MacOS/…
    ///       → …/Brave Browser.app
    ///     /Applications/Zen.app/Contents/MacOS/plugin-container.app/
    ///         Contents/MacOS/plugin-container
    ///       → /Applications/Zen.app
    ///
    /// `nil` for a path with no `.app` component at all, so a daemon is never
    /// read as belonging to an app.
    static func outermostAppBundlePath(forExecutablePath path: String) -> String? {
        var walked: [String] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            walked.append(String(component))
            if component.hasSuffix(".app") {
                return "/" + walked.joined(separator: "/")
            }
        }
        return nil
    }

    /// The process's executable path. `proc_pidpath` needs no entitlement for
    /// processes of the same user, and Echo runs unsandboxed (system-audio
    /// taps require it), so this is readable for every app the user launched.
    private static func executablePath(ofPID pid: pid_t) -> String? {
        // PROC_PIDPATHINFO_MAXSIZE (4 * MAXPATHLEN) — the size `proc_pidpath`
        // documents as always sufficient; it is not exposed to Swift.
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    // MARK: - Cache

    private static let cache = BundleIDCache()

    /// Keyed on the app bundle's *path*, not the pid: the path → bundle ID
    /// mapping is stable for as long as the app is installed, while pids are
    /// recycled and would eventually hand a new process a stale identity. The
    /// pid → path syscall is cheap and therefore never cached; only the
    /// Info.plist read is, which is what makes resolving every process object
    /// on a scoped tap's follow update affordable (measured over a full
    /// 204-process table: 7 ms cold, 1 ms warm).
    private final class BundleIDCache {
        private let lock = NSLock()
        private var ids: [String: String] = [:]

        func bundleID(atPath path: String) -> String {
            lock.lock()
            let cached = ids[path]
            lock.unlock()
            if let cached { return cached }

            let resolved = Bundle(url: URL(fileURLWithPath: path))?.bundleIdentifier ?? ""
            lock.lock()
            ids[path] = resolved
            lock.unlock()
            return resolved
        }
    }
}
