//
//  CallAppCatalog.swift
//  Echo
//
//  SP-006 / ADR-017: the curated set of apps whose microphone capture means
//  "the user is probably in a call". Detection is deliberately NOT "any app
//  that touches the mic" — dictation, voice memos and voice assistants must
//  never raise the island, so only catalogued bundle IDs match.
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

    /// The bundle-ID prefix this app is recognised by — see `matches(bundleID:)`.
    let bundlePrefix: String

    /// Exact match, or the prefix followed by a `.` so helper processes
    /// attribute to their parent app (`com.google.Chrome.helper` → Chrome)
    /// while neighbouring identifiers do not (`com.google.Chromecast`,
    /// `com.google.Chromium`).
    ///
    /// Case-sensitive: bundle IDs are compared as Core Audio reports them.
    /// An empty bundle ID — daemons and unbundled processes, for which
    /// `kAudioProcessPropertyBundleID` yields nothing — never matches, so a
    /// nameless capture can never be read as a call.
    func matches(bundleID: String) -> Bool {
        guard !bundleID.isEmpty else { return false }
        return bundleID == bundlePrefix || bundleID.hasPrefix(bundlePrefix + ".")
    }
}

/// The shipped catalog (ADR-017: it lives in code; growing it is a code
/// change, and a user-editable list is a future spec).
///
/// Browsers are included because Meet-in-a-browser is a primary meeting
/// surface; the accepted cost is that non-call browser mic use (voice search)
/// can offer to record. The island is dismissible and never records on its own,
/// so the worst case is one ignored prompt.
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
        // FaceTime is here for completeness, but on macOS 26 it never captures
        // in its own process, so in practice it never matches. SP-006 open
        // question 1, resolved against real calls 2026-08-04: the process that
        // does capture is `com.apple.avconferenced`, and that daemon is NOT
        // catalogued on purpose — it was observed holding the microphone for 18
        // minutes across three unrelated app tests with no FaceTime call in
        // sight. Cataloguing it would mean a permanent "FaceTime call detected"
        // island (ADR-017's rejected false-positive class) and, worse, a
        // permanent call that masks every real one after it. FaceTime is
        // therefore a known detection gap, not a supported app.
        CallApp(displayName: "FaceTime", bundlePrefix: "com.apple.FaceTime"),
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

    /// The catalogued app this bundle ID belongs to, or `nil` for everything
    /// else — the deliberate silence that keeps dictation and voice memos from
    /// ever raising the island.
    static func match(bundleID: String) -> CallApp? {
        apps.first { $0.matches(bundleID: bundleID) }
    }
}
