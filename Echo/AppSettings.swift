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

    @ObservationIgnored private let fileURL: URL

    init(fileURL: URL = EchoPaths.settingsFile) {
        self.fileURL = fileURL
        let stored = Self.load(from: fileURL)
        self.privacyBannerDismissed = stored.privacyBannerDismissed
        self.callDetectionEnabled = stored.callDetectionEnabled
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
