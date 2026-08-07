//
//  AppSettings.swift
//  Echo
//
//  Small, persisted UI state that must survive relaunch but is not meeting
//  data. Stored as `settings.json` under the single data root — never
//  UserDefaults (2026-07-13 decision: uninstall == delete the app + the folder).
//
//  Kept deliberately tiny: one Codable payload, loaded once at construction and
//  rewritten atomically on change. Add fields to `Stored` with defaults so old
//  files keep decoding.
//

import Foundation
import Observation

@Observable
@MainActor
final class AppSettings {

    /// The on-disk payload. Every field defaults so a missing key (older file,
    /// or none at all) decodes cleanly.
    private struct Stored: Codable {
        var privacyBannerDismissed = false
        var callDetectionEnabled = true
        var keepRecordingsAfterTranscription = false
        var autoGenerateSummaries = true
        var disabledCallApps: [String] = []

        init() {}

        /// Decodes key by key so an absent one keeps its default. Swift's
        /// synthesized decoder throws `keyNotFound` instead, which would drop
        /// the *whole* file back to defaults the first time a field is added —
        /// silently resetting settings the user already chose (SP-006 found
        /// this: adding `callDetectionEnabled` would have un-dismissed every
        /// existing user's privacy banner).
        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let defaults = Stored()
            privacyBannerDismissed = try container.decodeIfPresent(
                Bool.self, forKey: .privacyBannerDismissed
            ) ?? defaults.privacyBannerDismissed
            callDetectionEnabled = try container.decodeIfPresent(
                Bool.self, forKey: .callDetectionEnabled
            ) ?? defaults.callDetectionEnabled
            keepRecordingsAfterTranscription = try container.decodeIfPresent(
                Bool.self, forKey: .keepRecordingsAfterTranscription
            ) ?? defaults.keepRecordingsAfterTranscription
            autoGenerateSummaries = try container.decodeIfPresent(
                Bool.self, forKey: .autoGenerateSummaries
            ) ?? defaults.autoGenerateSummaries
            disabledCallApps = try container.decodeIfPresent(
                [String].self, forKey: .disabledCallApps
            ) ?? defaults.disabledCallApps
        }
    }

    /// Whether the user closed the "Everything stays on this Mac" banner. Once
    /// dismissed it never shows again. Read-only to callers — mutate through
    /// `dismissPrivacyBanner()` so the write to disk can't be forgotten.
    private(set) var privacyBannerDismissed: Bool

    /// Whether Echo offers to record when it detects a call (SP-006). On by
    /// default, and off means off: the mic-activity monitor is stopped, the
    /// island is hidden and every pending timer is cancelled.
    private(set) var callDetectionEnabled: Bool

    /// Whether a successful final pass keeps the meeting's audio in its
    /// folder (renamed to the preserved `audio-*` names) instead of deleting
    /// it. Future-only: flipping it off never deletes recordings already
    /// preserved — space is reclaimed through the explicit delete actions.
    private(set) var keepRecordingsAfterTranscription: Bool

    /// Whether summaries generate on their own (post-stop and the backfill
    /// scan). Off still honors an explicit "Generate summary" request, and
    /// never gates model downloads.
    private(set) var autoGenerateSummaries: Bool

    /// `CallApp.displayName` values the user excluded from call detection.
    /// Stored sorted for stable JSON. Names, not bundle prefixes: the catalog
    /// stays the only prefix authority, and one name covers all of an app's
    /// prefixes. A name the catalog no longer carries is harmlessly ignored.
    private(set) var disabledCallApps: [String]

    @ObservationIgnored private let fileURL: URL

    init(fileURL: URL = EchoPaths.settingsFile) {
        self.fileURL = fileURL
        let stored = Self.load(from: fileURL)
        self.privacyBannerDismissed = stored.privacyBannerDismissed
        self.callDetectionEnabled = stored.callDetectionEnabled
        self.keepRecordingsAfterTranscription = stored.keepRecordingsAfterTranscription
        self.autoGenerateSummaries = stored.autoGenerateSummaries
        self.disabledCallApps = stored.disabledCallApps
    }

    /// Permanently dismisses the privacy banner and persists the change.
    func dismissPrivacyBanner() {
        guard !privacyBannerDismissed else { return }
        privacyBannerDismissed = true
        persist()
    }

    /// Turns call detection on or off and persists the change (SP-006).
    func setCallDetection(enabled: Bool) {
        guard callDetectionEnabled != enabled else { return }
        callDetectionEnabled = enabled
        persist()
    }

    /// Turns recording preservation on or off and persists the change.
    func setKeepRecordings(enabled: Bool) {
        guard keepRecordingsAfterTranscription != enabled else { return }
        keepRecordingsAfterTranscription = enabled
        persist()
    }

    /// Turns automatic summary generation on or off and persists the change.
    func setAutoGenerateSummaries(enabled: Bool) {
        guard autoGenerateSummaries != enabled else { return }
        autoGenerateSummaries = enabled
        persist()
    }

    /// Includes or excludes one call app (by display name) from detection and
    /// persists the change.
    func setCallApp(_ displayName: String, enabled: Bool) {
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
