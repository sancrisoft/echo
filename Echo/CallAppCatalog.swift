//
//  CallAppCatalog.swift
//  Echo
//
//  SP-006 / ADR-017: the set of apps whose microphone capture means "the user
//  is probably in a call". Detection is deliberately NOT "any app that touches
//  the mic" — dictation, voice memos and voice assistants must never raise the
//  island.
//
//  Two tiers meet in `match`: the curated table in this file (native meeting
//  apps, plus the browser processes that need naming by hand), and every
//  browser installed on this Mac, asked of the system by `BrowserCatalog`.
//  The second tier is why a Meet call in a browser nobody hardcoded is
//  detected; the first is why the curated names and near-miss exclusions still
//  hold.
//
//  Pure and table-tested. The Core Audio side (`MicActivityMonitor`) reports
//  raw (pid, bundleID) mic clients and never decides what they mean; matching
//  and every timing rule live here and in `CallSessionMachine`.
//

/// A meeting app (or a browser hosting one) whose mic capture means the user
/// is probably in a call (ADR-017).
nonisolated struct CallApp: Equatable, Hashable, Sendable {

    /// Island copy: "Zoom call detected".
    let displayName: String

    /// The bundle-ID prefix this app is recognised by — see
    /// `matches(bundleID:appBundleID:)`.
    let bundlePrefix: String

    /// SP-008: whether a recording session can honestly narrow its system
    /// channel to this app — i.e. whether the processes this entry matches are
    /// the ones that actually *play* the call's audio. When false, the island
    /// offers a plain global recording instead of naming the app (open
    /// question 3's settled policy: an unscopeable app runs as an honest
    /// Everything, never a scope the tap can't deliver).
    let scopeable: Bool

    init(displayName: String, bundlePrefix: String, scopeable: Bool = true) {
        self.displayName = displayName
        self.bundlePrefix = bundlePrefix
        self.scopeable = scopeable
    }

    /// Whether a process belongs to this app, judged on both identities the
    /// capture layers can read: the bundle ID Core Audio reports for the
    /// process itself, and `appBundleID` — the bundle ID of the outermost
    /// `.app` its executable lives in (`AppBundleIdentity`).
    ///
    /// The bundle ID alone is enough for Chromium-shaped apps, whose helpers
    /// carry the parent's prefix (`com.google.Chrome.helper` → Chrome), and it
    /// is what keeps neighbours out (`com.google.Chromecast`,
    /// `com.google.Chromium`). It is *not* enough for Gecko-shaped ones: a
    /// Firefox or Zen media process is `org.mozilla.plugincontainer` /
    /// `app.zen-browser.plugincontainer`, sharing no prefix with the browser
    /// the user launched — those attribute through the app bundle they live
    /// in, which is why `appBundleID` exists.
    ///
    /// Case-sensitive: identifiers are compared as the system reports them.
    /// Both being empty — daemons and unbundled processes, for which
    /// `kAudioProcessPropertyBundleID` yields nothing and no `.app` encloses
    /// the executable — never matches, so a nameless capture can never be read
    /// as a call.
    func matches(bundleID: String, appBundleID: String = "") -> Bool {
        matches(identifier: bundleID) || matches(identifier: appBundleID)
    }

    private func matches(identifier: String) -> Bool {
        guard !identifier.isEmpty else { return false }
        return identifier == bundlePrefix || identifier.hasPrefix(bundlePrefix + ".")
    }
}

