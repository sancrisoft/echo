//
//  AppSettingsTests.swift
//  EchoCoreTests
//
//  SP-006: the "Suggest recording when a call starts" setting persists in
//  settings.json like every other setting (single-data-folder rule, never
//  UserDefaults), defaults to on, and survives a settings file written before
//  the feature existed.
//
//  The settings-page fields (recording retention, auto-summaries, per-app
//  call detection) persist in settings.json the same way, default to today's
//  behavior, and survive a settings file written before they existed — the
//  key-by-key decode regression SP-006 taught us to test.
//

import EchoCore
import EchoCoreTestSupport
import Foundation
import Testing

/// A fresh settings file path that does not exist yet, removed afterwards.
@MainActor
private func withTempSettingsFile<T>(_ body: (URL) throws -> T) throws -> T {
    let scratch = try TemporaryDirectory(prefix: "AppSettingsTests")
    defer { scratch.remove() }
    return try body(scratch.path("settings.json"))
}

@Suite("AppSettings — call detection")
@MainActor
struct AppSettingsCallDetectionTests {

    @Test func callDetectionIsOnByDefault() throws {
        try withTempSettingsFile { url in
            #expect(AppSettings(fileURL: url).callDetectionEnabled)
        }
    }

    @Test func turningItOffRoundTripsThroughDisk() throws {
        try withTempSettingsFile { url in
            let settings = AppSettings(fileURL: url)
            settings.setCallDetection(enabled: false)
            #expect(!settings.callDetectionEnabled)

            // A relaunch reads the same answer back.
            #expect(!AppSettings(fileURL: url).callDetectionEnabled)
        }
    }

    @Test func turningItBackOnRoundTripsThroughDisk() throws {
        try withTempSettingsFile { url in
            let settings = AppSettings(fileURL: url)
            settings.setCallDetection(enabled: false)
            settings.setCallDetection(enabled: true)

            #expect(AppSettings(fileURL: url).callDetectionEnabled)
        }
    }

    @Test func theSettingIsIndependentOfThePrivacyBanner() throws {
        try withTempSettingsFile { url in
            let settings = AppSettings(fileURL: url)
            settings.dismissPrivacyBanner()
            settings.setCallDetection(enabled: false)

            let reloaded = AppSettings(fileURL: url)
            #expect(reloaded.privacyBannerDismissed)
            #expect(!reloaded.callDetectionEnabled)
        }
    }

    @Test func aSettingsFileWrittenBeforeTheFeatureDecodesToOn() throws {
        try withTempSettingsFile { url in
            // Exactly what shipped before SP-006 — no call-detection key.
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data(#"{"privacyBannerDismissed":true}"#.utf8).write(to: url)

            let settings = AppSettings(fileURL: url)
            #expect(settings.privacyBannerDismissed)
            #expect(settings.callDetectionEnabled, "an upgrade must not silently disable the feature")
        }
    }

    @Test func anUnreadableSettingsFileFallsBackToOn() throws {
        try withTempSettingsFile { url in
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data("not json".utf8).write(to: url)

            #expect(AppSettings(fileURL: url).callDetectionEnabled)
        }
    }

    @Test func redundantWritesAreSkipped() throws {
        try withTempSettingsFile { url in
            let settings = AppSettings(fileURL: url)
            // Already on: nothing to persist, so no file is created.
            settings.setCallDetection(enabled: true)
            #expect(!FileManager.default.fileExists(atPath: url.path))

            settings.setCallDetection(enabled: false)
            #expect(FileManager.default.fileExists(atPath: url.path))
        }
    }
}

@Suite("AppSettings — settings-page preferences")
@MainActor
struct AppSettingsPreferencesTests {

    @Test func defaultsPreserveTodaysBehavior() throws {
        try withTempSettingsFile { url in
            let settings = AppSettings(fileURL: url)
            #expect(!settings.keepRecordingsAfterTranscription)
            #expect(settings.autoGenerateSummaries)
            #expect(settings.disabledCallApps.isEmpty)
            #expect(settings.checkForUpdatesAutomatically)
        }
    }

    @Test func updateCheckToggleRoundTripsThroughDisk() throws {
        try withTempSettingsFile { url in
            let settings = AppSettings(fileURL: url)
            settings.setCheckForUpdates(automatically: false)
            #expect(!settings.checkForUpdatesAutomatically)

            #expect(!AppSettings(fileURL: url).checkForUpdatesAutomatically)
        }
    }

