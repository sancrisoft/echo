//
//  BrowserCatalog.swift
//  Echo
//
//  Every browser installed on this Mac, asked of the system instead of
//  hardcoded.
//
//  ADR-017's curated catalog named six browsers, which meant a Google Meet
//  call in the seventh — Zen, Vivaldi, Opera, Orion, plain Chromium, whatever
//  ships next — was invisible to detection. A browser is not something worth
//  keeping a list of: macOS already knows which apps are browsers, because
//  they are the apps that register to open `https` URLs. Asking LaunchServices
//  makes detection browser-agnostic and keeps it that way with no code change.
//
//  The curated catalog still comes first (`CallAppCatalog.match`): it owns the
//  native meeting apps, the display names Echo has always shown, and the one
//  browser process that lives outside its app bundle (Safari's WebKit GPU
//  process). This file is the fallback tier underneath it.
//
//  The accepted cost is ADR-017's, now across more browsers: non-call mic use
//  in a browser (voice search) can offer to record. The island is dismissible
//  and never records on its own, so the worst case is one ignored prompt.
//

import AppKit
import Foundation

nonisolated enum BrowserCatalog {

    /// Every installed browser as a `CallApp`, in LaunchServices' order (the
    /// user's default browser first). Scopeable like any other browser: the
    /// processes these entries match are the ones playing the call's audio.
    ///
    /// Deduplicated by bundle ID — a browser that ships an updater or a second
    /// copy of its own bundle is listed once.
    static func installed() -> [CallApp] {
        cache.apps(query: query)
    }

    private static let httpsProbe = URL(string: "https://echo.local")!

    private static func query() -> [CallApp] {
        var seen = Set<String>()
        return NSWorkspace.shared.urlsForApplications(toOpen: httpsProbe).compactMap { url in
            guard let bundleID = Bundle(url: url)?.bundleIdentifier,
                  seen.insert(bundleID).inserted
            else { return nil }
            return CallApp(displayName: displayName(for: url), bundlePrefix: bundleID)
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

    private static let cache = InstalledCache()

    /// A short-lived cache so the LaunchServices query stays off the hot path
    /// of a Core Audio listener. The set changes only when the user installs
    /// or removes a browser, and a browser installed mid-session becomes
    /// detectable within the TTL — well inside the time it takes to open it
    /// and join a call.
    private final class InstalledCache {
        private static let ttl: TimeInterval = 60

        private let lock = NSLock()
        private var cached: [CallApp] = []
        private var readAt: Date?

        func apps(query: () -> [CallApp]) -> [CallApp] {
            lock.lock()
            if let readAt, Date().timeIntervalSince(readAt) < Self.ttl {
                let fresh = cached
                lock.unlock()
                return fresh
            }
            lock.unlock()

            let queried = query()
            lock.lock()
            cached = queried
            readAt = Date()
            lock.unlock()
            return queried
        }
    }
}
