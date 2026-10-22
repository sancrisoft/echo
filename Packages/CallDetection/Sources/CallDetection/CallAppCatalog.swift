//
//  CallAppCatalog.swift
//  CallDetection
//
//  The set of apps whose microphone capture means "the user is probably in a
//  call". Detection is deliberately NOT "any app that touches the mic" —
//  dictation, voice memos and voice assistants must never raise the island.
//
//  Two tiers meet in `match`: the curated table in this file (native meeting
//  apps, plus the browser processes that need naming by hand), and every
//  browser installed on this Mac, asked of the system by `BrowserCatalog`.
//  The second tier is why a Meet call in a browser nobody hardcoded is
//  detected; the first is why the curated names and near-miss exclusions still
//  hold.
//
//  Entries are `Audio.ProcessSelector` values, not a type of this package's
//  own: the app the island names is the app a scoped tap narrows to, and one
//  matcher for both is what keeps detection and scoping from ever disagreeing
//  about what an app is.
//
//  Pure and table-tested. The Core Audio side reports raw mic clients and
//  never decides what they mean; matching and every timing rule live here and
//  in `CallSessionMachine`.
//

import Audio

/// The curated tier. It lives in code: growing it is a code change, and a
/// user-editable list is a future spec.
///
/// Browsers appear here as well as in `BrowserCatalog` — the curated entries
/// keep the display names Echo has always shown ("Brave", not "Brave
/// Browser") and cover the one browser process that lives outside its app
/// bundle, Safari's WebKit GPU process. The accepted cost of detecting
/// browsers at all is that non-call browser mic use (voice search) can offer
/// to record. The island is dismissible and never records on its own, so the
/// worst case is one ignored prompt.
public enum CallAppCatalog {

    /// Order is the attribution order: with several catalogued processes
    /// capturing at once, the first match in this table names the island.
    /// Native meeting apps come before browsers so a Zoom call in front of an
    /// open browser tab is attributed to Zoom.
    public static let apps: [ProcessSelector] = [
        ProcessSelector(displayName: "Zoom", bundlePrefix: "us.zoom.xos"),
        ProcessSelector(displayName: "Microsoft Teams", bundlePrefix: "com.microsoft.teams2"),
        ProcessSelector(displayName: "Microsoft Teams", bundlePrefix: "com.microsoft.teams"),
        ProcessSelector(displayName: "Slack", bundlePrefix: "com.tinyspeck.slackmacgap"),
        ProcessSelector(displayName: "Discord", bundlePrefix: "com.hnc.Discord"),
        // Resolved by measuring real calls: FaceTime never captures in its own
        // process (`com.apple.FaceTime` stays at is-running-input 0, is-running
        // 0, even mid-call). The process that does is Apple's AV conferencing
        // daemon, and it tracks the call faithfully — measured going quiet
        // within two seconds of hanging up.
        //
        // A longer hold across other apps' tests looked at first like a daemon
        // that never lets go; it was a FaceTime call left connected in the
        // background. Both entries stay: the app for macOS versions that
        // capture in-process, the daemon for the ones that don't. Other Apple
        // conferencing surfaces (an iPhone call relayed to the Mac) share the
        // daemon, so they attribute here too — they are calls as well, and the
        // island's copy is the only thing that reads slightly off.
        ProcessSelector(displayName: "FaceTime", bundlePrefix: "com.apple.FaceTime"),
        // Not scopeable: the audio behind a FaceTime call is played by Apple's
        // AV conferencing daemon, not by a process a per-app scope has been
        // verified to tap. Until that measurement lands, a call attributed here
        // runs as an honest Everything — flip this to true the day it does.
        ProcessSelector(
            displayName: "FaceTime",
            bundlePrefix: "com.apple.avconferenced",
            scopeable: false
        ),
        ProcessSelector(displayName: "Webex", bundlePrefix: "Cisco-Systems.Spark"),
        ProcessSelector(displayName: "Google Chrome", bundlePrefix: "com.google.Chrome"),
        ProcessSelector(displayName: "Microsoft Edge", bundlePrefix: "com.microsoft.edgemac"),
        ProcessSelector(displayName: "Brave", bundlePrefix: "com.brave.Browser"),
        ProcessSelector(displayName: "Arc", bundlePrefix: "company.thebrowser.Browser"),
        ProcessSelector(displayName: "Firefox", bundlePrefix: "org.mozilla.firefox"),
        ProcessSelector(displayName: "Safari", bundlePrefix: "com.apple.Safari"),
        // WebKit runs media capture in its GPU process, so a Meet call in
        // Safari can surface under this identity rather than Safari's own
        // (verified against the DEBUG detection log during build).
        ProcessSelector(displayName: "Safari", bundlePrefix: "com.apple.WebKit.GPU"),
    ]

