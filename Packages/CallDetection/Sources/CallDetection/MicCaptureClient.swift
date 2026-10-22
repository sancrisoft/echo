//
//  MicCaptureClient.swift
//  CallDetection
//
//  One process capturing microphone input right now, as the Core Audio shim
//  reports it and as the catalog reads it. A value type rather than a nested
//  one so the pure half of this package — catalog, filter, machine — is
//  complete and testable without the monitor that produces it.
//

import Foundation

/// A process holding the microphone. `bundleID` is empty for daemons and
/// unbundled processes, which is why an empty identity can never match the
/// catalog.
public struct MicCaptureClient: Hashable, Sendable {

    public var pid: pid_t

    /// The bundle ID Core Audio reports for the process itself.
    public var bundleID: String

    /// The second identity: the bundle ID of the outermost `.app` the
    /// process's executable lives in (`Audio.AppBundleIdentity`), which is how
    /// a browser helper that shares no bundle prefix with its parent —
    /// Firefox's and Zen's `plugincontainer` — still attributes to the browser
    /// the user launched. Empty when no `.app` encloses the executable.
    public var appBundleID: String

    public init(pid: pid_t, bundleID: String, appBundleID: String = "") {
        self.pid = pid
        self.bundleID = bundleID
        self.appBundleID = appBundleID
    }
}
