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
import os

@Observable
@MainActor
final class AppSettings {

    private static let log = Logger(subsystem: "com.sancrisoft.Echo", category: "AppSettings")

    /// The on-disk payload. Every field defaults so a missing key (older file,
    /// or none at all) decodes cleanly.
    private struct Stored: Codable {
        var privacyBannerDismissed = false
    }

    /// Whether the user closed the "Everything stays on this Mac" banner. Once
    /// dismissed it never shows again. Read-only to callers — mutate through
    /// `dismissPrivacyBanner()` so the write to disk can't be forgotten.
    private(set) var privacyBannerDismissed: Bool

    @ObservationIgnored private let fileURL: URL

    init(fileURL: URL = EchoPaths.settingsFile) {
        self.fileURL = fileURL
        self.privacyBannerDismissed = Self.load(from: fileURL).privacyBannerDismissed
    }

    /// Permanently dismisses the privacy banner and persists the change.
    func dismissPrivacyBanner() {
        guard !privacyBannerDismissed else { return }
        privacyBannerDismissed = true
        persist()
    }

    private static func load(from url: URL) -> Stored {
        guard let data = try? Data(contentsOf: url) else { return Stored() }
        do {
            return try JSONDecoder().decode(Stored.self, from: data)
        } catch {
            log.error("Reading settings failed, using defaults: \(error.localizedDescription, privacy: .public)")
            return Stored()
        }
    }

    private func persist() {
        let stored = Stored(privacyBannerDismissed: privacyBannerDismissed)
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
            try encoder.encode(stored).write(to: fileURL, options: .atomic)
        } catch {
            Self.log.error("Writing settings failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