    /// The app a capturing process belongs to, or `nil` for everything else —
    /// the deliberate silence that keeps dictation and voice memos from ever
    /// raising the island.
    ///
    /// Two tiers. The curated table above is consulted first, so the native
    /// meeting apps, Echo's long-standing display names and the one browser
    /// process that lives outside its app bundle (Safari's WebKit GPU process)
    /// all keep resolving exactly as before. `browsers` — every browser
    /// installed on this Mac, from `BrowserCatalog` — is the fallback, and it
    /// is what makes a Meet call in a browser nobody hardcoded detectable.
    /// Empty by default so the matcher stays pure and table-testable; the
    /// detection path passes the live set.
    public static func match(
        bundleID: String,
        appBundleID: String = "",
        browsers: [ProcessSelector] = []
    ) -> ProcessSelector? {
        apps.first { $0.matches(bundleID: bundleID, appBundleID: appBundleID) }
            ?? browsers.first { $0.matches(bundleID: bundleID, appBundleID: appBundleID) }
    }

    /// The apps behind a set of mic clients: deduped, in catalog order, so
    /// attribution is deterministic when several apps capture at once.
    ///
    /// `disabledNames` drops apps the user excluded in Settings — filtered
    /// HERE, the single matcher call site, so a disabled app is invisible
    /// everywhere downstream (island, scope dropdown, auto-scope). Names, not
    /// prefixes: one display name covers all of an app's catalog prefixes, and
    /// a stale name (the catalog renamed the app) is harmlessly ignored
    /// because nothing matches it.
    ///
    /// `browsers` is the installed-browser tier, ordered after the curated
    /// table so a Zoom call in front of an open browser tab is still
    /// attributed to Zoom. A browser the curated table already names resolves
    /// to the curated entry, so it can never appear twice.
    ///
    /// What this returns IS what feeds the machine's `matchedAppsChanged`.
    public static func matchedApps(
        from clients: [MicCaptureClient],
        disabledNames: Set<String> = [],
        browsers: [ProcessSelector] = []
    ) -> [ProcessSelector] {
        let matched = Set(
            clients.compactMap {
                match(bundleID: $0.bundleID, appBundleID: $0.appBundleID, browsers: browsers)
            }
        )
        var seen = Set<ProcessSelector>()
        return (apps + browsers).filter {
            seen.insert($0).inserted
                && matched.contains($0)
                && !disabledNames.contains($0.displayName)
        }
    }

    /// Every app detection can name, in order of first appearance — the
    /// Settings page's per-app rows. One row per app: a name owning several
    /// prefixes (Teams, FaceTime, Safari) appears once and disabling it covers
    /// all of them, and an installed browser the curated table already names
    /// (Chrome, Safari) does not get a second row.
    ///
    /// `browsers` is the same live set the matcher takes, so every browser
    /// that can raise the island has a checkbox that silences it.
    public static func detectableDisplayNames(browsers: [ProcessSelector] = []) -> [String] {
        var seen = Set<String>()
        return (apps + browsers).compactMap {
            seen.insert($0.displayName).inserted ? $0.displayName : nil
        }
    }

    /// The curated table's own display names — `detectableDisplayNames()` with
    /// no browsers.
    public static var uniqueDisplayNames: [String] { detectableDisplayNames() }
}
