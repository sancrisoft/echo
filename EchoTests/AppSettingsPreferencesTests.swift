//
//  AppSettingsPreferencesTests.swift
//  EchoTests
//
//  The settings-page fields (recording retention, auto-summaries, per-app
//  call detection) persist in settings.json like every other setting
//  (single-data-folder rule, never UserDefaults), default to today's
//  behavior, and survive a settings file written before they existed —
//  the key-by-key decode regression SP-006 taught us to test.
//

import Foundation
import Testing
@testable import Echo

@Suite("AppSettings — settings-page preferences")
@MainActor
struct AppSettingsPreferencesTests {

    /// A fresh settings file path that does not exist yet, removed afterwards.
    private func withTempSettingsFile<T>(_ body: (URL) throws -> T) rethrows -> T {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "AppSettingsPreferencesTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        return try body(root.appending(path: "settings.json", directoryHint: .notDirectory))
    }

    @Test func defaultsPreserveTodaysBehavior() {
        withTempSettingsFile { url in
            let settings = AppSettings(fileURL: url)
            #expect(!settings.keepRecordingsAfterTranscription)
            #expect(settings.autoGenerateSummaries)
            #expect(settings.disabledCallApps.isEmpty)
        }
    }

    @Test func keepRecordingsRoundTripsThroughDisk() {
        withTempSettingsFile { url in
            let settings = AppSettings(fileURL: url)
            settings.setKeepRecordings(enabled: true)
            #expect(settings.keepRecordingsAfterTranscription)

            // A relaunch reads the same answer back.
            #expect(AppSettings(fileURL: url).keepRecordingsAfterTranscription)
        }
    }

    @Test func autoSummariesRoundTripsThroughDisk() {
        withTempSettingsFile { url in
            let settings = AppSettings(fileURL: url)
            settings.setAutoGenerateSummaries(enabled: false)
            #expect(!settings.autoGenerateSummaries)

            #expect(!AppSettings(fileURL: url).autoGenerateSummaries)
        }
    }

    @Test func disabledCallAppsRoundTripSortedAndDeduped() {
        withTempSettingsFile { url in
            let settings = AppSettings(fileURL: url)
            settings.setCallApp("Zoom", enabled: false)
            settings.setCallApp("Discord", enabled: false)
            settings.setCallApp("Discord", enabled: false)   // no-op duplicate
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
        }
    }

    /// The reverse direction: writing a new field must carry the old fields
    /// along, so no toggle ever resets another.
    @Test func writingANewFieldKeepsTheOldOnes() {
        withTempSettingsFile { url in
            let settings = AppSettings(fileURL: url)
            settings.dismissPrivacyBanner()
            settings.setCallDetection(enabled: false)
            settings.setKeepRecordings(enabled: true)
            settings.setAutoGenerateSummaries(enabled: false)
            settings.setCallApp("Slack", enabled: false)

            let reloaded = AppSettings(fileURL: url)
            #expect(reloaded.privacyBannerDismissed)
            #expect(!reloaded.callDetectionEnabled)
            #expect(reloaded.keepRecordingsAfterTranscription)
            #expect(!reloaded.autoGenerateSummaries)
            #expect(reloaded.disabledCallApps == ["Slack"])
        }
    }

    @Test func noOpMutatorsDontTouchTheFile() {
        withTempSettingsFile { url in
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
