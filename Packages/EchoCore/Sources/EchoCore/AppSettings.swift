//
//  AppSettings.swift
//  EchoCore
//
//  Small, persisted preferences that must survive relaunch but are not meeting
//  data. Stored as `settings.json` under the data root — never UserDefaults
//  (uninstall == delete the app + the folder).
//
//  Kept deliberately tiny: one Codable payload, loaded once at construction and
//  rewritten atomically on change. Add fields to `Stored` with defaults so old
//  files keep decoding, and add a `decodeIfPresent` line for each — see the
//  note on `Stored.init(from:)` for why the synthesized decoder is not used.
//

import Foundation
import Observation

@Observable
@MainActor
public final class AppSettings {

    /// The on-disk payload. Every field defaults so a missing key (older file,
    /// or none at all) decodes cleanly.
    private struct Stored: Codable {
        var privacyBannerDismissed = false
        var callDetectionEnabled = true
        var keepRecordingsAfterTranscription = false
        var autoGenerateSummaries = true
        var disabledCallApps: [String] = []
        var checkForUpdatesAutomatically = true
        var hasLaunchedBefore = false
        var showsIsland = true
        var lastOpenMeeting: UUID?
        var hasRequestedSystemAudio = false
        var hasLeftWelcome = false

        init() {}

