//
//  ScopedProcessResolution.swift
//  Echo
//
//  SP-008 / ADR-026: which Core Audio process objects a scoped tap includes,
//  and when a live tap's include set must change. The identity is the app's
//  bundle prefix, matched against both the process's own bundle ID and the app
//  bundle its executable lives in — resolved through
//  `CallApp.matches(bundleID:appBundleID:)`, the same pure matcher detection
//  uses, so detection and scoping can never disagree about what an app is.
//  Never a PID, which would miss every helper-process architecture (Chrome's
//  audio service, Zoom's aomhost, WebKit's GPU process) — and never the bundle
//  ID alone, which would miss the Gecko browsers whose media process shares no
//  prefix with its parent.
//
//  Pure and table-tested. The Core Audio side (`SystemAudioCapture`) only
//  enumerates processes and applies the sets decided here; every inclusion
//  and follow rule lives in this file.
//

import CoreAudio

/// Resolves a scoped session's app to its current process objects and decides
/// when the live tap's include set needs updating (ADR-026).
nonisolated enum ScopedProcessResolution {

    /// One process object as the audio server reports it. Both identities are
    /// empty for daemons and unbundled processes — which never match any app,
    /// so a nameless process can never join a scoped tap. `appBundleID` is the
    /// bundle ID of the outermost `.app` the process's executable lives in
    /// (`AppBundleIdentity`).
    struct ProcessEntry: Hashable, Sendable {
        var object: AudioObjectID
        var bundleID: String
        var appBundleID: String = ""
    }

    /// Every process object belonging to `app` — exact bundle ID, a helper
    /// carrying the app's prefix, or a helper living inside the app's bundle
    /// (`CallApp.matches`). Empty is legal, not a failure: an app with no live
    /// audio processes taps nothing and the system channel records silence
    /// (ADR-026).
    static func includeSet(for app: CallApp, in processes: [ProcessEntry]) -> Set<AudioObjectID> {
        Set(
            processes
                .filter { app.matches(bundleID: $0.bundleID, appBundleID: $0.appBundleID) }
                .map(\.object)
        )
    }

    /// Whether a process-list change requires updating the live tap.
    ///
    /// `nil` means the tap's current include set is already the truth — the
    /// change was unrelated churn — and no property write should happen; the
    /// scoped tap is touched on set changes only, never per notification
    /// (SP-008 performance NFR). Non-nil is the exact new set to apply,
    /// including the empty set when the app fully exits: that is silence,
    /// not failure, and the app's relaunch grows the set right back.
    static func followUpdate(
        for app: CallApp,
        current: Set<AudioObjectID>,
        processes: [ProcessEntry]
    ) -> Set<AudioObjectID>? {
        let resolved = includeSet(for: app, in: processes)
        return resolved == current ? nil : resolved
    }
}