/// The curated tier (ADR-017: it lives in code; growing it is a code change,
/// and a user-editable list is a future spec).
///
/// Browsers appear here as well as in `BrowserCatalog` — the curated entries
/// keep the display names Echo has always shown ("Brave", not "Brave
/// Browser") and cover the one browser process that lives outside its app
/// bundle, Safari's WebKit GPU process. The accepted cost of detecting
/// browsers at all is that non-call browser mic use (voice search) can offer
/// to record. The island is dismissible and never records on its own, so the
/// worst case is one ignored prompt.
nonisolated enum CallAppCatalog {

    /// Order is the attribution order: with several catalogued processes
    /// capturing at once, the first match in this table names the island.
    /// Native meeting apps come before browsers so a Zoom call in front of an
    /// open browser tab is attributed to Zoom.
    static let apps: [CallApp] = [
        CallApp(displayName: "Zoom", bundlePrefix: "us.zoom.xos"),
        CallApp(displayName: "Microsoft Teams", bundlePrefix: "com.microsoft.teams2"),
        CallApp(displayName: "Microsoft Teams", bundlePrefix: "com.microsoft.teams"),
        CallApp(displayName: "Slack", bundlePrefix: "com.tinyspeck.slackmacgap"),
        CallApp(displayName: "Discord", bundlePrefix: "com.hnc.Discord"),
        // SP-006 open question 1, resolved by measuring real calls: FaceTime
        // never captures in its own process (`com.apple.FaceTime` stays at
        // is-running-input 0, is-running 0, even mid-call). The process that
        // does is Apple's AV conferencing daemon, and it tracks the call
        // faithfully — measured going quiet within two seconds of hanging up.
        //
        // A longer hold across other apps' tests looked at first like a daemon
        // that never lets go; it was a FaceTime call left connected in the
        // background. Both entries stay: the app for macOS versions that
        // capture in-process, the daemon for the ones that don't. Other Apple
        // conferencing surfaces (an iPhone call relayed to the Mac) share the
        // daemon, so they attribute here too — they are calls as well, and the
        // island's copy is the only thing that reads slightly off.
        CallApp(displayName: "FaceTime", bundlePrefix: "com.apple.FaceTime"),
        // Not scopeable (SP-008): the audio behind a FaceTime call is played
        // by Apple's AV conferencing daemon, not by a process a per-app scope
        // has been verified to tap. Until the build-phase measurement proves
        // the daemon's output audio taps correctly, a call attributed here
        // runs as an honest Everything (open question 3's policy) — flip this
        // to true the day the measurement lands.
        CallApp(displayName: "FaceTime", bundlePrefix: "com.apple.avconferenced", scopeable: false),
        CallApp(displayName: "Webex", bundlePrefix: "Cisco-Systems.Spark"),
        CallApp(displayName: "Google Chrome", bundlePrefix: "com.google.Chrome"),
        CallApp(displayName: "Microsoft Edge", bundlePrefix: "com.microsoft.edgemac"),
        CallApp(displayName: "Brave", bundlePrefix: "com.brave.Browser"),
        CallApp(displayName: "Arc", bundlePrefix: "company.thebrowser.Browser"),
        CallApp(displayName: "Firefox", bundlePrefix: "org.mozilla.firefox"),
        CallApp(displayName: "Safari", bundlePrefix: "com.apple.Safari"),
        // WebKit runs media capture in its GPU process, so a Meet call in
        // Safari can surface under this identity rather than Safari's own
        // (verified against the DEBUG detection log during build).
        CallApp(displayName: "Safari", bundlePrefix: "com.apple.WebKit.GPU"),
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
    static func match(
        bundleID: String,
        appBundleID: String = "",
        browsers: [CallApp] = []
    ) -> CallApp? {
        apps.first { $0.matches(bundleID: bundleID, appBundleID: appBundleID) }
            ?? browsers.first { $0.matches(bundleID: bundleID, appBundleID: appBundleID) }
    }

    /// Every app detection can name, in order of first appearance — the
    /// Settings page's per-app rows. One row per app: a name owning several
    /// prefixes (Teams, FaceTime, Safari) appears once and disabling it covers
    /// all of them, and an installed browser the curated table already names
    /// (Chrome, Safari) does not get a second row.
    ///
    /// `browsers` is the same live set the matcher takes, so every browser
    /// that can raise the island has a checkbox that silences it.
    static func detectableDisplayNames(browsers: [CallApp] = []) -> [String] {
        var seen = Set<String>()
        return (apps + browsers).compactMap {
            seen.insert($0.displayName).inserted ? $0.displayName : nil
        }
    }

    /// The curated table's own display names — `detectableDisplayNames()` with
    /// no browsers.
    static var uniqueDisplayNames: [String] { detectableDisplayNames() }
}
