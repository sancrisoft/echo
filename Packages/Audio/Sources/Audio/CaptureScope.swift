//
//  CaptureScope.swift
//  Audio
//
//  A recording session's system-channel coverage. The microphone channel is
//  always the user, recorded whole; scope narrows only what the *system* tap
//  hears — everything the Mac plays, or one app resolved to its process set.
//
//  Pure and table-tested. Which surface picks which scope (island → detected
//  app, window → everything) and what happens when a scoped start fails (the
//  visible collapse to global) are decided in Recording; this type only names
//  the choice.
//

/// An app the system tap can be narrowed to, as the capture layer needs to
/// know it: a name for the surfaces, and the bundle-ID prefix its processes
/// are recognised by.
///
/// This is the capture-side half of what v1 carried as `CallApp`. Detection
/// owns the catalogs and the timing, and `CallDetection` sits *above* this
/// package, so a scoped session is described by a selector Audio defines and
/// detection maps onto — the matcher itself stays one implementation, here,
/// so detection and scoping can never disagree about what an app is.
public struct ProcessSelector: Equatable, Hashable, Sendable {

    /// The app's display name, as the surfaces name it ("Zoom").
    public let displayName: String

    /// The bundle-ID prefix this app is recognised by — see
    /// `matches(bundleID:appBundleID:)`.
    public let bundlePrefix: String

    /// Whether a recording session can honestly narrow its system channel to
    /// this app — i.e. whether the processes this selector matches are the
    /// ones that actually *play* the app's audio. When false, the caller
    /// records a plain global session instead of naming the app: an
    /// unscopeable app runs as an honest "Everything", never as a scope the
    /// tap cannot deliver.
    public let scopeable: Bool

    public init(displayName: String, bundlePrefix: String, scopeable: Bool = true) {
        self.displayName = displayName
        self.bundlePrefix = bundlePrefix
        self.scopeable = scopeable
    }

    /// Whether a process belongs to this app, judged on both identities the
    /// capture layer can read: the bundle ID Core Audio reports for the
    /// process itself, and `appBundleID` — the bundle ID of the outermost
    /// `.app` its executable lives in (`AppBundleIdentity`).
    ///
    /// The bundle ID alone is enough for Chromium-shaped apps, whose helpers
    /// carry the parent's prefix (`com.google.Chrome.helper` → Chrome), and
    /// it is what keeps neighbours out (`com.google.Chromecast`,
    /// `com.google.Chromium`). It is *not* enough for Gecko-shaped ones: a
    /// Firefox or Zen media process is `org.mozilla.plugincontainer` /
    /// `app.zen-browser.plugincontainer`, sharing no prefix with the browser
    /// the user launched — those attribute through the app bundle they live
    /// in, which is why `appBundleID` exists.
    ///
    /// Case-sensitive: identifiers are compared as the system reports them.
    /// Both being empty — daemons and unbundled processes, for which
    /// `kAudioProcessPropertyBundleID` yields nothing and no `.app` encloses
    /// the executable — never matches, so a nameless process can never join a
    /// scoped tap.
    public func matches(bundleID: String, appBundleID: String = "") -> Bool {
        matches(identifier: bundleID) || matches(identifier: appBundleID)
    }

    private func matches(identifier: String) -> Bool {
        guard !identifier.isEmpty else { return false }
        return identifier == bundlePrefix || identifier.hasPrefix(bundlePrefix + ".")
    }
}

/// What the system-audio channel covers for one recording session.
public enum CaptureScope: Equatable, Sendable {

    /// All system audio — the global tap, byte-for-byte.
    case everything

    /// Only the given app: every process object whose bundle ID the selector
    /// matches, followed as helpers appear and vanish.
    case app(ProcessSelector)

    /// The app a scoped session narrows to, `nil` for a global session —
    /// what the capture layer resolves to a process set.
    public var scopedApp: ProcessSelector? {
        switch self {
        case .everything:
            return nil
        case .app(let app):
            return app
        }
    }
}