        /// Decodes key by key so an absent one keeps its default. Swift's
        /// synthesized decoder throws `keyNotFound` instead, which would drop
        /// the *whole* file back to defaults the first time a field is added —
        /// silently resetting settings the user already chose (adding
        /// `callDetectionEnabled` would have un-dismissed every existing
        /// user's privacy banner).
        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let defaults = Stored()
            privacyBannerDismissed =
                try container.decodeIfPresent(Bool.self, forKey: .privacyBannerDismissed)
                ?? defaults.privacyBannerDismissed
            callDetectionEnabled =
                try container.decodeIfPresent(Bool.self, forKey: .callDetectionEnabled)
                ?? defaults.callDetectionEnabled
            keepRecordingsAfterTranscription =
                try container.decodeIfPresent(Bool.self, forKey: .keepRecordingsAfterTranscription)
                ?? defaults.keepRecordingsAfterTranscription
            autoGenerateSummaries =
                try container.decodeIfPresent(Bool.self, forKey: .autoGenerateSummaries)
                ?? defaults.autoGenerateSummaries
            disabledCallApps =
                try container.decodeIfPresent([String].self, forKey: .disabledCallApps)
                ?? defaults.disabledCallApps
            checkForUpdatesAutomatically =
                try container.decodeIfPresent(Bool.self, forKey: .checkForUpdatesAutomatically)
                ?? defaults.checkForUpdatesAutomatically
            hasLaunchedBefore =
                try container.decodeIfPresent(Bool.self, forKey: .hasLaunchedBefore)
                ?? defaults.hasLaunchedBefore
            showsIsland =
                try container.decodeIfPresent(Bool.self, forKey: .showsIsland)
                ?? defaults.showsIsland
            lastOpenMeeting =
                try container.decodeIfPresent(UUID.self, forKey: .lastOpenMeeting)
                ?? defaults.lastOpenMeeting
            hasRequestedSystemAudio =
                try container.decodeIfPresent(Bool.self, forKey: .hasRequestedSystemAudio)
                ?? defaults.hasRequestedSystemAudio
            hasLeftWelcome =
                try container.decodeIfPresent(Bool.self, forKey: .hasLeftWelcome)
                ?? defaults.hasLeftWelcome
        }
    }

    /// Whether the user closed the "Everything stays on this Mac" banner. Once
    /// dismissed it never shows again.
    public private(set) var privacyBannerDismissed: Bool

    /// Whether Echo offers to record when it detects a call. Off means off:
    /// the mic-activity monitor is stopped, the island is hidden and every
    /// pending timer is cancelled.
    public private(set) var callDetectionEnabled: Bool

    /// Whether a successful transcription pass keeps the meeting's audio in its
    /// folder (renamed to the preserved `audio-*` names) instead of deleting
    /// it. Future-only: flipping it off never deletes recordings already
    /// preserved — space is reclaimed through the explicit delete actions.
    public private(set) var keepRecordingsAfterTranscription: Bool

    /// Whether summaries generate on their own (post-stop and the backfill
    /// scan). Off still honors an explicit "Generate summary" request, and
    /// never gates model downloads.
    public private(set) var autoGenerateSummaries: Bool

    /// Call-app display names the user excluded from call detection. Stored
    /// sorted for stable JSON. Names, not bundle prefixes: the catalog stays
    /// the only prefix authority, and one name covers all of an app's prefixes.
    /// A name the catalog no longer carries is harmlessly ignored.
    public private(set) var disabledCallApps: [String]

    /// Whether Echo asks GitHub once a day for the latest release. Off means no
    /// request leaves the app until the user clicks Check for Updates.
    public private(set) var checkForUpdatesAutomatically: Bool

    /// Whether Echo has ever launched on this Mac. False exactly once, and the
    /// one launch that puts the window on screen by itself: a fresh install is
    /// otherwise a menu bar icon, an island hiding in the cutout, and nothing
    /// else to find. A settings file written before this key existed reads as
    /// false too, so an install that predates it gets that one window as well —
    /// the same promise, one launch late.
    public private(set) var hasLaunchedBefore: Bool

    /// Whether the island is on screen. On by default, and for every screen at
    /// once (DEC-1, product owner 2026-10-02). Off takes the panel away and
    /// nothing else: call detection keeps running, and the menu bar item says
    /// what the island would have said.
    public private(set) var showsIsland: Bool

    /// The meeting the window last showed, so the window opens on it after a
    /// relaunch (product owner, 2026-10-02). Navigation rather than a
    /// preference, but it has to outlive the process, and this is the one
    /// small file that does. `nil` until a meeting has been open; one that
    /// has since gone is the window's to step past.
    public private(set) var lastOpenMeeting: UUID?

    /// Whether Echo has ever asked macOS to let it hear the Mac's audio. The
    /// permission cannot be read without asking — the check that reads it is
    /// the request that raises the dialog — so this is what tells a check
    /// that it may run without putting a dialog in front of someone who never
    /// pressed anything. Echo's own record, not macOS's: a rebuilt Echo is
    /// asked again by macOS, and its check then raises the dialog once more.
    public private(set) var hasRequestedSystemAudio: Bool

    /// Whether the user has left the welcome screen, by Start using Echo or
    /// Record without notes. Until then the welcome comes back at each launch
    /// on which the models are not both on disk (product owner, 2026-10-19).
    public private(set) var hasLeftWelcome: Bool

    @ObservationIgnored private let fileURL: URL

    /// Loads the preferences from `fileURL`, falling back to defaults when the
    /// file is missing or unreadable.
    public init(fileURL: URL) {
        self.fileURL = fileURL
        let stored = Self.load(from: fileURL)
        self.privacyBannerDismissed = stored.privacyBannerDismissed
        self.callDetectionEnabled = stored.callDetectionEnabled
        self.keepRecordingsAfterTranscription = stored.keepRecordingsAfterTranscription
        self.autoGenerateSummaries = stored.autoGenerateSummaries
        self.disabledCallApps = stored.disabledCallApps
        self.checkForUpdatesAutomatically = stored.checkForUpdatesAutomatically
        self.hasLaunchedBefore = stored.hasLaunchedBefore
        self.showsIsland = stored.showsIsland
        self.lastOpenMeeting = stored.lastOpenMeeting
        self.hasRequestedSystemAudio = stored.hasRequestedSystemAudio
        self.hasLeftWelcome = stored.hasLeftWelcome
    }

    /// The app's preferences, at the data root's `settings.json`.
    public convenience init(dataRoot: DataRoot) {
        self.init(fileURL: dataRoot.settingsFile)
    }

    /// Permanently dismisses the privacy banner and persists the change.
    public func dismissPrivacyBanner() {
        guard !privacyBannerDismissed else { return }
        privacyBannerDismissed = true
        persist()
    }

    /// Turns call detection on or off and persists the change.
    public func setCallDetection(enabled: Bool) {
        guard callDetectionEnabled != enabled else { return }
        callDetectionEnabled = enabled
        persist()
    }

    /// Turns recording preservation on or off and persists the change.
    public func setKeepRecordings(enabled: Bool) {
        guard keepRecordingsAfterTranscription != enabled else { return }
        keepRecordingsAfterTranscription = enabled
        persist()
    }

    /// Turns automatic summary generation on or off and persists the change.
    public func setAutoGenerateSummaries(enabled: Bool) {
        guard autoGenerateSummaries != enabled else { return }
        autoGenerateSummaries = enabled
        persist()
    }

    /// Includes or excludes one call app (by display name) from detection and
    /// persists the change.
    public func setCallApp(_ displayName: String, enabled: Bool) {
        var updated = Set(disabledCallApps)
        if enabled {
            updated.remove(displayName)
        } else {
            updated.insert(displayName)
        }
        let sorted = updated.sorted()
        guard sorted != disabledCallApps else { return }
        disabledCallApps = sorted
        persist()
    }

    /// Turns the daily update check on or off and persists the change.
    public func setCheckForUpdates(automatically enabled: Bool) {
        guard checkForUpdatesAutomatically != enabled else { return }
        checkForUpdatesAutomatically = enabled
        persist()
    }

    /// Records that Echo has launched, and persists the change. One-way, like
    /// the privacy banner: nothing ever unsets it.
    public func noteLaunched() {
        guard !hasLaunchedBefore else { return }
        hasLaunchedBefore = true
        persist()
    }

    /// Shows or hides the island and persists the change.
    public func setShowsIsland(_ shown: Bool) {
        guard showsIsland != shown else { return }
        showsIsland = shown
        persist()
    }

    /// Records the meeting the window shows and persists it.
    public func noteOpenMeeting(_ id: UUID) {
        guard lastOpenMeeting != id else { return }
        lastOpenMeeting = id
        persist()
    }

    /// Records that Echo has asked for System Audio Recording, and persists
    /// it. One-way: an asked question stays asked.
    public func noteRequestedSystemAudio() {
        guard !hasRequestedSystemAudio else { return }
        hasRequestedSystemAudio = true
        persist()
    }

    /// Records that the user left the welcome screen, and persists it.
    /// One-way: the welcome never comes back once left.
    public func noteLeftWelcome() {
        guard !hasLeftWelcome else { return }
        hasLeftWelcome = true
        persist()
    }

    private static func load(from url: URL) -> Stored {
        guard let data = try? Data(contentsOf: url) else { return Stored() }
        do {
            return try JSONDecoder().decode(Stored.self, from: data)
        } catch {
            ErrorTrace.record("Reading settings failed, using defaults", error: error, category: "AppSettings")
            return Stored()
        }
    }

    private func persist() {
        var stored = Stored()
        stored.privacyBannerDismissed = privacyBannerDismissed
        stored.callDetectionEnabled = callDetectionEnabled
        stored.keepRecordingsAfterTranscription = keepRecordingsAfterTranscription
        stored.autoGenerateSummaries = autoGenerateSummaries
        stored.disabledCallApps = disabledCallApps
        stored.checkForUpdatesAutomatically = checkForUpdatesAutomatically
        stored.hasLaunchedBefore = hasLaunchedBefore
        stored.showsIsland = showsIsland
        stored.lastOpenMeeting = lastOpenMeeting
        stored.hasRequestedSystemAudio = hasRequestedSystemAudio
        stored.hasLeftWelcome = hasLeftWelcome
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
            try encoder.encode(stored).write(to: fileURL, options: .atomic)
        } catch {
            ErrorTrace.record("Writing settings failed", error: error, category: "AppSettings")
        }
    }
}