    @Test func keepRecordingsRoundTripsThroughDisk() throws {
        try withTempSettingsFile { url in
            let settings = AppSettings(fileURL: url)
            settings.setKeepRecordings(enabled: true)
            #expect(settings.keepRecordingsAfterTranscription)

            // A relaunch reads the same answer back.
            #expect(AppSettings(fileURL: url).keepRecordingsAfterTranscription)
        }
    }

    @Test func autoSummariesRoundTripsThroughDisk() throws {
        try withTempSettingsFile { url in
            let settings = AppSettings(fileURL: url)
            settings.setAutoGenerateSummaries(enabled: false)
            #expect(!settings.autoGenerateSummaries)

            #expect(!AppSettings(fileURL: url).autoGenerateSummaries)
        }
    }

    @Test func disabledCallAppsRoundTripSortedAndDeduped() throws {
        try withTempSettingsFile { url in
            let settings = AppSettings(fileURL: url)
            settings.setCallApp("Zoom", enabled: false)
            settings.setCallApp("Discord", enabled: false)
            settings.setCallApp("Discord", enabled: false)  // no-op duplicate
            #expect(settings.disabledCallApps == ["Discord", "Zoom"])

            let reloaded = AppSettings(fileURL: url)
            #expect(reloaded.disabledCallApps == ["Discord", "Zoom"])

            reloaded.setCallApp("Discord", enabled: true)
            #expect(reloaded.disabledCallApps == ["Zoom"])
            #expect(AppSettings(fileURL: url).disabledCallApps == ["Zoom"])
        }
    }

    /// The SP-006 lesson: a settings.json missing the new keys must keep the
    /// old fields' values instead of dropping the whole file to defaults.
    @Test func aSettingsFileWrittenBeforeTheseFieldsKeepsItsOldValues() throws {
        try withTempSettingsFile { url in
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            // Exactly what shipped before this page — only the two old keys.
            try Data(#"{"privacyBannerDismissed":true,"callDetectionEnabled":false}"#.utf8).write(to: url)

            let settings = AppSettings(fileURL: url)
            #expect(settings.privacyBannerDismissed)
            #expect(!settings.callDetectionEnabled)
            #expect(!settings.keepRecordingsAfterTranscription)
            #expect(settings.autoGenerateSummaries)
            #expect(settings.disabledCallApps.isEmpty)
            #expect(settings.checkForUpdatesAutomatically)
        }
    }

    /// The reverse direction: writing a new field must carry the old fields
    /// along, so no toggle ever resets another.
    @Test func writingANewFieldKeepsTheOldOnes() throws {
        try withTempSettingsFile { url in
            let settings = AppSettings(fileURL: url)
            settings.dismissPrivacyBanner()
            settings.setCallDetection(enabled: false)
            settings.setKeepRecordings(enabled: true)
            settings.setAutoGenerateSummaries(enabled: false)
            settings.setCallApp("Slack", enabled: false)
            settings.setCheckForUpdates(automatically: false)

            let reloaded = AppSettings(fileURL: url)
            #expect(reloaded.privacyBannerDismissed)
            #expect(!reloaded.callDetectionEnabled)
            #expect(reloaded.keepRecordingsAfterTranscription)
            #expect(!reloaded.autoGenerateSummaries)
            #expect(reloaded.disabledCallApps == ["Slack"])
            #expect(!reloaded.checkForUpdatesAutomatically)
        }
    }

    @Test func noOpMutatorsDontTouchTheFile() throws {
        try withTempSettingsFile { url in
            let settings = AppSettings(fileURL: url)
            // All defaults already: nothing to persist, so no file is created.
            settings.setKeepRecordings(enabled: false)
            settings.setAutoGenerateSummaries(enabled: true)
            settings.setCallApp("Zoom", enabled: true)
            #expect(!FileManager.default.fileExists(atPath: url.path))

            settings.setKeepRecordings(enabled: true)
            #expect(FileManager.default.fileExists(atPath: url.path))

            // A genuine no-op after a real write leaves the bytes alone.
            let before = try? Data(contentsOf: url)
            settings.setKeepRecordings(enabled: true)
            settings.setCallApp("Zoom", enabled: true)
            #expect((try? Data(contentsOf: url)) == before)
        }
    }
}
