//
//  DataRoot.swift
//  EchoCore
//
//  The single root for everything Echo writes to disk. Uninstalling the app
//  must be "delete Echo.app + delete ~/Library/Application Support/Echo": no
//  UserDefaults, no ~/Documents, no caches anywhere else.
//
//  No accessor here creates a directory. The package that owns a subtree
//  creates it when it first writes (the meeting store creates `Meetings/`, the
//  error log creates `Logs/`, …), which keeps this type side-effect free and
//  keeps tests able to point at a temporary root without touching disk.
//

import Foundation

public struct DataRoot: Hashable, Sendable {

    /// The root folder itself.
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// `~/Library/Application Support/Echo` — the one folder v1 and v2 share
    /// (ADR-005).
    public static let standard = DataRoot(
        url: FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Echo", directoryHint: .isDirectory)
    )

    /// One subfolder per saved meeting.
    public var meetings: URL {
        url.appending(path: "Meetings", directoryHint: .isDirectory)
    }

    /// Download base for every on-device model.
    public var models: URL {
        url.appending(path: "Models", directoryHint: .isDirectory)
    }

    /// The error trace log, one NDJSON file per UTC day.
    public var logs: URL {
        url.appending(path: "Logs", directoryHint: .isDirectory)
    }

    /// Persisted preferences (`AppSettings`).
    public var settingsFile: URL {
        url.appending(path: "settings.json", directoryHint: .notDirectory)
    }

    /// The persisted "the user paused the summary-model download" intent.
    public var summaryDownloadStateFile: URL {
        url.appending(path: "summary-download-state.json", directoryHint: .notDirectory)
    }
}
