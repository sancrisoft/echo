//
//  AppSettingsCallDetectionTests.swift
//  EchoTests
//
//  SP-006: the "Suggest recording when a call starts" setting persists in
//  settings.json like every other setting (single-data-folder rule, never
//  UserDefaults), defaults to on, and survives a settings file written before
//  the feature existed.
//

import Foundation
import Testing
@testable import Echo

@Suite("AppSettings — call detection")
@MainActor
struct AppSettingsCallDetectionTests {

    /// A fresh settings file path that does not exist yet, removed afterwards.
    private func withTempSettingsFile<T>(_ body: (URL) throws -> T) rethrows -> T {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "AppSettingsTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        return try body(root.appending(path: "settings.json", directoryHint: .notDirectory))
    }

    @Test func callDetectionIsOnByDefault() {
        withTempSettingsFile { url in
            #expect(AppSettings(fileURL: url).callDetectionEnabled)
        }
    }

    @Test func turningItOffRoundTripsThroughDisk() {
        withTempSettingsFile { url in
            let settings = AppSettings(fileURL: url)
            settings.setCallDetection(enabled: false)
            #expect(!settings.callDetectionEnabled)

            // A relaunch reads the same answer back.
            #expect(!AppSettings(fileURL: url).callDetectionEnabled)
        }
    }

    @Test func turningItBackOnRoundTripsThroughDisk() {
        withTempSettingsFile { url in
            let settings = AppSettings(fileURL: url)
            settings.setCallDetection(enabled: false)
            settings.setCallDetection(enabled: true)

            #expect(AppSettings(fileURL: url).callDetectionEnabled)
        }
    }

    @Test func theSettingIsIndependentOfThePrivacyBanner() {
        withTempSettingsFile { url in
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

    @Test func redundantWritesAreSkipped() {
        withTempSettingsFile { url in
            let settings = AppSettings(fileURL: url)
            // Already on: nothing to persist, so no file is created.
            settings.setCallDetection(enabled: true)
            #expect(!FileManager.default.fileExists(atPath: url.path))

            settings.setCallDetection(enabled: false)
            #expect(FileManager.default.fileExists(atPath: url.path))
        }
    }
}
