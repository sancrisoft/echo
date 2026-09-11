//
//  BrowserCatalog.swift
//  CallDetection
//
//  Every browser installed on this Mac, asked of the system instead of
//  hardcoded.
//
//  The curated catalog named six browsers, which meant a Google Meet call in
//  the seventh — Zen, Vivaldi, Opera, Orion, plain Chromium, whatever ships
//  next — was invisible to detection. A browser is not something worth keeping
//  a list of: macOS already knows which apps are browsers, because they are
//  the apps that register to open `https` URLs. Asking LaunchServices makes
//  detection browser-agnostic and keeps it that way with no code change.
//
//  The curated catalog still comes first (`CallAppCatalog.match`): it owns the
//  native meeting apps, the display names Echo has always shown, and the one
//  browser process that lives outside its app bundle (Safari's WebKit GPU
//  process). This file is the fallback tier underneath it.
//
//  The accepted cost is the curated tier's, now across more browsers: non-call
//  mic use in a browser (voice search) can offer to record. The island is
//  dismissible and never records on its own, so the worst case is one ignored
//  prompt.
//
//  AppKit here is `NSWorkspace` for app identity, never for drawing;
//  scripts/check_boundaries.sh allowlists this file by path.
//

import AppKit
import Audio
import Foundation
import Synchronization

public enum BrowserCatalog {

    /// Every installed browser as a selector, in LaunchServices' order (the
    /// user's default browser first). Scopeable like any other browser: the
    /// processes these entries match are the ones playing the call's audio.
    ///
    /// Deduplicated by bundle ID — a browser that ships an updater or a second
    /// copy of its own bundle is listed once.
    public static func installed() -> [ProcessSelector] {
        cachedApps(query: query)
    }

    /// Any `https` URL asks LaunchServices the same question — which apps
    /// registered to open the scheme — so the host is a placeholder and is
    /// never resolved. A literal that cannot fail to parse, guarded rather
    /// than force-unwrapped: an empty tier degrades to the curated catalog.
    private static let httpsProbe = URL(string: "https://echo.local")

    private static func query() -> [ProcessSelector] {
        guard let httpsProbe else { return [] }
        var seen = Set<String>()
        return NSWorkspace.shared.urlsForApplications(toOpen: httpsProbe).compactMap { url in
            guard let bundleID = Bundle(url: url)?.bundleIdentifier,
                seen.insert(bundleID).inserted
            else { return nil }
            return ProcessSelector(displayName: displayName(for: url), bundlePrefix: bundleID)
        }
    }

    /// The bundle's file name without `.app` — "Zen", "Brave Browser",
    /// "Google Chrome".
    ///
    /// Not `FileManager.displayName(atPath:)`, which appends ".app" for a user
    /// who shows all file extensions, and not `CFBundleDisplayName`, which is
    /// localized: the disabled-apps setting is keyed on this string, so it has
    /// to be the same string on every Mac and after every OS language change.
    private static func displayName(for url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
    }

    // MARK: - Cache

    /// A short-lived cache so the LaunchServices query stays off the hot path
    /// of a Core Audio listener. The set changes only when the user installs
    /// or removes a browser, and a browser installed mid-session becomes
    /// detectable within the TTL — well inside the time it takes to open it
    /// and join a call.
    ///
    /// Behind a `Mutex` for `AppBundleIdentity`'s reason: the callers are
    /// threads, not actors. The mic-activity monitor resolves a report on its
    /// own queue while a settings change re-runs the filter on the main actor,
    /// and neither may block on the other's isolation to read the list.
    private static let cache = Mutex<(apps: [ProcessSelector], readAt: Date?)>(([], nil))

    /// Measured only in the sense that the query is a LaunchServices round
    /// trip: 60 s is long enough that a burst of listener fires costs one, and
    /// short enough that installing a browser is picked up before a call in it
    /// can start.
    private static let ttl: TimeInterval = 60

    private static func cachedApps(query: () -> [ProcessSelector]) -> [ProcessSelector] {
        let fresh = cache.withLock { state -> [ProcessSelector]? in
            guard let readAt = state.readAt, Date().timeIntervalSince(readAt) < ttl else {
                return nil
            }
            return state.apps
        }
        if let fresh { return fresh }

        let queried = query()
        cache.withLock { $0 = (queried, Date()) }
        return queried
    }
}
